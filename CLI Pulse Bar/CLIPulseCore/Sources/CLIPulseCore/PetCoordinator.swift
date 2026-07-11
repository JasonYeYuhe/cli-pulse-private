// PetCoordinator — v1.42 "Pulse Cat" M1 (persistence + hatch application).
//
// An actor owning the pet's durable collection. Design (plan §2.2):
//   • SOURCE OF TRUTH = an append-only event log `pet-events-v1.jsonl` (one JSON
//     object per line: hatch / setActive / rulesetUpgrade). Events are never
//     modified or removed — only appended.
//   • State is DERIVED by replaying the log, so corrupt-state recovery is
//     inherent: a truncated/garbled last line is skipped and the rest replays.
//   • A derived snapshot `pet-state-v1.json` is ALSO written (atomic) for M2 /
//     external readers, but is NOT read back for correctness — replaying a
//     handful of events is sub-millisecond, which removes any snapshot-staleness
//     race after a crash.
//
// Cross-platform (pure Foundation I/O) so the collection logic is unit-testable
// everywhere; only the M2 wiring that reads the macOS ledger is os-gated.

import Foundation

// MARK: - Event log

public enum PetEventKind: String, Codable, Sendable {
    case hatch
    case setActive
    case rulesetUpgrade
}

public struct PetEvent: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var kind: PetEventKind
    public var dayKey: String
    public var timestampUnixMs: Int64
    public var form: String?                 // hatch / setActive
    public var whySnapshot: PetWindowProfile?  // hatch only — frozen interpretation
    public var fromRulesetVersion: Int?      // rulesetUpgrade
    public var toRulesetVersion: Int?        // rulesetUpgrade

    public init(schemaVersion: Int = PetEvent.currentSchemaVersion,
                kind: PetEventKind, dayKey: String, timestampUnixMs: Int64,
                form: String? = nil, whySnapshot: PetWindowProfile? = nil,
                fromRulesetVersion: Int? = nil, toRulesetVersion: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.dayKey = dayKey
        self.timestampUnixMs = timestampUnixMs
        self.form = form
        self.whySnapshot = whySnapshot
        self.fromRulesetVersion = fromRulesetVersion
        self.toRulesetVersion = toRulesetVersion
    }
}

/// Result of an evaluate-and-hatch cycle.
public struct PetHatchOutcome: Sendable, Equatable {
    public var decision: PetHatchDecision
    public var state: PetState
    /// The hatch event appended this cycle, if any (for a reveal + name-it flow).
    public var hatchEvent: PetEvent?
}

public actor PetCoordinator {
    public static let shared = PetCoordinator()

    private let root: URL?          // nil ⇒ Application Support/CLIPulse
    private var events: [PetEvent]?  // nil until first load (off-main)

    public init(root: URL? = nil) { self.root = root }

    // MARK: Load / replay

    private func loadedEvents() -> [PetEvent] {
        if let events { return events }
        let e = Self.readEventLog(root: root)
        events = e
        return e
    }

    /// Current derived state (replayed from the log — the source of truth).
    public func state() -> PetState {
        PetCoordinator.rebuild(from: loadedEvents())
    }

    /// Full event history (for the Cattery "why hatched" panel + debugging).
    public func eventLog() -> [PetEvent] { loadedEvents() }

    /// Deterministically rebuild state by replaying events in order. Unknown
    /// schema versions are skipped (can't be safely interpreted).
    public static func rebuild(from events: [PetEvent]) -> PetState {
        var s = PetState()
        for e in events where e.schemaVersion == PetEvent.currentSchemaVersion {
            switch e.kind {
            case .hatch:
                if let raw = e.form, let form = PetForm(rawValue: raw) {
                    s = PetEngine.applyHatch(form, on: s, dayKey: e.dayKey)
                }
            case .setActive:
                if let raw = e.form, s.ownedForms.contains(raw) { s.activeForm = raw }
            case .rulesetUpgrade:
                break   // marker only; owned cats keep their frozen whySnapshot
            }
        }
        return s
    }

    // MARK: Mutations

    /// Evaluate the current window and hatch if warranted. Appends a hatch event
    /// (with the frozen whySnapshot) and persists. Returns the outcome so the UI
    /// can play the reveal. A no-hatch cycle mutates nothing (never punishes).
    @discardableResult
    public func evaluateAndHatch(ledger: PetDailyLedger, todayKey: String, nowUnixMs: Int64) -> PetHatchOutcome {
        let log = loadedEvents()
        let state = PetCoordinator.rebuild(from: log)
        let decision = PetEngine.evaluate(ledger: ledger, state: state, todayKey: todayKey)
        guard decision.shouldHatch, let form = decision.hatchedForm else {
            return PetHatchOutcome(decision: decision, state: state, hatchEvent: nil)
        }
        let event = PetEvent(kind: .hatch, dayKey: todayKey, timestampUnixMs: nowUnixMs,
                             form: form.rawValue, whySnapshot: decision.profile)
        // Commit the hatch ONLY after it is durably appended (Codex F4) — a failed
        // write leaves state unchanged and the hatch retries next cycle.
        guard commit(event, to: log) else {
            return PetHatchOutcome(decision: decision, state: state, hatchEvent: nil)
        }
        return PetHatchOutcome(decision: decision,
                               state: PetCoordinator.rebuild(from: events ?? log),
                               hatchEvent: event)
    }

    /// Switch the active companion (only if owned). Idempotent.
    @discardableResult
    public func setActiveForm(_ form: PetForm, todayKey: String, nowUnixMs: Int64) -> PetState {
        let log = loadedEvents()
        let state = PetCoordinator.rebuild(from: log)
        guard state.owns(form), state.activeForm != form.rawValue else { return state }
        let event = PetEvent(kind: .setActive, dayKey: todayKey, timestampUnixMs: nowUnixMs, form: form.rawValue)
        guard commit(event, to: log) else { return state }
        return PetCoordinator.rebuild(from: events ?? log)
    }

    // MARK: Persistence

    /// Physically appends `event` to the log (never rewrites — so unknown
    /// future-schema lines written by a newer app are preserved byte-for-byte,
    /// Codex F5). Commits the in-memory cache + derived snapshot only on a
    /// successful durable append. Returns whether it committed.
    private func commit(_ event: PetEvent, to log: [PetEvent]) -> Bool {
        guard Self.appendEvent(event, root: root) else { return false }
        var newLog = log
        newLog.append(event)
        events = newLog
        Self.writeSnapshot(PetCoordinator.rebuild(from: newLog), root: root)  // best-effort
        return true
    }

    // MARK: - IO (Application Support/CLIPulse)

    static let eventsFileName = "pet-events-v1.jsonl"
    static let snapshotFileName = "pet-state-v1.json"

    static func dir(root: URL?) -> URL {
        (root ?? PetDailyLedgerIO.defaultRoot())
    }
    static func eventsURL(root: URL?) -> URL { dir(root: root).appendingPathComponent(eventsFileName) }
    static func snapshotURL(root: URL?) -> URL { dir(root: root).appendingPathComponent(snapshotFileName) }

    /// Reads the JSONL log from RAW BYTES, splitting on LF and decoding each line
    /// independently. Reading raw `Data` (not a UTF-8 `String`) means one garbled
    /// / non-UTF-8 / truncated line is skipped without discarding the whole log
    /// (Codex F3); unknown-schema lines survive the read and are re-included by
    /// the physical-append writer.
    static func readEventLog(root: URL?) -> [PetEvent] {
        guard let data = try? Data(contentsOf: eventsURL(root: root)) else { return [] }
        let decoder = JSONDecoder()
        var out: [PetEvent] = []
        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(PetEvent.self, from: Data(lineData)) { out.append(event) }
        }
        return out
    }

    /// Physically appends one JSONL record (create-if-absent) and fsyncs, so the
    /// existing log bytes — including unknown future-schema lines — are never
    /// rewritten or lost (Codex F5). Returns whether the durable write succeeded.
    @discardableResult
    static func appendEvent(_ event: PetEvent, root: URL?) -> Bool {
        let d = dir(root: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var line = try encoder.encode(event)
            line.append(0x0A)
            let url = eventsURL(root: root)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forUpdating: url)   // read+write (need to peek last byte)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                // If the existing content doesn't end in LF (e.g. a prior partial
                // write), write a separator first so the new record can't merge
                // onto the previous line and orphan both (Codex F5-follow-up).
                if size > 0 {
                    try handle.seek(toOffset: size - 1)
                    let lastByte = try handle.read(upToCount: 1)
                    try handle.seekToEnd()
                    if lastByte != Data([0x0A]) { try handle.write(contentsOf: Data([0x0A])) }
                }
                try handle.write(contentsOf: line)
                try handle.synchronize()
            } else {
                try line.write(to: url, options: .atomic)
            }
            return true
        } catch { return false }
    }

    @discardableResult
    static func writeSnapshot(_ state: PetState, root: URL?) -> Bool {
        let d = dir(root: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            let url = snapshotURL(root: root)
            let tmp = d.appendingPathComponent(".tmp-\(UUID().uuidString).json")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch { return false }
    }
}

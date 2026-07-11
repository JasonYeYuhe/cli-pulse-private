// PetLedgerManager — v1.42 "Pulse Cat" M0.
//
// macOS glue between the token-history producers and the pure `PetDailyLedger`.
// An actor (the ledger is mutable shared state touched from the refresh path),
// lazily loading off-main to stay app-hang-safe — the exact idiom of
// `DailyUsageArchiveManager`. Unlike that manager it does NOT scan; it only
// folds handed-in results, so it never touches disk beyond the ledger file.

#if os(macOS)
import Foundation

public extension Notification.Name {
    /// Posted after the pet ledger is mutated + saved, so pet surfaces (Pet tab,
    /// floating companion — M2) can re-snapshot live.
    static let petLedgerDidChange = Notification.Name("cli_pulse_pet_ledger_did_change")
}

public actor PetLedgerManager {
    public static let shared = PetLedgerManager()

    // nil until the first actor-isolated access (disk read stays off the
    // MainActor first-touch — this menu-bar agent is app-hang-sensitive).
    private var ledger: PetDailyLedger?
    private let root: URL?          // nil ⇒ default Application Support/CLIPulse

    public init(root: URL? = nil) {
        self.root = root
        self.ledger = nil
    }

    private func loaded() -> PetDailyLedger {
        if let ledger { return ledger }
        let l = PetDailyLedgerIO.load(root: root)
        ledger = l
        return l
    }

    /// Current ledger snapshot (for the engine / pet surfaces).
    public func snapshot() -> PetDailyLedger { loaded() }

    // MARK: - Producers

    /// Fold a local scan (Claude/Codex on-disk JSONL) — high confidence.
    /// `observedAtUnixMs` MUST be captured at data-source time (when the scan
    /// completed), NOT at actor receipt, so a stale overlapping refresh whose
    /// task lands last can't overwrite a fresher slice (Codex F3). Defaults to
    /// now for call sites (tests) that produce and record in one step.
    public func record(_ scan: CostUsageScanResult, observedAtUnixMs: Int64? = nil) {
        let obs = PetObservation.fromLocalScan(scan, nowUnixMs: observedAtUnixMs ?? Self.nowMs())
        guard !obs.isEmpty else { return }
        apply(obs)
    }

    /// Fill cloud daily-usage rows (other providers / other devices) — medium.
    /// `observedAtUnixMs` MUST be the cloud-fetch completion time (see `record`).
    public func mergeCloud(_ rows: [DailyUsage], observedAtUnixMs: Int64? = nil) {
        let obs = PetObservation.fromCloudRows(rows, nowUnixMs: observedAtUnixMs ?? Self.nowMs())
        guard !obs.isEmpty else { return }
        apply(obs)
    }

    /// Fold pre-built observations (used by producers above + fixtures/tests).
    public func ingest(_ observations: [PetObservation]) {
        guard !observations.isEmpty else { return }
        apply(observations)
    }

    private func apply(_ observations: [PetObservation]) {
        var l = loaded()
        l.ingest(observations)
        l.lastUpdatedUnixMs = Self.nowMs()
        ledger = l
        PetDailyLedgerIO.save(l, root: root)
        NotificationCenter.default.post(name: .petLedgerDidChange, object: nil)
    }

    /// Wall-clock milliseconds — call sites capture this at data-source time.
    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}
#endif

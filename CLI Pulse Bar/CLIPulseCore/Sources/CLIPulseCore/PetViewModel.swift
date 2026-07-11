// PetViewModel — v1.42 "Pulse Cat" M2.
//
// PetTabModel is a PURE, testable snapshot of everything the Pet tab renders.
// PetViewModel is the @MainActor ObservableObject that loads it — from the real
// ledger + coordinator on macOS, or the deterministic Sample Pet when there's no
// data yet (or on platforms without a local ledger). All gated by the kill-switch.

import Foundation
import SwiftUI

// MARK: - Pure snapshot

public struct PetTabModel: Sendable, Equatable {
    public var decision: PetHatchDecision
    public var vitals: PetVitals
    public var diet: [PetDietSlice]
    public var cattery: [PetCatteryEntry]
    public var hatchStatus: PetHatchStatus
    public var state: PetState
    public var isSample: Bool
    public var ownedWhy: [String: PetWindowProfile]   // form.rawValue → frozen why-snapshot
    public var todayKey: String

    public var activeForm: PetForm? { state.activeForm.flatMap(PetForm.init(rawValue:)) }

    public static func build(ledger: PetDailyLedger, state: PetState,
                             todayKey: String, nowUnixMs: Int64,
                             ownedWhy: [String: PetWindowProfile] = [:],
                             isSample: Bool) -> PetTabModel {
        let decision = PetEngine.evaluate(ledger: ledger, state: state, todayKey: todayKey)
        return PetTabModel(
            decision: decision,
            vitals: PetVitalsEngine.compute(ledger: ledger, todayKey: todayKey, nowUnixMs: nowUnixMs),
            diet: PetUsageDiet.compute(ledger: ledger, todayKey: todayKey),
            cattery: PetCattery.entries(state: state),
            hatchStatus: PetHatchStatus.from(decision: decision, state: state),
            state: state,
            isSample: isSample,
            ownedWhy: ownedWhy,
            todayKey: todayKey)
    }

    /// The deterministic Sample Pet snapshot (Codex F8).
    public static func sample() -> PetTabModel {
        build(ledger: PetSampleData.ledger(), state: PetSampleData.state(),
              todayKey: PetSampleData.todayKey, nowUnixMs: PetSampleData.nowUnixMs, isSample: true)
    }
}

// MARK: - Loader

@MainActor
public final class PetViewModel: ObservableObject {
    @Published public private(set) var model: PetTabModel = .sample()
    @Published public var enabled: Bool = PetSettings.isEnabled
    /// Set when a hatch just happened this load — drives the reveal + name-it sheet.
    @Published public var pendingReveal: PetForm?

    public init() {}

    /// Local day key for "now" (matches the ledger's basis).
    public static func todayKey(_ now: Date = Date()) -> String { DailyUsageStats.localDayKey(now) }

    public func reload() async {
        enabled = PetSettings.isEnabled
        guard enabled else { model = .sample(); return }
        #if os(macOS)
        let ledger = await PetLedgerManager.shared.snapshot()
        let state = await PetCoordinator.shared.state()
        let events = await PetCoordinator.shared.eventLog()
        var why: [String: PetWindowProfile] = [:]
        for e in events where e.kind == .hatch { if let f = e.form, let w = e.whySnapshot { why[f] = w } }
        // No real usage yet ⇒ show the labeled Sample so the tab is never blank.
        if ledger.days.isEmpty && state.ownedForms.isEmpty {
            model = .sample()
        } else {
            model = PetTabModel.build(ledger: ledger, state: state,
                                      todayKey: Self.todayKey(),
                                      nowUnixMs: PetLedgerManager.nowMs(),
                                      ownedWhy: why, isSample: false)
        }
        #else
        model = .sample()   // iOS/watch: no local ledger in v1 → Sample only
        #endif
    }

    /// Evaluate + hatch (if warranted) and refresh. Returns the hatched form.
    @discardableResult
    public func hatchIfReady() async -> PetForm? {
        #if os(macOS)
        guard PetSettings.isEnabled else { return nil }
        let ledger = await PetLedgerManager.shared.snapshot()
        let outcome = await PetCoordinator.shared.evaluateAndHatch(
            ledger: ledger, todayKey: Self.todayKey(), nowUnixMs: PetLedgerManager.nowMs())
        await reload()
        if let f = outcome.hatchEvent?.form.flatMap(PetForm.init(rawValue:)) {
            pendingReveal = f
            // Auto-show the floating companion ONCE, right after the first hatch
            // (opt-in default; dismissable) — §5.
            if !PetSettings.didAutoShowCompanion {
                PetSettings.didAutoShowCompanion = true
                PetSettings.companionVisible = true
                PetPanelController.shared.setVisible(true)
            }
            return f
        }
        #endif
        return nil
    }

    public func setActive(_ form: PetForm) async {
        #if os(macOS)
        _ = await PetCoordinator.shared.setActiveForm(form, todayKey: Self.todayKey(), nowUnixMs: PetLedgerManager.nowMs())
        await reload()
        #endif
    }

    public func setEnabled(_ on: Bool) async {
        PetSettings.isEnabled = on
        #if os(macOS)
        // The kill-switch hides + suppresses the floating companion too, not just
        // the tab (Codex M2b#3).
        if !on {
            PetSettings.companionVisible = false
            PetPanelController.shared.hide()
        }
        #endif
        await reload()
    }

    public func nameActive(_ name: String, form: PetForm) {
        PetSettings.setName(name, for: form)
        objectWillChange.send()
    }
}

// PetTab — v1.42 "Pulse Cat" M2 (the home base).
//
// The Pet tab: egg/hatch flow, active companion + vitals with a confidence line
// (the cat never fakes liveness), the exact 7-day Usage Diet bar, the Cattery
// grid, an active-pet switcher, why-hatched, and the kill-switch. Renders from
// real data on macOS or the deterministic Sample Pet otherwise. Static line-art
// images ⇒ inherently Reduce-Motion-safe; VoiceOver labels throughout.

import SwiftUI

// The Pet tab is a macOS/iOS surface (not a watch surface in v1); some controls
// it uses (.roundedBorder text fields, small control sizes) are unavailable on
// watchOS, so the whole view is gated off that platform.
#if os(macOS) || os(iOS)

// MARK: - Family accent colors (mood is never color-only; labels always present)

extension PetFamily {
    var accent: Color {
        switch self {
        case .anthropic: return Color(red: 0.85, green: 0.53, blue: 0.30)   // warm clay
        case .openai:    return Color(red: 0.22, green: 0.68, blue: 0.60)   // teal
        case .google:    return Color(red: 0.30, green: 0.55, blue: 0.90)   // blue
        case .other:     return Color(red: 0.55, green: 0.55, blue: 0.60)   // gray
        }
    }
    var localizedName: String {
        switch self {
        case .anthropic: return L10n.pet.familyAnthropic
        case .openai: return L10n.pet.familyOpenAI
        case .google: return L10n.pet.familyGoogle
        case .other: return L10n.pet.familyOther
        }
    }
}

public struct PetTab: View {
    @StateObject private var vm = PetViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showNameSheet = false
    @State private var nameDraft = ""
    // Live-persisted (not a one-time snapshot) so an auto-show / relaunch is
    // reflected in the toggle (Codex M2b#6). Keys match PetSettings.
    @AppStorage("cli_pulse_pet_companion_visible") private var companionOn = false
    @AppStorage("cli_pulse_pet_companion_clickthrough") private var clickThrough = false
    #if DEBUG
    @AppStorage("cli_pulse_pet_debug_force_animate") private var debugForceAnimate = false
    #endif

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !vm.enabled {
                    disabledCard
                } else {
                    heroSection
                    if case .hasCompanion = vm.model.hatchStatus {
                        if vm.model.decision.shouldHatch, let f = vm.model.decision.hatchedForm {
                            hatchPromptBanner(form: f)
                        }
                        vitalsSection
                    }
                    dietSection
                    catterySection
                    whyHatchedSection
                    settingsSection
                }
            }
            .padding(16)
        }
        .task { await vm.reload() }
        .onChange(of: vm.pendingReveal) { form in
            if form != nil { nameDraft = ""; showNameSheet = true }
        }
        // Clear pendingReveal on ANY dismiss (Esc / swipe), else a later hatch of
        // the same form won't re-trigger onChange and the sheet never reopens (agy).
        .sheet(isPresented: $showNameSheet, onDismiss: { vm.pendingReveal = nil }) { nameSheet }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.pet.title).font(.title2).bold()
                Text(L10n.pet.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.model.isSample {
                Text(L10n.pet.sampleBadge)
                    .font(.caption2).bold().padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .accessibilityLabel(L10n.pet.sampleBadge)
            }
        }
    }

    private var disabledCard: some View {
        VStack(spacing: 12) {
            petImage(name: "egg_idle_0", size: 96)
            Text(L10n.pet.disabledBody).font(.callout).multilineTextAlignment(.center)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L10n.pet.enabledToggle) { Task { await vm.setEnabled(true) } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    // MARK: Hero (egg or companion)

    @ViewBuilder private var heroSection: some View {
        switch vm.model.hatchStatus {
        case let .egg(stage):
            eggHero(stage: stage)
        case let .readyToHatch(form):
            eggHero(stage: .crack3, ready: true, form: form)
        case let .ownedThisWeek(form):
            eggHero(stage: .crack3, ownedForm: form)
        case let .hasCompanion(form):
            companionHero(form: form)
        }
    }

    private func eggHero(stage: PetEggStage, ready: Bool = false,
                         form: PetForm? = nil, ownedForm: PetForm? = nil) -> some View {
        VStack(spacing: 10) {
            petImage(name: PetAssets.eggFrames(stage: stage).first ?? "egg_idle_0", size: 132)
                .accessibilityLabel(L10n.pet.eggTitle)
            if ready, let form {
                Text(L10n.pet.hatchReady).font(.headline)
                Button(L10n.pet.hatchButton) {
                    Task { if let hatched = await vm.hatchIfReady() { _ = hatched } }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(PetSettings.displayName(for: form))
            } else if ownedForm != nil {
                Text(L10n.pet.eggTitle).font(.headline)
                Text(L10n.pet.ownedThisWeek).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(L10n.pet.eggTitle).font(.headline)
                Text(L10n.pet.eggBody).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                let active = vm.model.decision.profile.activeDayKeys.count
                Text(L10n.pet.eggProgress("\(active)", "\(PetRuleset.minActiveDaysToQualify)"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    private func hatchPromptBanner(form: PetForm) -> some View {
        HStack(spacing: 10) {
            petImage(name: "egg_crack3", size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.pet.hatchReady).font(.callout).bold()
                Text(L10n.pet.formName(form)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.pet.hatchButton) { Task { _ = await vm.hatchIfReady() } }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(form.family.accent.opacity(0.14)))
    }

    private func companionHero(form: PetForm) -> some View {
        let bucket = vm.model.vitals.energy
        return VStack(spacing: 8) {
            petImage(name: "\(form.rawValue)_\(bucket == .sleeping ? "sleep_0" : "idle_0")", size: 140)
                .accessibilityLabel(petVoiceOver(form: form))
            Text(PetSettings.displayName(for: form)).font(.headline)
            Text(form.family.localizedName + " · " + vitalWord(bucket))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    // MARK: Vitals

    private var vitalsSection: some View {
        let v = vm.model.vitals
        // Mood (quota/ServiceStatus "weather") needs live inputs — it lands in
        // the animation PR (M2b); showing a fake "Content" here would violate the
        // honesty rule (Codex F2/M2#3), so only ledger-derived vitals are shown.
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                vitalChip(L10n.pet.energy, vitalWord(v.energy))
                vitalChip(L10n.pet.hunger, "\(Int((v.hunger * 100).rounded()))%")
            }
            Text(confidenceLine(v))
                .font(.caption2).foregroundStyle(.tertiary)
                .accessibilityLabel(confidenceLine(v))
        }
    }

    private func vitalChip(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).bold()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: Usage Diet

    private var dietSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.pet.usageDiet).font(.subheadline).bold()
            if vm.model.diet.isEmpty {
                Text(L10n.pet.confUnavailable).font(.caption).foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(vm.model.diet) { slice in
                            Rectangle().fill(slice.family.accent)
                                .frame(width: max(2, geo.size.width * slice.percent / 100))
                        }
                    }
                }
                .frame(height: 16).clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(dietVoiceOver)
                FlowLegend(slices: vm.model.diet)
            }
        }
    }

    // MARK: Cattery

    private var catterySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.pet.cattery).font(.subheadline).bold()
                Spacer()
                Text(L10n.pet.catteryCount("\(PetCattery.ownedCount(state: vm.model.state))", "\(PetCattery.totalForms)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(vm.model.cattery) { entry in catteryCell(entry) }
            }
        }
    }

    private func catteryCell(_ entry: PetCatteryEntry) -> some View {
        Button {
            if entry.owned { Task { await vm.setActive(entry.form) } }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    petImage(name: "\(entry.form.rawValue)_idle_0", size: 60)
                        .opacity(entry.owned ? 1 : 0.16)
                    if !entry.owned {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(entry.owned ? PetSettings.displayName(for: entry.form)
                     : (entry.form.isInHatchPool ? L10n.pet.locked : L10n.pet.comingSoon))
                    .font(.caption2).lineLimit(1)
                    .foregroundStyle(entry.owned ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(entry.isActive ? entry.form.family.accent.opacity(0.18) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(entry.isActive ? entry.form.family.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(!entry.owned)
        .accessibilityLabel(catteryVoiceOver(entry))
    }

    // MARK: Why hatched (frozen snapshot — never reinterpreted)

    @ViewBuilder private var whyHatchedSection: some View {
        if let form = vm.model.activeForm, let why = vm.model.ownedWhy[form.rawValue] {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text(L10n.pet.whyHatched).font(.subheadline).bold()
                if let date = vm.model.state.ownedDayKeys[form.rawValue] {
                    Text(L10n.pet.ownedOn(date)).font(.caption).foregroundStyle(.secondary)
                }
                let dom = why.dominant?.localizedName ?? L10n.pet.familyOther
                let tempo = why.tempo == .burst ? L10n.pet.vitalSprint : L10n.pet.vitalWorking
                Text("\(dom) · \(tempo)").font(.caption).foregroundStyle(.secondary)
                // The frozen family mix at hatch time.
                let mix = why.familyShares
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .filter { $0.value > 0.001 }
                    .prefix(3)
                    .map { "\((PetFamily(rawValue: $0.key) ?? .other).localizedName) \(Int(($0.value * 100).rounded()))%" }
                    .joined(separator: " · ")
                if !mix.isEmpty { Text(mix).font(.caption2).foregroundStyle(.tertiary) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Toggle(L10n.pet.enabledToggle, isOn: Binding(
                get: { vm.enabled },
                set: { on in Task { await vm.setEnabled(on) } }))
            #if os(macOS)
            Toggle(L10n.pet.companionToggle, isOn: $companionOn)   // @AppStorage persists it
                .onChange(of: companionOn) { on in PetPanelController.shared.setVisible(on) }
            if companionOn {
                Toggle(L10n.pet.companionClickThrough, isOn: $clickThrough)
                    .onChange(of: clickThrough) { on in PetPanelController.shared.setClickThrough(on) }
                Text(L10n.pet.companionClickThroughHint).font(.caption2).foregroundStyle(.tertiary)
            }
            #endif
            Button {
                copySummary()
            } label: { Label(L10n.pet.copySummary, systemImage: "doc.on.doc") }
                .buttonStyle(.plain).font(.callout)
            #if DEBUG && os(macOS)
            // Debug-build-only test affordances (the M1 plan's debug menu; not
            // compiled into release builds, so English-only is fine).
            Divider()
            HStack(spacing: 14) {
                Button("Debug: Unlock all cats") { Task { await vm.debugUnlockAll() } }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
                Button("Debug: Reset collection") { Task { await vm.debugReset() } }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
            }
            // The shipping cat only animates while you're actively using AI (fresh
            // usage → non-sleeping bucket). This forces the floating companion to
            // animate now so the motion can be verified without live token burn.
            Button(debugForceAnimate ? "Debug: Stop forced animation" : "Debug: Animate companion now") {
                debugForceAnimate.toggle()
                companionOn = true                     // ensure the panel is up to see it
                PetPanelController.shared.setVisible(true)
                Task { await PetPanelController.shared.refresh() }
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
            #endif
        }
    }

    // MARK: Name-it sheet

    private var nameSheet: some View {
        VStack(spacing: 16) {
            if let form = vm.pendingReveal {
                petImage(name: "\(form.rawValue)_idle_0", size: 120)
                Text(L10n.pet.nameItTitle).font(.headline)
                Text(L10n.pet.formName(form)).font(.caption).foregroundStyle(.secondary)
                TextField(L10n.pet.namePlaceholder, text: $nameDraft).textFieldStyle(.roundedBorder).frame(width: 220)
                Button(L10n.pet.hatchButton) {
                    if !nameDraft.isEmpty { vm.nameActive(nameDraft, form: form) }
                    vm.pendingReveal = nil; showNameSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28).frame(minWidth: 300)
    }

    // MARK: Helpers

    private func petImage(name: String, size: CGFloat) -> some View {
        Group {
            if let img = PetAssets.image(name) {
                img.resizable().scaledToFit()
            } else {
                Image(systemName: "pawprint").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private func vitalWord(_ b: PetAnimationBucket) -> String {
        switch b {
        case .sleeping: return L10n.pet.vitalSleeping
        case .idle: return L10n.pet.vitalIdle
        case .working: return L10n.pet.vitalWorking
        case .sprint: return L10n.pet.vitalSprint
        }
    }
    private func confidenceLine(_ v: PetVitals) -> String {
        switch v.confidence {
        case .live: return L10n.pet.confLive
        case let .stale(age): return L10n.pet.confStale(Self.ago(age))
        case .partial: return L10n.pet.confLive
        case .unavailable: return L10n.pet.confUnavailable
        }
    }
    static func ago(_ seconds: Int) -> String {
        if seconds < 90 { return "\(max(1, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
    private func petVoiceOver(form: PetForm) -> String {
        "\(PetSettings.displayName(for: form)) — \(vitalWord(vm.model.vitals.energy)), \(confidenceLine(vm.model.vitals))"
    }
    private func catteryVoiceOver(_ e: PetCatteryEntry) -> String {
        e.owned ? "\(PetSettings.displayName(for: e.form))\(e.isActive ? ", active" : "")"
                : "\(L10n.pet.formName(e.form)), \(e.form.isInHatchPool ? L10n.pet.locked : L10n.pet.comingSoon)"
    }
    private var dietVoiceOver: String {
        vm.model.diet.map { "\($0.family.localizedName) \(Int($0.percent.rounded()))%" }.joined(separator: ", ")
    }
    private func copySummary() {
        // Honest header: name the companion only if one exists (no `.huh`
        // invention for an unhatched egg), and mark the Sample explicitly so
        // copied text never looks like real usage (agy/Codex M2).
        var lines: [String] = []
        if vm.model.isSample { lines.append("[\(L10n.pet.sampleBadge)] \(L10n.pet.title)") }
        else if let f = vm.model.activeForm { lines.append("\(L10n.pet.title) — \(PetSettings.displayName(for: f))") }
        else { lines.append("\(L10n.pet.title) — \(L10n.pet.eggTitle)") }
        lines += vm.model.diet.map { "\($0.family.localizedName): \(Int($0.percent.rounded()))%" }
        let text = lines.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Diet legend

private struct FlowLegend: View {
    let slices: [PetDietSlice]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(slices) { s in
                HStack(spacing: 4) {
                    Circle().fill(s.family.accent).frame(width: 8, height: 8)
                    Text("\(s.family.localizedName) \(Int(s.percent.rounded()))%").font(.caption2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

#endif  // os(macOS) || os(iOS)

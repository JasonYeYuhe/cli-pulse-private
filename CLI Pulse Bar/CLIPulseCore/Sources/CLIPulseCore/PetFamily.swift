// PetFamily + PetWeightTable — v1.42 "Pulse Cat" M0 (data contract).
//
// The Pulse Cat's hatch is driven by which AI *model vendor* dominated the
// trailing 7-day usage window (axis-1). `PetFamily` is that vendor taxonomy.
//
// Design decision (Codex F1 — "the cat must never lie"): only providers that
// UNAMBIGUOUSLY identify a first-party model vendor map to a named family.
// Model-agnostic coding tools / IDEs / aggregators (Cursor, Copilot, Windsurf,
// Zed, OpenRouter, Bedrock, …) let the user pick any model, so they reveal no
// vendor — they map to `.other`. `.other` usage still counts toward window
// totals (tempo, active-days), but a window dominated by `.other` resolves to
// the *Mixed* form, never a false vendor verdict. New/unknown `ProviderKind`
// cases default to `.other` for the same reason (unknown vendor ⇒ no verdict).
//
// Pure + cross-platform (no `#if os`), so the mapping + weight math are fully
// unit-testable and portable to the future Rust/Tauri engine.

import Foundation

// MARK: - Family (axis-1: model vendor)

public enum PetFamily: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai
    case google
    /// Model-agnostic tools, aggregators, and every non-big-3 vendor. A window
    /// dominated by `.other` resolves to the Mixed form (never a false verdict).
    case other

    /// Maps a provider to its model-vendor family. v1 recognises only the three
    /// families with dedicated cat forms; everything else is `.other`.
    ///
    /// Membership rationale (kept auditable in one place):
    /// - anthropic: Claude Code (first-party Anthropic CLI).
    /// - openai:   Codex (OpenAI CLI), OpenAI Admin (org spend), Azure OpenAI
    ///             (OpenAI models on Azure).
    /// - google:   Gemini CLI, Vertex AI (Google Cloud), Antigravity (Google's
    ///             agentic IDE, Gemini-backed).
    /// Uses `default:` (house idiom, cf. `ProviderKind.defaultCostRate`) so a
    /// newly-added provider is `.other` until deliberately classified — the
    /// honest default (see file header).
    public static func of(_ kind: ProviderKind) -> PetFamily {
        switch kind {
        case .claude:
            return .anthropic
        case .codex, .openaiAdmin, .azureOpenAI:
            return .openai
        case .gemini, .vertexAI, .antigravity:
            return .google
        default:
            return .other
        }
    }

    /// Family for a raw provider string (the form carried on `DailyEntry` /
    /// `DailyUsage` / the ledger). An unrecognised string ⇒ `.other`.
    public static func of(providerRaw: String) -> PetFamily {
        guard let kind = ProviderKind(rawValue: providerRaw) else { return .other }
        return of(kind)
    }
}

// MARK: - Weight table (axis-1: enfranchise free/local, kill div-by-zero)

/// Converts raw token counts into a weight-normalised score so the family with
/// the most *valuable* usage — not merely the most tokens — dominates.
///
/// `weight_p = clamp(defaultCostRate_p × 1000, $0.5, $30)` USD per Mtok, where
/// `ProviderKind.defaultCostRate` is USD per **1K** tokens (so ×1000 → per Mtok).
/// The floor ($0.5) enfranchises free/local providers (Ollama's rate is 0) and
/// kills the div-by-zero when a window is all-free (3.1 Pro F1); the ceiling
/// ($30) stops one premium model from swamping the mix.
///
/// Scores are integer **micro-USD/Mtok** so all downstream share math is pure
/// integer arithmetic — deterministic and portable to the Rust engine (the
/// golden-vector contract forbids float drift). `Int64` headroom is ample:
/// 10^11 tokens × 3×10^7 micro-rate = 3×10^18 < Int64.max (9.2×10^18).
public enum PetWeightTable {
    /// Table revision — bump when the clamp bounds or rate basis change so a
    /// re-weight is auditable against a hatch's frozen snapshot (Codex F4).
    public static let version = 1

    public static let minRatePerMtokUSD = 0.5
    public static let maxRatePerMtokUSD = 30.0

    /// Integer micro-USD/Mtok weight for a provider, in [500_000, 30_000_000].
    public static func microRatePerMtok(for kind: ProviderKind) -> Int {
        let perMtokUSD = kind.defaultCostRate * 1000.0        // $/Ktok → $/Mtok
        let clamped = min(max(perMtokUSD, minRatePerMtokUSD), maxRatePerMtokUSD)
        return Int((clamped * 1_000_000).rounded())
    }

    /// Weight for a raw provider string; unknown providers get the floor rate
    /// (enfranchised, never zero — the div-by-zero guard).
    public static func microRatePerMtok(forProviderRaw raw: String) -> Int {
        guard let kind = ProviderKind(rawValue: raw) else {
            return Int((minRatePerMtokUSD * 1_000_000).rounded())
        }
        return microRatePerMtok(for: kind)
    }

    /// Deterministic weighted score for a token count under a provider's weight.
    /// Negative token counts are clamped to 0; the multiply saturates at
    /// `Int64.max` rather than trapping on absurd/adversarial inputs (Codex F5).
    public static func weightedScore(tokens: Int, providerRaw: String) -> Int64 {
        PetSaturating.mul(Int64(max(0, tokens)), Int64(microRatePerMtok(forProviderRaw: providerRaw)))
    }
}

// MARK: - Saturating integer math (deterministic, non-trapping)

/// The pet ledger runs pure `Int`/`Int64` math for determinism (Rust-port
/// contract) but must never trap on adversarial/absurd token counts — and on
/// **watchOS `Int` is 32-bit** (`SaturatingInt` doc), so even a large sum can
/// overflow. All accumulation/multiplication in the pet path routes through
/// these saturating helpers: overflow clamps to `.max`/`.min`, which is
/// deterministic across platforms and the future Rust port (Codex F5).
public enum PetSaturating {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? (b >= 0 ? Int.max : Int.min) : r
    }
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? (b >= 0 ? Int64.max : Int64.min) : r
    }
    public static func mul(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        return o ? Int64.max : r   // pet weights/tokens are non-negative
    }

    /// Exact `a*b >= c*d` for NON-NEGATIVE Int64, via 128-bit full-width
    /// multiplication. Used for threshold ratio decisions (dominance ≥55%,
    /// tempo ≥60%) so a saturated operand can never flip the verdict at extreme
    /// scale — `mul` above must NOT be used for a decision comparison (Codex F1).
    public static func productGE(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64) -> Bool {
        let l = UInt64(Swift.max(0, a)).multipliedFullWidth(by: UInt64(Swift.max(0, b)))
        let r = UInt64(Swift.max(0, c)).multipliedFullWidth(by: UInt64(Swift.max(0, d)))
        return l.high != r.high ? l.high > r.high : l.low >= r.low
    }
}

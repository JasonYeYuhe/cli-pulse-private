// PetObservation producers — v1.42 "Pulse Cat" M0.
//
// Pure, cross-platform adapters that turn the two token-history sources into
// `PetObservation`s. Kept off the macOS-only `PetLedgerManager` (and free of
// `Date()`) so the mapping is deterministic and unit-testable on every platform.
//
// The third producer named in the plan — `ProviderUsage` quota snapshots — has
// NO builder here on purpose: those feed mood only and must never become token
// history (Codex F1/F2). Any such producer lives in M1's vitals layer.

import Foundation

public extension PetObservation {

    /// Builds cumulative, high-confidence observations from a local scan.
    /// Aggregates `DailyEntry` rows per (day, provider): `tokens` = Σ(input +
    /// output) (billable work, excludes cache — parity with the cost UI);
    /// `messages` = Σ messageCount (the `__claude_msg__` bucket carries the real
    /// count, per-model rows carry ~0, so summing all rows does not double-count,
    /// exactly as `DailyUsageArchive.mergeScanEntries` does); `cost` = Σ costUSD.
    static func fromLocalScan(_ scan: CostUsageScanResult, nowUnixMs: Int64) -> [PetObservation] {
        aggregate(
            rows: scan.entries.map {
                Row(dayKey: $0.date, providerRaw: $0.provider,
                    tokens: PetSaturating.add(max(0, $0.inputTokens), max(0, $0.outputTokens)),
                    messages: max(0, $0.messageCount),
                    costNano: PetObservation.nanoUSD($0.costUSD ?? 0))
            },
            confidence: .high,
            nowUnixMs: nowUnixMs)
    }

    /// Builds cumulative, medium-confidence observations from cloud daily-usage
    /// rows. Cloud rows carry no message count (`messages` = 0). Skips the
    /// synthetic message-bucket model just as the archive's cloud merge does.
    static func fromCloudRows(_ rows: [DailyUsage], nowUnixMs: Int64) -> [PetObservation] {
        aggregate(
            rows: rows
                .filter { $0.model != ScanEntry.messageBucketModel }
                .map {
                    Row(dayKey: $0.date, providerRaw: $0.provider,
                        tokens: PetSaturating.add(max(0, $0.inputTokens), max(0, $0.outputTokens)),
                        messages: 0,
                        costNano: PetObservation.nanoUSD($0.cost))
                },
            confidence: .medium,
            nowUnixMs: nowUnixMs)
    }

    // MARK: - Aggregation

    private struct Row {
        let dayKey: String
        let providerRaw: String
        let tokens: Int
        let messages: Int
        let costNano: Int64
    }

    /// Collapses rows to one observation per (day, provider). The grouping key is
    /// sorted for canonical, deterministic output ordering; all sums saturate
    /// (never trap) and cost is integer nano-USD so aggregation is order-
    /// independent (Codex F5/F7). Rust-port contract.
    private static func aggregate(rows: [Row], confidence: PetDataConfidence,
                                  nowUnixMs: Int64) -> [PetObservation] {
        struct Acc { var tokens = 0; var messages = 0; var costNano: Int64 = 0 }
        var byKey: [String: Acc] = [:]                 // "dayKey\u{1}providerRaw" -> Acc
        for r in rows {
            let key = r.dayKey + "\u{1}" + r.providerRaw
            var acc = byKey[key] ?? Acc()
            acc.tokens = PetSaturating.add(acc.tokens, r.tokens)
            acc.messages = PetSaturating.add(acc.messages, r.messages)
            acc.costNano = PetSaturating.add(acc.costNano, r.costNano)
            byKey[key] = acc
        }
        return byKey.keys.sorted().map { key in
            let parts = key.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            let dayKey = String(parts[0])
            let providerRaw = parts.count > 1 ? String(parts[1]) : ""
            let acc = byKey[key]!
            return PetObservation(
                providerRaw: providerRaw,
                familyKey: PetFamily.of(providerRaw: providerRaw).rawValue,
                tokens: acc.tokens,
                messages: acc.messages,
                costNanoUSD: acc.costNano,
                sourceTimestampUnixMs: nowUnixMs,
                dayKey: dayKey,
                confidence: confidence,
                semantics: .cumulativeToday)
        }
    }
}

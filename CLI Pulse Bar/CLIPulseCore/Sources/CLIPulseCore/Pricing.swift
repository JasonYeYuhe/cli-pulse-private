import Foundation

/// Public pricing API for token cost calculations.
/// Delegates to CostUsageScanner.Pricing on macOS; returns nil on other platforms.
public enum TokenPricing {

    /// Calculate cost for Codex (OpenAI) model usage.
    public static func codexCost(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double? {
        #if os(macOS)
        return CostUsageScanner.Pricing.codexCostUSD(model: model, inputTokens: inputTokens, cachedInputTokens: cachedInputTokens, outputTokens: outputTokens)
        #else
        return nil
        #endif
    }

    /// Calculate cost for Claude (Anthropic) model usage.
    public static func claudeCost(model: String, inputTokens: Int, cacheReadInputTokens: Int, cacheCreationInputTokens: Int, outputTokens: Int) -> Double? {
        #if os(macOS)
        return CostUsageScanner.Pricing.claudeCostUSD(model: model, inputTokens: inputTokens, cacheReadInputTokens: cacheReadInputTokens, cacheCreationInputTokens: cacheCreationInputTokens, outputTokens: outputTokens)
        #else
        return nil
        #endif
    }

    /// Format a USD cost in the user's chosen display currency (v1.40 PR-7 —
    /// routes through CurrencyConverter; conversion at display time only).
    public static func formatCost(_ cost: Double) -> String {
        CurrencyConverter.shared.format(cost)
    }
}

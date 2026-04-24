import XCTest
@testable import CLIPulseCore

/// v1.10.7: pins the cloud-only / no-local-scan fallback behavior in
/// `AppState.updateCostSummary()` and `AppState.completeRefresh()`.
///
/// iPhone App Store builds never have a local JSONL scan result (those come
/// from macOS-only log dirs), so they hit the "estimate" branch of
/// `updateCostSummary()`. Before this fix the fallback never populated
/// `costSummary.utilization`, and the cloud `dashboard_summary` RPC ships an
/// empty `provider_breakdown`, so the Overview tab rendered two empty cards.
@MainActor
final class CostSummaryFallbackTests: XCTestCase {

    private func usage(
        _ name: String,
        plan: String? = nil,
        today: Int = 0,
        todayCost: Double = 0,
        weekCost: Double = 0,
        thirtyDayCost: Double = 0
    ) -> ProviderUsage {
        ProviderUsage(
            provider: name,
            today_usage: today, week_usage: 0,
            estimated_cost_today: todayCost,
            estimated_cost_week: weekCost,
            estimated_cost_30_day: thirtyDayCost,
            cost_status_today: "Estimated",
            cost_status_week: "Estimated",
            quota: nil, remaining: nil,
            plan_type: plan,
            reset_time: nil,
            tiers: [],
            status_text: "Operational",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: name, category: "cloud",
                supports_exact_cost: false, supports_quota: true
            )
        )
    }

    // MARK: - updateCostSummary fallback

    func testFallbackPopulatesSubscriptionUtilization() {
        let state = AppState()
        state.providerConfigs = [
            ProviderConfig(kind: .claude, isEnabled: true),
            ProviderConfig(kind: .codex,  isEnabled: true),
        ]
        // Claude Max 5x = $100/mo, 30-day API equiv $250 -> 250% utilization.
        // Codex Pro   = $200/mo, 30-day API equiv $20 ->  10% utilization.
        state.providers = [
            usage("Claude", plan: "Max 5x", thirtyDayCost: 250),
            usage("Codex",  plan: "Pro",    thirtyDayCost: 20),
        ]
        state.costUsageScanResult = nil

        state.updateCostSummary()

        XCTAssertFalse(state.costSummary.utilization.isEmpty,
                       "cloud-only fallback must populate utilization so iPhone can render it")
        XCTAssertEqual(state.costSummary.utilization.count, 2)

        // Sorted by utilizationPercent DESC — Claude (250%) first.
        let claude = state.costSummary.utilization[0]
        XCTAssertEqual(claude.provider, "Claude")
        XCTAssertEqual(claude.plan, "Max 5x")
        XCTAssertEqual(claude.subscriptionCost, 100, accuracy: 0.001)
        XCTAssertEqual(claude.apiEquivCost, 250, accuracy: 0.001)
        XCTAssertEqual(claude.utilizationPercent, 250, accuracy: 0.001)

        let codex = state.costSummary.utilization[1]
        XCTAssertEqual(codex.provider, "Codex")
        XCTAssertEqual(codex.utilizationPercent, 10, accuracy: 0.001)

        XCTAssertFalse(state.costSummary.isPrecise, "fallback must stay flagged Estimated")
    }

    func testFallbackSkipsProvidersWithoutPaidPlan() {
        let state = AppState()
        state.providerConfigs = [
            ProviderConfig(kind: .claude, isEnabled: true),
            ProviderConfig(kind: .ollama, isEnabled: true),
        ]
        state.providers = [
            usage("Claude", plan: "Pro", thirtyDayCost: 30),
            usage("Ollama", plan: nil,   thirtyDayCost: 5),  // no subscription
        ]
        state.costUsageScanResult = nil

        state.updateCostSummary()

        XCTAssertEqual(state.costSummary.utilization.count, 1)
        XCTAssertEqual(state.costSummary.utilization.first?.provider, "Claude")
    }

    func testFallbackHandlesMissingThirtyDayCostAsZero() {
        let state = AppState()
        state.providerConfigs = [ProviderConfig(kind: .claude, isEnabled: true)]
        state.providers = [usage("Claude", plan: "Pro", weekCost: 0)]
        state.costUsageScanResult = nil

        state.updateCostSummary()

        XCTAssertEqual(state.costSummary.utilization.count, 1)
        XCTAssertEqual(state.costSummary.utilization.first?.apiEquivCost, 0)
        XCTAssertEqual(state.costSummary.utilization.first?.utilizationPercent, 0)
    }

    func testFallbackUsesWeekTimes4_3WhenThirtyDayMissing() {
        let state = AppState()
        state.providerConfigs = [ProviderConfig(kind: .claude, isEnabled: true)]
        // No 30-day, but weekly cost = $10 → extrapolated 30-day = 43.
        state.providers = [usage("Claude", plan: "Pro", weekCost: 10)]
        state.costUsageScanResult = nil

        state.updateCostSummary()

        XCTAssertEqual(state.costSummary.utilization.count, 1)
        XCTAssertEqual(state.costSummary.utilization.first?.apiEquivCost ?? 0, 43.0, accuracy: 0.001)
        // $43 / $20 = 215%
        XCTAssertEqual(state.costSummary.utilization.first?.utilizationPercent ?? 0, 215, accuracy: 0.01)
    }

    // MARK: - completeRefresh provider_breakdown fallback

    func testCompleteRefreshSynthesisesProviderBreakdownFromProviders() {
        let state = AppState()
        state.providerConfigs = [
            ProviderConfig(kind: .claude, isEnabled: true),
            ProviderConfig(kind: .codex,  isEnabled: true),
        ]
        state.providers = [
            usage("Claude", plan: "Pro", today: 1_200, todayCost: 0.5),
            usage("Codex",  plan: "Pro", today: 3_400, todayCost: 1.5),
        ]
        state.costUsageScanResult = nil
        state.dashboard = DashboardSummary(
            total_usage_today: 0,
            total_estimated_cost_today: 0,
            cost_status: "Estimated",
            total_requests_today: 0,
            active_sessions: 0,
            online_devices: 0,
            unresolved_alerts: 0,
            provider_breakdown: [],        // <-- the bug: cloud dashboard returns this empty
            top_projects: [],
            trend: [],
            recent_activity: [],
            risk_signals: [],
            alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0)
        )

        state.completeRefresh()

        let rebuilt = state.dashboard?.provider_breakdown ?? []
        XCTAssertEqual(rebuilt.count, 2,
                       "completeRefresh must synthesise provider_breakdown when cloud ships []")
        let byName = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.provider, $0) })
        XCTAssertEqual(byName["Claude"]?.usage, 1_200)
        XCTAssertEqual(byName["Claude"]?.estimated_cost ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(byName["Codex"]?.usage, 3_400)
        XCTAssertEqual(byName["Codex"]?.estimated_cost ?? 0, 1.5, accuracy: 0.001)
    }

    func testCompleteRefreshPreservesExistingProviderBreakdown() {
        let state = AppState()
        state.providerConfigs = [ProviderConfig(kind: .claude, isEnabled: true)]
        state.providers = [usage("Claude", plan: "Pro", today: 99, todayCost: 9.9)]
        state.costUsageScanResult = nil

        let existing = ProviderBreakdown(
            provider: "Claude", usage: 42, estimated_cost: 1.23,
            cost_status: "Exact", remaining: nil
        )
        state.dashboard = DashboardSummary(
            total_usage_today: 0,
            total_estimated_cost_today: 0,
            cost_status: "Estimated",
            total_requests_today: 0,
            active_sessions: 0, online_devices: 0, unresolved_alerts: 0,
            provider_breakdown: [existing],
            top_projects: [], trend: [], recent_activity: [], risk_signals: [],
            alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0)
        )

        state.completeRefresh()

        XCTAssertEqual(state.dashboard?.provider_breakdown.count, 1)
        XCTAssertEqual(state.dashboard?.provider_breakdown.first?.usage, 42,
                       "existing non-empty provider_breakdown must survive the rebuild")
        XCTAssertEqual(state.dashboard?.provider_breakdown.first?.estimated_cost ?? 0, 1.23,
                       accuracy: 0.001)
    }
}

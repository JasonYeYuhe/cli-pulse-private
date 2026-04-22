import Foundation
import Combine

/// v1.10 P2-3 slice 5: final P2-3 extraction. Provider-related observable
/// state lives here so the Providers tab, Overview tab, Settings → Providers
/// section, and provider-config editor re-render on provider changes only,
/// instead of on every unrelated `AppState` mutation.
///
/// `AppState` still owns the canonical instance (`public let providerState`)
/// and exposes the 5 fields as computed forwarders so internal callers
/// (`DataRefreshManager` inside `extension AppState`, `DemoDataProvider`,
/// `setProviderEnabled`, `toggleProvider`, etc.) keep mutating through
/// implicit `self`.
///
/// The MenuBarLabel view must also observe this state — `menuBarIcon` reads
/// `mostUsedProvider` which in turn reads `providers` and
/// `enabledProviderNames` (computed from `providerConfigs`). Without the
/// observer, the menu-bar icon wouldn't refresh when a provider's usage
/// changes.
@MainActor
public final class ProviderState: ObservableObject {
    @Published public var providers: [ProviderUsage] = []
    @Published public var providerConfigs: [ProviderConfig] = ProviderConfig.defaults()
    @Published public var providerDetails: [ProviderDetail] = []
    @Published public var costSummary: CostSummary = CostSummary()
    /// Which provider the standalone "Provider Settings" window is editing, if any.
    /// Read by the Window scene in `CLIPulseBarApp`; written by Settings → gear buttons.
    @Published public var editingProviderKind: ProviderKind?

    public init() {}

    /// Convenience derived from `providerConfigs`. Mirrors
    /// `AppState.enabledProviderNames` so callers that observe `ProviderState`
    /// directly don't have to route through `AppState.objectWillChange`
    /// (which would no longer fire for `providerConfigs` changes after the
    /// P2-3 slice 5 extraction).
    public var enabledProviderNames: Set<String> {
        Set(providerConfigs.filter(\.isEnabled).map(\.kind.rawValue))
    }
}

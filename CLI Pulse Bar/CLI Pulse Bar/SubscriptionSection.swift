import SwiftUI
import StoreKit
import CLIPulseCore

/// v1.10 P2-2 slice 3: extracted from SettingsTab.swift (pre-extraction
/// `subscriptionSection` + `inlineIAPCards` + `inlineProductRow` + `iapError`
/// state). Shows current plan, quotas, Manage button for Pro/Team, or inline
/// IAP purchase cards for free-tier users.
struct SubscriptionSection: View {
    @EnvironmentObject var state: AppState
    /// v1.10 P2-3 slice 2: observe SubscriptionManager directly instead of
    /// relying on AppState's old `subscriptionCancellable.sink` forwarder.
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.openWindow) private var openWindow
    @State private var iapError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.settings.subscription, icon: "creditcard")

            HStack {
                Text(L10n.settings.currentPlan)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                SubscriptionBadge(tier: subscriptionManager.currentTier)
            }

            HStack {
                Text(L10n.settings.providers)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(subscriptionManager.maxProviders < 0 ? "Unlimited" : "\(subscriptionManager.maxProviders)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.settings.devices)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(subscriptionManager.maxDevices < 0 ? "Unlimited" : "\(subscriptionManager.maxDevices)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.settings.dataRetention)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(subscriptionManager.dataRetentionDays) \(L10n.settings.days)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if subscriptionManager.isProOrAbove {
                Button {
                    openWindow(id: "subscription")
                } label: {
                    Label(L10n.settings.manageSubscription, systemImage: "gear")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            } else {
                if subscriptionManager.products.isEmpty {
                    if subscriptionManager.isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(L10n.subscription.loadingPlans)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L10n.subscription.unavailable)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await subscriptionManager.loadProducts() }
                        } label: {
                            Text(L10n.subscription.retry)
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PulseTheme.accent)
                    }
                } else {
                    inlineIAPCards
                }

                if let iapError {
                    Text(iapError)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }

                Button {
                    openWindow(id: "subscription")
                } label: {
                    Text(L10n.subscription.viewAllPlans)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            }
        }
    }

    private var inlineIAPCards: some View {
        VStack(spacing: 6) {
            if let pro = subscriptionManager.proMonthly {
                inlineProductRow(product: pro, label: "Pro Monthly", features: "Unlimited providers, 5 devices")
            }
            if let proY = subscriptionManager.proYearly {
                inlineProductRow(product: proY, label: "Pro Yearly", features: "Save 17%")
            }
            if let team = subscriptionManager.teamMonthly {
                inlineProductRow(product: team, label: "Team Monthly", features: "Unlimited everything, team features")
            }
            if let teamY = subscriptionManager.teamYearly {
                inlineProductRow(product: teamY, label: "Team Yearly", features: "Save 17%")
            }
        }
    }

    private func inlineProductRow(product: Product, label: String, features: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                Text(features)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task {
                    iapError = nil
                    do {
                        _ = try await subscriptionManager.purchase(product)
                    } catch {
                        iapError = error.localizedDescription
                    }
                }
            } label: {
                Text(product.displayPrice)
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .controlSize(.small)
        }
        .padding(6)
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

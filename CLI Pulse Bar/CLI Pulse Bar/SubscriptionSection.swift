import SwiftUI
import StoreKit
import CLIPulseCore

/// v1.10 P2-2 slice 3: extracted from SettingsTab.swift (pre-extraction
/// `subscriptionSection` + `inlineIAPCards` + `inlineProductRow` + `iapError`
/// state). Shows current plan, quotas, Manage button for Pro/Team, or inline
/// IAP purchase cards for free-tier users.
struct SubscriptionSection: View {
    @EnvironmentObject var state: AppState
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
                SubscriptionBadge(tier: state.subscriptionManager.currentTier)
            }

            HStack {
                Text(L10n.settings.providers)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.subscriptionManager.maxProviders < 0 ? "Unlimited" : "\(state.subscriptionManager.maxProviders)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.settings.devices)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.subscriptionManager.maxDevices < 0 ? "Unlimited" : "\(state.subscriptionManager.maxDevices)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.settings.dataRetention)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(state.subscriptionManager.dataRetentionDays) \(L10n.settings.days)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if state.subscriptionManager.isProOrAbove {
                Button {
                    openWindow(id: "subscription")
                } label: {
                    Label(L10n.settings.manageSubscription, systemImage: "gear")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            } else {
                if state.subscriptionManager.products.isEmpty {
                    if state.subscriptionManager.isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading plans...")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Subscription plans are not available at this time.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await state.subscriptionManager.loadProducts() }
                        } label: {
                            Text("Retry")
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
                    Text("View all plans & details")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            }
        }
    }

    private var inlineIAPCards: some View {
        VStack(spacing: 6) {
            if let pro = state.subscriptionManager.proMonthly {
                inlineProductRow(product: pro, label: "Pro Monthly", features: "Unlimited providers, 5 devices")
            }
            if let proY = state.subscriptionManager.proYearly {
                inlineProductRow(product: proY, label: "Pro Yearly", features: "Save 17%")
            }
            if let team = state.subscriptionManager.teamMonthly {
                inlineProductRow(product: team, label: "Team Monthly", features: "Unlimited everything, team features")
            }
            if let teamY = state.subscriptionManager.teamYearly {
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
                        _ = try await state.subscriptionManager.purchase(product)
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

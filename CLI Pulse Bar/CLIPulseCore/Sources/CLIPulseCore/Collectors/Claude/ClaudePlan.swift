// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Claude/ClaudePlan.swift
// (https://github.com/steipete/CodexBar). Vendored verbatim except for
// the project-style adjustments noted below.
//
// CodexBar-parity Phase A / G2 — Anthropic plan-tier normalization
// (Free/Pro/Max/Team/Enterprise/Ultra) from raw OAuth `rateLimitTier`,
// `subscriptionType`, web billing fields and CLI login-method strings.
//
// We deliberately keep the public surface 1:1 with CodexBar's so that
// future cherry-picks remain low-effort. The only divergences are:
//   * file lives in CLIPulseCore (shared macOS + iOS + watchOS) — NOT
//     `#if os(macOS)` gated; it is pure Foundation
//   * UTF-8 BOM-free / 4-space style
//   * `brandedLoginMethod` / `compactLoginMethod` return brand proper
//     nouns ("Claude Max", "Max", …) and are intentionally NOT routed
//     through L10n (same rationale as ClaudePeakHours' brand strings)
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Foundation

public enum ClaudePlan: String, CaseIterable, Sendable {
    case max
    case pro
    case team
    case enterprise
    case ultra

    public var brandedLoginMethod: String {
        switch self {
        case .max:
            "Claude Max"
        case .pro:
            "Claude Pro"
        case .team:
            "Claude Team"
        case .enterprise:
            "Claude Enterprise"
        case .ultra:
            "Claude Ultra"
        }
    }

    public var compactLoginMethod: String {
        switch self {
        case .max:
            "Max"
        case .pro:
            "Pro"
        case .team:
            "Team"
        case .enterprise:
            "Enterprise"
        case .ultra:
            "Ultra"
        }
    }

    public var countsAsSubscription: Bool {
        switch self {
        case .max, .pro, .team, .ultra:
            true
        case .enterprise:
            false
        }
    }

    public static func fromOAuthRateLimitTier(_ rateLimitTier: String?) -> Self? {
        self.fromRateLimitTier(rateLimitTier)
    }

    public static func fromOAuthCredentials(subscriptionType: String?, rateLimitTier: String?) -> Self? {
        self.fromCompatibilityLoginMethod(subscriptionType)
            ?? self.fromOAuthRateLimitTier(rateLimitTier)
    }

    public static func fromWebAccount(rateLimitTier: String?, billingType: String?) -> Self? {
        if let plan = self.fromRateLimitTier(rateLimitTier) {
            return plan
        }

        let tier = Self.normalized(rateLimitTier)
        let billing = Self.normalized(billingType)
        if billing.contains("stripe"), tier.contains("claude") {
            return .pro
        }
        return nil
    }

    public static func fromCompatibilityLoginMethod(_ loginMethod: String?) -> Self? {
        let words = Self.normalizedWords(loginMethod)
        if words.isEmpty {
            return nil
        }
        if words.contains("max") {
            return .max
        }
        if words.contains("pro") {
            return .pro
        }
        if words.contains("team") {
            return .team
        }
        if words.contains("enterprise") {
            return .enterprise
        }
        if words.contains("ultra") {
            return .ultra
        }
        return nil
    }

    public static func oauthLoginMethod(rateLimitTier: String?) -> String? {
        self.fromOAuthRateLimitTier(rateLimitTier)?.brandedLoginMethod
    }

    public static func oauthLoginMethod(subscriptionType: String?, rateLimitTier: String?) -> String? {
        self.fromOAuthCredentials(
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier)?.brandedLoginMethod
    }

    public static func webLoginMethod(rateLimitTier: String?, billingType: String?) -> String? {
        self.fromWebAccount(rateLimitTier: rateLimitTier, billingType: billingType)?.brandedLoginMethod
    }

    public static func cliCompatibilityLoginMethod(_ loginMethod: String?) -> String? {
        guard let loginMethod = loginMethod?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loginMethod.isEmpty
        else {
            return nil
        }

        if let plan = self.fromCompatibilityLoginMethod(loginMethod) {
            return plan.compactLoginMethod
        }

        return loginMethod
    }

    public static func isSubscriptionLoginMethod(_ loginMethod: String?) -> Bool {
        self.fromCompatibilityLoginMethod(loginMethod)?.countsAsSubscription ?? false
    }

    private static func fromRateLimitTier(_ rateLimitTier: String?) -> Self? {
        let tier = Self.normalized(rateLimitTier)
        if tier.contains("max") {
            return .max
        }
        if tier.contains("pro") {
            return .pro
        }
        if tier.contains("team") {
            return .team
        }
        if tier.contains("enterprise") {
            return .enterprise
        }
        return nil
    }

    private static func normalized(_ text: String?) -> String {
        text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedWords(_ text: String?) -> [String] {
        self.normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

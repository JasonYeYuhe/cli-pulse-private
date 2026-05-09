# PROJECT_PLAN — v1.14 Pro Lifetime IAP

Date: 2026-05-08
Branch: `v1.14-lifetime-iap` (to create)

## Context

ASC pricing changes for v1.13 are scheduled to take effect 2026-05-09:
- Pro Monthly ¥8 / $0.99 USD
- Pro Yearly ¥88 / $12.99 USD
- Team Monthly ¥16 / $1.99 USD
- Team Yearly ¥176 / $24.99 USD

In addition, a Non-Consumable IAP draft was created (NOT submitted for review):
- Reference Name: CLI Pulse Pro Lifetime
- Product ID: `com.clipulse.pro.lifetime`
- Apple ID: 6767441323
- Type: Non-Consumable
- Base Price: ¥128.00 CNY (China mainland) → $19.99 USD globally
- Status: "Prepare for Submission" (saved as draft)
- Localization: English (U.S.)

The v1.13 binary does not reference this product ID. v1.14 wires it through SubscriptionManager + UI + backend validate-receipt. Submission for review happens once code work is verified end-to-end against StoreKit Sandbox.

## Scope

iOS, macOS, watchOS clients only. Android (Google Play) keeps subscription-only.

## Backend changes

### Edge function: `validate-receipt`

[backend/supabase/functions/validate-receipt/index.ts](backend/supabase/functions/validate-receipt/index.ts):

1. Extend `PRODUCT_TIER_MAP` (line 49):
   ```ts
   const PRODUCT_TIER_MAP: Record<string, string> = {
     "com.clipulse.pro.monthly": "pro",
     "com.clipulse.pro.yearly": "pro",
     "com.clipulse.team.monthly": "team",
     "com.clipulse.team.yearly": "team",
     "com.clipulse.pro.lifetime": "pro",
   };
   ```

2. Lifetime IAPs are Non-Consumable, so `payload.expiresDate` is undefined.
   The existing check `if (payload.expiresDate && payload.expiresDate < Date.now())` already
   skips correctly (falsy → branch not taken).

3. Add a defensive guard so verifyAndDecodeTransaction's lifetime payloads aren't accidentally
   rejected by future logic that assumes a subscription:
   ```ts
   const isLifetime = productId === "com.clipulse.pro.lifetime";
   ```
   Use this flag to skip subscription-renewal-status checks if any are added later.

### Database schema

**REQUIRES USER APPROVAL** (per `feedback_cli_pulse_autonomy.md` — backend schema is one of the 3
gated categories).

Add an `is_lifetime` boolean column to `subscriptions` for clean queries:

```sql
ALTER TABLE subscriptions
  ADD COLUMN IF NOT EXISTS is_lifetime BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_subscriptions_is_lifetime
  ON subscriptions (user_id) WHERE is_lifetime = TRUE;
```

Alternative (no schema change): rely on `apple_product_id = 'com.clipulse.pro.lifetime' AND
expires_at IS NULL` as the lifetime selector. Cleaner but couples query to product ID strings.

**Recommended:** add `is_lifetime` — matches the explicitness elsewhere in the schema, and
isolates ASC product-ID changes from the storage layer.

### Server tier RPC: `get_user_tier`

If the server tier RPC currently picks the highest active subscription by `expires_at >= now()`,
it must also treat `is_lifetime = TRUE` rows as active without an expiry check. Audit the
function body before merging.

## Swift client changes

### CLIPulseCore/SubscriptionManager.swift

Lines 78-85: add product ID + extend the set:

```swift
public static let proLifetimeID = "com.clipulse.pro.lifetime"

private static let allProductIDs: Set<String> = [
    proMonthlyID, proYearlyID, teamMonthlyID, teamYearlyID, proLifetimeID
]
```

Lines 131-134: add accessor:

```swift
public var proLifetime: Product? { products.first { $0.id == Self.proLifetimeID } }
```

Lines 196-225: extend `updateCurrentEntitlements` to recognize Non-Consumable lifetime txns.

Currently the loop only inspects `transaction.productType == .autoRenewable`. Lifetime
transactions arrive as `.nonConsumable` and never expire — they appear once in
`Transaction.currentEntitlements` and stay there.

```swift
for await result in StoreKit.Transaction.currentEntitlements {
    guard let transaction = try? checkVerified(result) else { continue }

    let txTier: SubscriptionTier?
    let isLifetime: Bool
    switch transaction.productType {
    case .autoRenewable:
        activeSubs.append(transaction)
        if transaction.productID == Self.teamMonthlyID ||
           transaction.productID == Self.teamYearlyID {
            txTier = .team
        } else if transaction.productID == Self.proMonthlyID ||
                  transaction.productID == Self.proYearlyID {
            txTier = .pro
        } else {
            txTier = nil
        }
        isLifetime = false
    case .nonConsumable where transaction.productID == Self.proLifetimeID:
        activeSubs.append(transaction)
        txTier = .pro
        isLifetime = true
    default:
        txTier = nil
        isLifetime = false
    }

    if let txTier, txTier.tierRank > highestTier.tierRank {
        highestTier = txTier
        highestJWS = result.jwsRepresentation
        highestProductID = transaction.productID
    }
    // For lifetime, we still want server to record the purchase so admin
    // can refund/revoke. Validate-receipt handles that branch.
}
```

Add a `@Published public var isLifetime: Bool = false` so UI can render the right CTA
("You own Lifetime — thank you" instead of an upgrade button).

### CLIPulseCore/SubscriptionView.swift + CLI Pulse Bar/SubscriptionSection.swift + CLI Pulse Bar iOS/iOSSettingsTab.swift

Add a Lifetime tile/row to the paywall, visually distinct from monthly/yearly:

- Title: "Pro Lifetime"
- Price: `proLifetime?.displayPrice ?? "¥128"` 
- Badge: "One-time" (NOT "save XX%")
- Description: "Pro features forever, all platforms"
- Tap → `purchase(proLifetime)` flow

Hide the Lifetime tile when `currentTier == .team` (Team is strictly better) or when
`isLifetime == true` (already owns it — show "Owned" instead).

### Localization strings (Localizable.strings)

Add:
- `subscription.lifetime` = "Lifetime"
- `subscription.lifetimeDescription` = "One-time purchase. Pro features forever."
- `subscription.lifetimeOwned` = "You own Pro Lifetime"
- All current locales: en, zh-Hans, zh-Hant, ja, ko, fr, de, es, it, pt-BR, ru

### Tests (CLIPulseCore/Tests/CLIPulseCoreTests/SubscriptionTierResolutionTests.swift)

Cases to add:
- Lifetime txn alone → `currentTier = .pro, isLifetime = true, resolution = .resolvedConfirmed`
- Lifetime + active Pro Yearly → still `.pro`, `isLifetime = true` (lifetime "wins" the
  display, but storage retains both)
- Lifetime + active Team subscription → `.team` (Team tier outranks Pro; lifetime stays
  as a fallback if Team lapses)
- Lifetime txn but server validateReceipt errors → `.resolvedDegraded` with
  `lastTierRefreshSource = "local-only-fallback"` — same path as subscriptions

## ASC submission (post-code-merge)

1. After v1.14 binary built and TestFlight-verified against Sandbox lifetime purchase,
   navigate ASC → In-App Purchases → CLI Pulse Pro Lifetime.
2. Verify Tax Category, Review Notes, Sandbox screenshot.
3. Click "Submit for Review" — bundles with the v1.14 app submission OR submits
   independently (Apple now allows IAP-only submissions).

## Risk & rollback

- StoreKit Non-Consumable behavior on macOS: family sharing OFF (we did not enable it
  in the IAP draft — confirm before launch).
- If a user cross-platform-buys Lifetime on iOS then signs in on macOS, the Sandbox
  doesn't always cross-propagate immediately. Settings should expose "Restore Purchases"
  prominently, which already calls `AppStore.sync()` + `updateCurrentEntitlements()`.
- Refund handling: if Apple refunds a lifetime purchase, `Transaction.currentEntitlements`
  drops it; the listener in `listenForTransactions()` re-runs entitlement update.
  No special code path needed.
- Backend rollback: deleting `is_lifetime` column would re-orphan lifetime users.
  Use a feature flag in validate-receipt instead — env var `LIFETIME_ENABLED` (default
  off) lets us disable lifetime purchases server-side without removing column.

## Out of scope for v1.14

- Promotional code redemptions for Lifetime (offer codes were not configured in the IAP)
- Family Sharing (deliberately off)
- Refund-from-app UX (relies on the App Store refund flow)
- Web pricing-page Lifetime tile (cli-pulse marketing site is a separate repo)

## Verification checklist

- [ ] Sandbox: Buy Lifetime → tier reads `.pro`, `isLifetime=true`, paywall hidden
- [ ] Sandbox: Buy Lifetime then Buy Pro Yearly → still `.pro`, `isLifetime=true`
- [ ] Sandbox: Buy Lifetime then Buy Team Monthly → `.team` displayed
- [ ] Sandbox: Refund Lifetime via App Store → tier drops back to `.free` within ~10s
- [ ] Server: validateReceipt with `com.clipulse.pro.lifetime` returns `verified=true, tier=pro`
- [ ] Server: subscriptions row has `is_lifetime=true, expires_at=null`
- [ ] UI: Settings shows "You own Pro Lifetime" instead of upgrade buttons when owned
- [ ] All localizations show Lifetime tile correctly
- [ ] Tests: SubscriptionTierResolutionTests covers all 4 lifetime cases above
- [ ] Build: macOS, iOS, watchOS all archive and TestFlight-verify

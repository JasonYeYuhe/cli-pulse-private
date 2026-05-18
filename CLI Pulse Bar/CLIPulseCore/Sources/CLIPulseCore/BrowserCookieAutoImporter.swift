// CodexBar-parity Phase A / G1 — macOS browser-cookie auto-import.
//
// Design derived from steipete/CodexBar's per-browser import flow
// (Sources/CodexBarCore/Providers/*/<X>StatusProbe.swift +
// BrowserCookieImportOrder.swift) and built on SweetCookieKit
// (https://github.com/steipete/SweetCookieKit). Both are MIT-licensed,
// © Peter Steinberger. We do not vendor their source verbatim here; we
// re-implement the orchestration against the public SweetCookieKit API.
//
// ─── MIT License (upstream notice) ────────────────────────────────
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

#if os(macOS) && canImport(SweetCookieKit)
import Foundation
import SweetCookieKit

/// SweetCookieKit-backed `CookieImporting` for macOS.
///
/// An `actor` so the per-process "this browser already denied access this
/// run" memo (D1 — avoids re-triggering a Keychain/FDA failure on every
/// refresh tick) is data-race-free. A full persistent cooldown
/// (CodexBar's `BrowserCookieAccessGate`) is deferred to a later phase.
public actor BrowserCookieAutoImporter: CookieImporting {
    public static let shared = BrowserCookieAutoImporter()

    /// Browsers tried, in priority order. The common ones first; the long
    /// tail (betas/canaries/niche) appended so nothing is silently skipped.
    private static let browserOrder: [Browser] = {
        let primary: [Browser] = [
            .safari, .chrome, .arc, .brave, .edge, .firefox, .zen,
            .chromium, .vivaldi, .dia, .comet, .helium
        ]
        let rest = Browser.allCases.filter { !primary.contains($0) }
        return primary + rest
    }()

    /// Browsers that returned `.accessDenied` during this process run.
    /// Skipped on subsequent calls so a denied Keychain/FDA prompt is not
    /// re-attempted on every refresh cycle (D1).
    private var deniedThisRun: Set<Browser> = []

    public init() {}

    public func importCookieHeader(
        domains: [String],
        knownSessionCookieNames: Set<String>,
        logger: (@Sendable (String) -> Void)?
    ) async -> String? {
        let log: (String) -> Void = { msg in logger?("[cookie-auto] \(msg)") }
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: domains, domainMatch: .contains)

        for browser in Self.browserOrder where !deniedThisRun.contains(browser) {
            do {
                let cookies = try client.cookies(matching: query, in: browser)
                guard !cookies.isEmpty else { continue }

                // If the provider declares known session-cookie names,
                // require at least one — avoids picking up a stale/
                // logged-out browser's unrelated cookies for the domain.
                if !knownSessionCookieNames.isEmpty {
                    guard cookies.contains(where: { knownSessionCookieNames.contains($0.name) })
                    else {
                        log("\(browser.displayName): cookies present but no known session name")
                        continue
                    }
                }

                let header = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                if !header.isEmpty {
                    log("imported via \(browser.displayName)")
                    return header
                }
            } catch let error as BrowserCookieError {
                switch error {
                case .accessDenied:
                    deniedThisRun.insert(browser)
                    log("\(browser.displayName): access denied (FDA/Keychain) — skipped this run")
                case .notFound:
                    log("\(browser.displayName): no cookie store")
                case let .loadFailed(_, details):
                    log("\(browser.displayName): load failed: \(details)")
                }
            } catch {
                log("\(browser.displayName): \(error.localizedDescription)")
            }
        }
        return nil
    }
}
#endif

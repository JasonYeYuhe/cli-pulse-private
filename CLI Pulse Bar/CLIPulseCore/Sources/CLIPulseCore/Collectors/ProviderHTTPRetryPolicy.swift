// Derived from steipete/CodexBar
// Sources/CodexBarCore/ProviderHTTPClient.swift
// (https://github.com/steipete/CodexBar), upstream commit 94f831a2 —
// "Retry transient OpenAI usage failures (#1117)".
//
// CodexBar-parity v1.24 Phase 1 Item #6 — retry transient HTTP failures
// (408 / 429 / 500 / 502 / 503 / 504 + network timeout-class URLErrors) for
// idempotent GET requests, honoring `Retry-After` and exponential backoff.
//
// Divergences from upstream:
//   * CLI Pulse has no `ProviderHTTPTransport` protocol; we wrap
//     `URLSession.data(for:)` directly via a free function
//     `httpDataWithRetry(_:retryPolicy:)`. Other collectors
//     (Azure, Volcano, Mistral, etc.) can adopt at will.
//   * macOS-gated to match the rest of the collectors layer.
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

#if os(macOS)
import Foundation

public struct ProviderHTTPRetryPolicy: Sendable {
    public let maxRetries: Int
    public let retryableStatusCodes: Set<Int>
    public let retryableURLErrorCodes: Set<URLError.Code>
    public let retryableMethods: Set<String>
    public let baseDelaySeconds: TimeInterval
    public let maxDelaySeconds: TimeInterval

    public init(
        maxRetries: Int,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        retryableURLErrorCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
        ],
        retryableMethods: Set<String> = ["GET", "HEAD", "OPTIONS"],
        baseDelaySeconds: TimeInterval = 1,
        maxDelaySeconds: TimeInterval = 10)
    {
        self.maxRetries = max(0, maxRetries)
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
        self.retryableMethods = retryableMethods
        self.baseDelaySeconds = max(0, baseDelaySeconds)
        self.maxDelaySeconds = max(0, maxDelaySeconds)
    }

    public static let disabled = ProviderHTTPRetryPolicy(
        maxRetries: 0,
        retryableStatusCodes: [],
        retryableURLErrorCodes: [],
        baseDelaySeconds: 0,
        maxDelaySeconds: 0)

    public static let transientIdempotent = ProviderHTTPRetryPolicy(maxRetries: 1)

    func shouldRetry(request: URLRequest, attempt: Int, statusCode: Int) -> Bool {
        canRetry(request: request, attempt: attempt)
            && retryableStatusCodes.contains(statusCode)
    }

    func shouldRetry(request: URLRequest, attempt: Int, error: Error) -> Bool {
        guard canRetry(request: request, attempt: attempt) else { return false }
        guard let urlError = error as? URLError else { return false }
        return retryableURLErrorCodes.contains(urlError.code)
    }

    func delaySeconds(attempt: Int, response: HTTPURLResponse?) -> TimeInterval {
        if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds >= 0
        {
            return min(seconds, maxDelaySeconds)
        }

        guard baseDelaySeconds > 0 else { return 0 }
        let multiplier = pow(2, Double(max(0, attempt)))
        return min(baseDelaySeconds * multiplier, maxDelaySeconds)
    }

    private func canRetry(request: URLRequest, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        let method = request.httpMethod?.uppercased() ?? "GET"
        return retryableMethods.contains(method)
    }
}

/// Wraps `URLSession.data(for:)` with retry semantics from
/// `ProviderHTTPRetryPolicy`. Transient HTTP failures (408/429/5xx) and
/// network-timeout-class errors retry up to `policy.maxRetries` times with
/// exponential backoff (capped) and `Retry-After` header honoring; the final
/// attempt's response (or thrown error) is returned to the caller.
public func httpDataWithRetry(
    _ request: URLRequest,
    retryPolicy: ProviderHTTPRetryPolicy,
    session: URLSession = .shared) async throws -> (Data, URLResponse)
{
    var attempt = 0

    while true {
        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0
            guard retryPolicy.shouldRetry(request: request, attempt: attempt, statusCode: status) else {
                return (data, response)
            }
            try await sleepBeforeRetry(policy: retryPolicy, attempt: attempt, response: httpResponse)
            attempt += 1
        } catch {
            guard retryPolicy.shouldRetry(request: request, attempt: attempt, error: error) else {
                throw error
            }
            try await sleepBeforeRetry(policy: retryPolicy, attempt: attempt, response: nil)
            attempt += 1
        }
    }
}

private func sleepBeforeRetry(
    policy: ProviderHTTPRetryPolicy,
    attempt: Int,
    response: HTTPURLResponse?) async throws
{
    let delay = policy.delaySeconds(attempt: attempt, response: response)
    guard delay > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
}
#endif

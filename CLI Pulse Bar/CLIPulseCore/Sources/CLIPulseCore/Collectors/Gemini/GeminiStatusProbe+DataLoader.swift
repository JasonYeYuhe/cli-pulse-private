// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe+DataLoader.swift
// (https://github.com/steipete/CodexBar).
//
// CodexBar-parity Phase A / G3 — default network loader for the probe.
//
// Divergence from upstream (Gemini 3.1 Pro review Q1): the entire curl
// fallback API (`dataLoaderWithCurlFallback`, `isURLSessionTimeout`,
// `curlDataLoader` + helpers) is dropped — it depended on CodexBar's
// `SubprocessRunner`/`ProviderHTTPClient`/`TTYCommandRunner` infra and
// keeping the wrapper without the fallback would be misleading dead code.
// `defaultDataLoader` delegates straight to `URLSession`.
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

extension GeminiStatusProbe {
    public static func defaultDataLoader(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

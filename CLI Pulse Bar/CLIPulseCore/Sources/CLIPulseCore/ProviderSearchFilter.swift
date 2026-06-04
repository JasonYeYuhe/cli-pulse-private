import Foundation

/// Pure, locale-aware filtering for the Providers tab search field (macOS +
/// iOS). With up to 48 tracked providers, the tab adds a name search on top of
/// the existing enabled/disabled filter. Extracted as a pure function so the
/// matching rule is unit-tested once and shared by both tabs.
public enum ProviderSearchFilter {
    /// Case- and diacritic-insensitive substring match of `query` against any
    /// of `fields`. An empty / whitespace-only query matches everything, so the
    /// list is unfiltered until the user types.
    public static func matches(query: String, in fields: [String]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return fields.contains { field in
            field.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Convenience for the common single-field (provider display name) case.
    public static func matches(providerName: String, query: String) -> Bool {
        matches(query: query, in: [providerName])
    }
}

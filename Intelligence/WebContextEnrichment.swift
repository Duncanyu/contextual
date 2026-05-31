import Foundation

/// One enrichment entry pulled from a public, no-key encyclopedia source.
/// All fields are public-info only — terms come from topic-term aggregation
/// (never selected text, never clipboard, never raw OCR sentences).
struct WebContextEntry: Sendable, Codable, Equatable {
    /// The lowercased topic term that produced this entry.
    let term: String
    /// Canonical title from the source (e.g. "Anker Innovations").
    let title: String
    /// Short prose extract, hard-capped server-side and again locally.
    let extract: String
    /// Identifier for the source ("wikipedia"). Always present in the
    /// rendered output so the user can tell what came from the screen vs.
    /// what came from the public web.
    let source: String
    /// Canonical public URL the user can visit themselves.
    let url: String
}

/// Result of a single enrichment attempt. Empty when enrichment was skipped
/// (sensitive workflow, env-disabled, no eligible terms) or when no source
/// returned a usable entry.
struct WebContextEnrichment: Sendable, Codable, Equatable {
    let entries: [WebContextEntry]
    /// Why this enrichment returned the result it did. Useful for logs:
    /// "fetched", "cached", "skipped_sensitive", "skipped_env_disabled",
    /// "skipped_no_eligible_terms", "no_results".
    let reason: String

    static let empty = WebContextEnrichment(entries: [], reason: "no_results")
}

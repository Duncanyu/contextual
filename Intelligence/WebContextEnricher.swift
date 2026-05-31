import Foundation

/// Passive public-web context enrichment for the `ContextExecutionEngine`.
///
/// Design constraints (Phase 18C grounding-quality fix):
/// - **No API keys.** Uses Wikipedia's open REST summary endpoint.
/// - **No browser control.** Just an HTTPS GET to a public source.
/// - **No private content leaves the device.** Only short, lowercased topic
///   terms from the temporal packet are sent. Never selected text, never
///   clipboard, never raw OCR sentences, never window titles, never URLs.
/// - **Hard sensitive-workflow gate.** Skipped entirely for emailing /
///   writing / coding / debugging / meeting.
/// - **Tight timeout** (1.5 s per request) and **in-memory cache** (1 hour)
///   so we never block the engine.
/// - **Kill switch.** Disabled by `CONTEXTUAL_AMBIENT_WEB_ENRICH=0`. Default
///   ON for shopping/researching/reading/studying/comparing/browsing/watching.
actor WebContextEnricher {

    static let shared = WebContextEnricher()

    // MARK: - Configuration

    /// Workflows where enrichment is NEVER attempted. Even if the user's
    /// topic terms look "public", we never want to leak that they were in
    /// these contexts.
    private static let sensitiveWorkflows: Set<AmbientWorkflowType> = [
        .emailing, .writing, .coding, .debugging, .meeting,
    ]

    /// Per-request timeout. Engine is debounced; if we exceed this, drop.
    private static let timeoutSeconds: TimeInterval = 1.5

    /// Cache TTL — public encyclopedic content rarely changes hour-to-hour.
    private static let cacheTTL: TimeInterval = 3600

    /// Common-noise topic terms we never query — they would either return
    /// nothing useful or pollute output with platform descriptions.
    private static let stopTerms: Set<String> = [
        "amazon", "google", "youtube", "facebook", "twitter", "reddit",
        "page", "tab", "browser", "window", "site", "view", "home",
        "click", "open", "search", "results", "next", "back",
        // Phase 18C: ambiguous low-precision terms (avoid false grounding).
        "bank", "prime", "with", "laptop", "phone", "apple",
    ]

    /// Maximum number of distinct terms we will query per tick.
    private static let maxTermsPerCall = 2

    // MARK: - Cache

    private struct CacheEntry {
        let entries: [WebContextEntry]
        let storedAt: Date
    }
    private var cache: [String: CacheEntry] = [:]

    // MARK: - Public API

    func enrich(
        terms: [String],
        workflowType: AmbientWorkflowType,
        now: Date = Date()
    ) async -> WebContextEnrichment {
        // Phase 18C grounding fix: Wikipedia is low-precision for product contexts.
        // It frequently causes false grounding when the term picker selects ambiguous
        // tokens like "bank" (power bank) or "prime" (brand line).
        if workflowType == .shopping || workflowType == .comparing {
            print("[WebContextEnricher] skipped reason=low_precision_for_product_context")
            return WebContextEnrichment(entries: [], reason: "skipped_low_precision_for_product_context")
        }
        // 1. Sensitive-workflow gate (cannot be overridden).
        if Self.sensitiveWorkflows.contains(workflowType) {
            print("[WebContextEnricher] skipped reason=sensitive_workflow workflow=\(workflowType.rawValue)")
            return WebContextEnrichment(entries: [], reason: "skipped_sensitive")
        }
        // 2. Kill switch.
        if !Self.isEnabledByEnv() {
            print("[WebContextEnricher] skipped reason=env_disabled workflow=\(workflowType.rawValue)")
            return WebContextEnrichment(entries: [], reason: "skipped_env_disabled")
        }
        // 3. Term eligibility.
        let queryTerms = Self.selectQueryTerms(terms)
        if queryTerms.isEmpty {
            print("[WebContextEnricher] skipped reason=no_eligible_terms workflow=\(workflowType.rawValue)")
            return WebContextEnrichment(entries: [], reason: "skipped_no_eligible_terms")
        }

        // 4. Cache lookup.
        let cacheKey = queryTerms.joined(separator: "|")
        if let entry = cache[cacheKey], now.timeIntervalSince(entry.storedAt) < Self.cacheTTL {
            print("[WebContextEnricher] cached terms=\(queryTerms.joined(separator: ",")) entries=\(entry.entries.count)")
            return WebContextEnrichment(entries: entry.entries, reason: "cached")
        }

        // 5. Fetch.
        var entries: [WebContextEntry] = []
        for term in queryTerms {
            if let entry = await Self.fetchWikipediaSummary(term: term) {
                entries.append(entry)
            }
        }

        // 6. Cache (even empty result, so we don't retry on every tick).
        cache[cacheKey] = CacheEntry(entries: entries, storedAt: now)
        let reason = entries.isEmpty ? "no_results" : "fetched"
        print("[WebContextEnricher] \(reason) terms=\(queryTerms.joined(separator: ",")) entries=\(entries.count)")
        return WebContextEnrichment(entries: entries, reason: reason)
    }

    // MARK: - Internals

    nonisolated private static func isEnabledByEnv() -> Bool {
        let raw = ProcessInfo.processInfo.environment["CONTEXTUAL_AMBIENT_WEB_ENRICH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw == "0" || raw == "no" || raw == "false" { return false }
        return true
    }

    nonisolated private static func selectQueryTerms(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for r in raw {
            let t = r.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 4, t.count <= 30 else { continue }
            guard !stopTerms.contains(t) else { continue }
            // Strip non-letters (Wikipedia titles are alphabetic).
            let cleaned = t.filter { $0.isLetter || $0 == "-" }
            guard cleaned.count >= 4 else { continue }
            if seen.insert(cleaned).inserted {
                result.append(cleaned)
                if result.count >= maxTermsPerCall { break }
            }
        }
        return result
    }

    nonisolated private static func fetchWikipediaSummary(term: String) async -> WebContextEntry? {
        // Wikipedia REST API: open, no key, public-info only.
        let safe = term.replacingOccurrences(of: " ", with: "_")
        guard let encoded = safe.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        request.setValue("Contextual/1.0 (ambient_assistant)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            struct WikiSummary: Decodable {
                let title: String
                let extract: String
                let content_urls: WikiURLs?
                struct WikiURLs: Decodable {
                    let desktop: WikiURL?
                    struct WikiURL: Decodable {
                        let page: String
                    }
                }
            }
            guard let decoded = try? JSONDecoder().decode(WikiSummary.self, from: data),
                  !decoded.extract.isEmpty,
                  !decoded.title.isEmpty else { return nil }
            return WebContextEntry(
                term: term,
                title: decoded.title,
                extract: String(decoded.extract.prefix(220)),
                source: "wikipedia",
                url: decoded.content_urls?.desktop?.page ?? "https://en.wikipedia.org/wiki/\(safe)"
            )
        } catch {
            return nil
        }
    }
}

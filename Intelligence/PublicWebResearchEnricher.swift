import Foundation

/// Bounded, non-agentic public web research enrichment layer.
/// No API keys, no browser automation, no agentic loops.
public actor PublicWebResearchEnricher {
    static let shared = PublicWebResearchEnricher()

    public struct PublicGroundedFact: Sendable, Equatable, Codable {
        public let label: String
        public let value: String
        public let sourceURL: String
        public let sourceTitle: String
        public let method: String
        public let confidence: Double
        
        public init(label: String, value: String, sourceURL: String, sourceTitle: String, method: String, confidence: Double) {
            self.label = label
            self.value = value
            self.sourceURL = sourceURL
            self.sourceTitle = sourceTitle
            self.method = method
            self.confidence = confidence
        }
    }

    struct ResearchResult: Sendable {
        let query: String
        let facts: [PublicGroundedFact]
        let genericSnippets: [String]
        let status: String
    }

    private struct CacheEntry {
        let result: ResearchResult
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 1800 // 30 minutes
    
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.0
        cfg.timeoutIntervalForResource = 5.0
        return URLSession(configuration: cfg)
    }()

    private static let allowedWorkflows: Set<AmbientWorkflowType> = [
        .shopping, .comparing, .researching, .reading
    ]

    func searchAndFetch(
        intent: String,
        intentGoal: String,
        workflow: AmbientWorkflowType,
        behavior: BehavioralState,
        titles: [String],
        terms: [String],
        activeCompartment: TaskCompartment? = nil,
        allCompartments: [TaskCompartment] = [],
        now: Date = Date()
    ) async -> ResearchResult {
        print("[PublicWebResearchEnricher] started intent=\(intent) workflow=\(workflow.rawValue)")

        let filteredTerms: [String] = {
            let base = activeCompartment?.dominantTerms.map { $0 } ?? terms
            let bg = Set(allCompartments.filter { $0.id != activeCompartment?.id }.flatMap { $0.dominantTerms }.map { $0.lowercased() })
            return base.filter { !bg.contains($0.lowercased()) }
        }()

        let query = Self.buildQuery(titles: titles, terms: filteredTerms)
        if query.isEmpty {
            print("[PublicWebResearchEnricher] skipped reason=not_public_web_context")
            return ResearchResult(query: "", facts: [], genericSnippets: [], status: "skipped_no_query")
        }

        if !Self.allowedWorkflows.contains(workflow) {
            print("[PublicWebResearchEnricher] skipped reason=sensitive_context")
            return ResearchResult(query: query, facts: [], genericSnippets: [], status: "skipped_sensitive")
        }

        if ProcessInfo.processInfo.environment["CONTEXTUAL_AMBIENT_WEB_ENRICH"] == "0" {
            print("[PublicWebResearchEnricher] skipped reason=env_disabled")
            return ResearchResult(query: query, facts: [], genericSnippets: [], status: "skipped_env")
        }

        if let hit = cache[query], now.timeIntervalSince(hit.storedAt) < cacheTTL {
            print("[PublicWebResearchEnricher] cache_hit query=\"\(query)\"")
            return hit.result
        }

        print("[PublicWebResearchEnricher] query=\"\(query)\"")

        // Search DuckDuckGo HTML
        let searchURLs = await performSearch(query: query)
        print("[PublicWebResearchEnricher] search_results=count=\(searchURLs.count)")

        if searchURLs.isEmpty {
            let res = ResearchResult(query: query, facts: [], genericSnippets: [], status: "search_failed")
            cache[query] = CacheEntry(result: res, storedAt: now)
            return res
        }

        var allFacts: [PublicGroundedFact] = []
        var genericSnippets: [String] = []

        // Fetch top URLs (max 3)
        for url in searchURLs.prefix(3) {
            print("[PublicWebResearchEnricher] fetching url=\(url.absoluteString)")
            let (facts, snippet) = await fetchAndExtract(url: url)
            if facts.isEmpty && snippet.isEmpty {
                print("[PublicWebResearchEnricher] fetched url=\(url.absoluteString) status=failed_or_empty")
            } else {
                print("[PublicWebResearchEnricher] fetched url=\(url.absoluteString) status=success")
            }
            allFacts.append(contentsOf: facts)
            if !snippet.isEmpty {
                genericSnippets.append(snippet)
            }
        }

        print("[PublicWebResearchEnricher] extracted facts=\(allFacts.count) sources=\(Set(allFacts.map { $0.sourceURL }).count)")
        print("[PublicWebResearchEnricher] completed quality=public_web_research")

        let res = ResearchResult(query: query, facts: allFacts, genericSnippets: genericSnippets, status: "success")
        cache[query] = CacheEntry(result: res, storedAt: now)
        return res
    }

    private static func buildQuery(titles: [String], terms: [String]) -> String {
        let validTitles = titles.filter { !$0.isEmpty }
        if let bestTitle = validTitles.first {
            let parts = bestTitle.components(separatedBy: " - ")
                .flatMap { $0.components(separatedBy: " | ") }
                .flatMap { $0.components(separatedBy: " — ") }
            if let first = parts.first, first.count > 5 {
                return first.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        let validTerms = terms.filter { !$0.isEmpty }
        if validTerms.count >= 2 {
            return validTerms.prefix(4).joined(separator: " ")
        }
        return ""
    }

    private func performSearch(query: String) async -> [URL] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return []
        }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 2.0

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                print("[PublicWebSearch] failed reason=http_error_or_decode_failed")
                return []
            }
            
            print("[PublicWebSearch] provider=duckduckgo_html")
            return parseDuckDuckGoURLs(html: html)
        } catch {
            print("[PublicWebSearch] failed reason=\(error.localizedDescription)")
            return []
        }
    }

    private func parseDuckDuckGoURLs(html: String) -> [URL] {
        var results: [URL] = []
        let pattern = "class=\"result__url\" href=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        for match in matches {
            if let r = Range(match.range(at: 1), in: html) {
                var urlStr = String(html[r])
                if urlStr.hasPrefix("//") { urlStr = "https:" + urlStr }
                if let url = URL(string: urlStr) {
                    // Extract actual URL from DuckDuckGo redirect if present
                    if url.host == "duckduckgo.com", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
                       let realURL = URL(string: uddg) {
                        results.append(realURL)
                    } else {
                        results.append(url)
                    }
                }
            }
        }
        return results
    }

    private func fetchAndExtract(url: URL) async -> ([PublicGroundedFact], String) {
        var req = URLRequest(url: url)
        req.setValue("Contextual/1.0 (public_page_metadata)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 2.0

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return ([], "")
            }

            let ctx = PublicPageContextExtractor.extractForTests(url: url, html: html)
            var facts: [PublicGroundedFact] = []
            
            let sourceTitle = ctx.pageTitle ?? ctx.ogTitle ?? url.host ?? "Unknown Page"

            func addFact(_ label: String, _ value: String?) {
                guard let v = value, !v.isEmpty else { return }
                facts.append(PublicGroundedFact(
                    label: label,
                    value: v,
                    sourceURL: url.absoluteString,
                    sourceTitle: sourceTitle,
                    method: "html_meta",
                    confidence: 0.9
                ))
            }
            
            addFact("title", ctx.pageTitle)
            addFact("og:title", ctx.ogTitle)
            addFact("og:description", ctx.ogDescription)

            for (k, v) in ctx.productFacts {
                facts.append(PublicGroundedFact(
                    label: k,
                    value: v,
                    sourceURL: url.absoluteString,
                    sourceTitle: sourceTitle,
                    method: "json_ld",
                    confidence: 0.9
                ))
            }
            
            var snippet = ""
            if let desc = ctx.ogDescription {
                snippet = desc
            } else if let title = ctx.ogTitle {
                snippet = title
            }
            
            return (facts, snippet)
        } catch {
            return ([], "")
        }
    }
}

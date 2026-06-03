import Foundation

/// Phase 22.2 — Bounded public entity lookup via URL Open Graph metadata (Task A).
///
/// Fetches the Open Graph tags from the entity's own page URL to produce a
/// richer, authoritative classification than vocabulary-only URL matching.
///
/// Strategy:
///   1. Check cache — return cached result synchronously if valid (30-min TTL).
///   2. If not cached and URL is safe to fetch → fire background Task (non-blocking).
///   3. Next tick, cache is populated and grounding uses enriched result.
///
/// Safety constraints:
///   - HTTPS only (no HTTP, no private IPs, no localhost).
///   - 3-second URLSession timeout.
///   - Only reads the URL the user is already viewing.
///   - Never stores page body — only OG tag values (public metadata).
///   - No API keys required.
///
/// Required logs: [EntityLookup]
enum EntityLookupLayer {

    // MARK: - Result type

    struct Result {
        let entityType: EntityGrounding.EntityType
        let confidence: Double
        let summary: String
        let source: Source
        let ogType: String       // raw og:type value for debugging
        let ogSiteName: String   // raw og:site_name for debugging

        enum Source: String {
            case urlMetadata = "url_metadata"
            case cache       = "cache"
            case titleOnly   = "title_only"
        }
    }

    // MARK: - Cache (thread-safe, synchronous access)

    private final class CacheStore {
        static let shared = CacheStore()
        private let queue = DispatchQueue(label: "EntityLookupCache", qos: .utility)
        private var cache: [String: (result: Result, expiry: Date)] = [:]
        private var pending: Set<String> = []
        private let ttl: TimeInterval = 1800  // 30 min

        func get(url: URL) -> Result? {
            queue.sync {
                guard let entry = cache[url.absoluteString] else { return nil }
                return Date() < entry.expiry ? entry.result : nil
            }
        }

        func set(url: URL, result: Result) {
            queue.async { [self] in
                cache[url.absoluteString] = (result, Date().addingTimeInterval(ttl))
            }
        }

        func isExpired(url: URL) -> Bool {
            queue.sync {
                guard let entry = cache[url.absoluteString] else { return true }
                return Date() >= entry.expiry
            }
        }

        func markPending(_ url: URL) { queue.async { self.pending.insert(url.absoluteString) } }
        func clearPending(_ url: URL) { queue.async { self.pending.remove(url.absoluteString) } }
        func isPending(_ url: URL) -> Bool { queue.sync { pending.contains(url.absoluteString) } }

        func resetForTests() { queue.sync { cache = [:]; pending = [] } }
    }

    // MARK: - Public API

    /// Returns the cached lookup result for the URL if valid, otherwise nil.
    /// Callers can use this synchronously inside EntityGroundingLayer.ground().
    static func cachedResult(for url: URL) -> Result? {
        CacheStore.shared.get(url: url)
    }

    /// Fire-and-forget background fetch.
    /// Populates the cache; the result is available on the NEXT tick.
    /// Safe to call multiple times — duplicate in-flight fetches are deduplicated.
    static func prefetchIfNeeded(url: URL, entityName: String) {
        guard isSafeToFetch(url) else {
            print("[EntityLookup] skipped reason=unsafe_url entity=\"\(entityName.prefix(40))\"")
            return
        }
        guard CacheStore.shared.isExpired(url: url) else {
            // Already cached and fresh — will be picked up by cachedResult() this tick
            print("[EntityLookup] skipped reason=cached url=\(url.host ?? "") entity=\"\(entityName.prefix(40))\"")
            return
        }
        guard !CacheStore.shared.isPending(url) else {
            // Fetch already in-flight from a prior tick — result will land in cache soon
            print("[EntityLookup] skipped reason=in_flight url=\(url.host ?? "")")
            return
        }
        CacheStore.shared.markPending(url)
        print("[EntityLookup] started entity=\"\(entityName.prefix(40))\" url=\(url.host ?? "")")
        Task.detached(priority: .utility) {
            let result = await fetch(url: url, entityName: entityName)
            CacheStore.shared.clearPending(url)
            CacheStore.shared.set(url: url, result: result)
        }
    }

    /// Synchronously parse OG metadata from a raw HTML string (exposed for tests).
    static func parseOGTags(from html: String) -> OGData {
        var data = OGData()
        let lower = html
        // Two patterns handle both attribute orderings in <meta> tags:
        //   pattern  — property="og:key" ... content="value"   → group1=key, group2=value
        //   pattern2 — content="value" ... property="og:key"   → group1=value, group2=key (swapped)
        let pattern  = #"<meta[^>]+(?:property|name)=['\"]og:(\w+)['\"][^>]+content=['\"]([^'"]*)['\"]"#
        let pattern2 = #"<meta[^>]+content=['\"]([^'"]*)['\"][^>]+(?:property|name)=['\"]og:(\w+)['\"]"#

        func applyTag(key rawKey: String, value: String) {
            let key = rawKey.lowercased()
            switch key {
            case "type":        if data.ogType.isEmpty    { data.ogType        = value.lowercased() }
            case "title":       if data.ogTitle.isEmpty   { data.ogTitle       = value }
            case "description": if data.ogDescription.isEmpty { data.ogDescription = String(value.prefix(200)) }
            case "site_name":   if data.ogSiteName.isEmpty { data.ogSiteName   = value }
            default: break
            }
        }

        func extract(from input: String, pat: String, keyGroup: Int, valueGroup: Int) {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return }
            let range = NSRange(input.startIndex..., in: input)
            re.enumerateMatches(in: input, range: range) { match, _, _ in
                guard let m = match, m.numberOfRanges == 3 else { return }
                guard let kr = Range(m.range(at: keyGroup),   in: input),
                      let vr = Range(m.range(at: valueGroup), in: input) else { return }
                applyTag(key: String(input[kr]), value: String(input[vr]))
            }
        }

        // pattern:  group1=key, group2=value
        extract(from: lower, pat: pattern,  keyGroup: 1, valueGroup: 2)
        // pattern2: group1=value, group2=key  → swap
        extract(from: lower, pat: pattern2, keyGroup: 2, valueGroup: 1)
        return data
    }

    // MARK: - Fetch implementation (background)

    private static func fetch(url: URL, entityName: String) async -> Result {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 3.0)
        request.setValue("Mozilla/5.0 (compatible; Contextual/1.0)", forHTTPHeaderField: "User-Agent")
        // Only request headers + enough body for OG tags (avoid downloading large pages)
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return fallbackResult(entityName: entityName, url: url)
            }
            // Only parse the first 8 KB — OG tags are in <head>, no need for full body
            let html = String(data: data.prefix(8192), encoding: .utf8)
                    ?? String(data: data.prefix(8192), encoding: .isoLatin1)
                    ?? ""
            let og = parseOGTags(from: html)
            let result = mapOGToResult(og: og, url: url, entityName: entityName)

            print("[EntityLookup] source=url_metadata"
                + " type=\(result.entityType.rawValue)"
                + " confidence=\(String(format: "%.2f", result.confidence))"
                + " og_type=\"\(og.ogType)\""
                + " site=\"\(og.ogSiteName)\"")
            print("[EntityLookup] result type=\(result.entityType.rawValue)")
            print("[EntityLookup] summary=\"\(result.summary.prefix(80))\"")
            print("[EntityLookup] confidence=\(String(format: "%.2f", result.confidence))")
            return result
        } catch {
            print("[EntityLookup] skipped reason=fetch_error entity=\"\(entityName.prefix(40))\" error=\(error.localizedDescription.prefix(60))")
            return fallbackResult(entityName: entityName, url: url)
        }
    }

    // MARK: - OG → EntityType mapping

    struct OGData {
        var ogType: String        = ""
        var ogTitle: String       = ""
        var ogDescription: String = ""
        var ogSiteName: String    = ""
    }

    private static func mapOGToResult(og: OGData, url: URL, entityName: String) -> Result {
        let host = url.host?.lowercased() ?? ""
        let siteLower = og.ogSiteName.lowercased()

        // ── Video episode / TV show ──────────────────────────────────────────
        if og.ogType == "video.episode" || og.ogType == "video.tv_show" {
            return Result(entityType: .tv_show, confidence: 0.95,
                         summary: "OG type: \(og.ogType)",
                         source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
        }
        if og.ogType == "video.movie" {
            return Result(entityType: .tv_show, confidence: 0.88,
                         summary: "OG type: video.movie",
                         source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
        }

        // ── Video other — check site context ──────────────────────────────────
        if og.ogType.hasPrefix("video") {
            // YouTube-origin → youtube_video
            if host.contains("youtube") || host.contains("youtu") || siteLower.contains("youtube") {
                return Result(entityType: .youtube_video, confidence: 0.92,
                             summary: "Video on YouTube platform",
                             source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
            }
            // Streaming service → tv_show
            let streamingNames = ["netflix", "hulu", "hbo", "disney", "peacock",
                                   "prime", "apple tv", "paramount", "crunchyroll"]
            if streamingNames.contains(where: { host.contains($0) || siteLower.contains($0) }) {
                return Result(entityType: .tv_show, confidence: 0.90,
                             summary: "Video on streaming platform",
                             source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
            }
            return Result(entityType: .youtube_video, confidence: 0.65,
                         summary: "Video content (platform unrecognised)",
                         source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
        }

        // ── Game ──────────────────────────────────────────────────────────────
        if og.ogType == "game" {
            return Result(entityType: .game, confidence: 0.90,
                         summary: "OG type: game",
                         source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
        }

        // ── Music ─────────────────────────────────────────────────────────────
        if og.ogType.hasPrefix("music") {
            return Result(entityType: .unknown, confidence: 0.55,
                         summary: "Music content — no relevant proposal",
                         source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
        }

        // ── Article / Book / Profile — use description for additional context ─
        if og.ogType == "article" || og.ogType == "book" {
            let desc = og.ogDescription.lowercased()
            let titleLower = og.ogTitle.lowercased()
            // Academic / course signal in description
            if desc.contains("course") || desc.contains("lecture") || desc.contains("syllabus")
               || titleLower.contains("lecture") || titleLower.contains("syllabus") {
                return Result(entityType: .course_material, confidence: 0.72,
                             summary: "Article with academic signals",
                             source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
            }
            return Result(entityType: .document, confidence: 0.65,
                         summary: "Article or book content",
                         source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
        }

        // ── Website (og:type == "website" or missing) ─────────────────────────
        // Fall through to weak classification
        return Result(entityType: .website, confidence: 0.30,
                     summary: "Generic website — og:type=\(og.ogType.isEmpty ? "none" : og.ogType)",
                     source: .urlMetadata, ogType: og.ogType, ogSiteName: og.ogSiteName)
    }

    private static func fallbackResult(entityName: String, url: URL) -> Result {
        Result(entityType: .unknown, confidence: 0.10,
               summary: "Fetch failed — no metadata",
               source: .titleOnly, ogType: "", ogSiteName: "")
    }

    // MARK: - Safety guard

    /// Returns false for URLs that should never be fetched:
    /// - Non-HTTPS (plain HTTP, file:, custom schemes)
    /// - Private/loopback IP ranges (10.x, 192.168.x, 172.16–31.x, 127.x, ::1)
    /// - Localhost variants
    static func isSafeToFetch(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        let host = url.host?.lowercased() ?? ""
        if host.isEmpty { return false }
        if host == "localhost" || host == "::1" { return false }
        // Block private IPv4 ranges
        let privatePatterns = [
            "^127\\.", "^10\\.", "^192\\.168\\.",
            "^172\\.(1[6-9]|2[0-9]|3[01])\\.",
            "^169\\.254\\.", "^0\\."
        ]
        for pattern in privatePatterns {
            if (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: host, range: NSRange(host.startIndex..., in: host)) != nil {
                return false
            }
        }
        return true
    }
}

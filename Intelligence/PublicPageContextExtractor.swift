import Foundation

/// Read-only public page metadata extractor (Phase 18C evidence upgrade).
///
/// Constraints:
/// - No browser automation, no clicking, no private pages.
/// - URL is discovered only from existing local context (AX fragments, snapshot clipboard text).
/// - If a public URL is available, fetch HTML directly (timeout <= 2s) and extract:
///   title / og:title / og:description / JSON-LD Product fields (when present).
public actor PublicPageContextExtractor {
	static let shared = PublicPageContextExtractor()

	public struct PublicPageContext: Sendable, Equatable, Codable {
		public let url: URL?
		public let pageTitle: String?
		public let ogTitle: String?
		public let ogDescription: String?
		public let productFacts: [String: String]
		public let extractedAt: Date
		public let source: String // "none" | "url_html"
        
        public init(url: URL?, pageTitle: String?, ogTitle: String?, ogDescription: String?, productFacts: [String : String], extractedAt: Date, source: String) {
            self.url = url
            self.pageTitle = pageTitle
            self.ogTitle = ogTitle
            self.ogDescription = ogDescription
            self.productFacts = productFacts
            self.extractedAt = extractedAt
            self.source = source
        }
	}

	private struct CacheEntry {
		let ctx: PublicPageContext
		let storedAt: Date
	}

	private var cache: [String: CacheEntry] = [:]
	private let cacheTTL: TimeInterval = 600 // 10 minutes

	private let session: URLSession = {
		let cfg = URLSessionConfiguration.ephemeral
		cfg.urlCache = nil
		cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		cfg.waitsForConnectivity = false
		return URLSession(configuration: cfg)
	}()

	func extract(
		windowTitle: String,
		axTextFragments: [String],
		clipboardText: String?,
		now: Date = Date()
	) async -> PublicPageContext {
		let url = Self.bestPublicURL(windowTitle: windowTitle, axTextFragments: axTextFragments, clipboardText: clipboardText)
		guard let url else {
			print("[PublicPageContextExtractor] skipped reason=no_public_url_available")
			return PublicPageContext(url: nil, pageTitle: nil, ogTitle: nil, ogDescription: nil, productFacts: [:], extractedAt: now, source: "none")
		}

		let cacheKey = url.absoluteString
		if let hit = cache[cacheKey], now.timeIntervalSince(hit.storedAt) < cacheTTL {
			return hit.ctx
		}

		print("[PublicPageContextExtractor] started url_source=\(url.host ?? "unknown")")
		let ctx = await fetchAndExtract(url: url, now: now)
		cache[cacheKey] = CacheEntry(ctx: ctx, storedAt: now)
		return ctx
	}

	// MARK: - URL discovery

	nonisolated private static func bestPublicURL(windowTitle: String, axTextFragments: [String], clipboardText: String?) -> URL? {
		// 1) AX fragments (often include address bar value).
		for frag in axTextFragments {
			if let url = parseFirstPublicURL(frag) { return url }
		}
		// 2) Clipboard URL only if clipboard is a public URL.
		if let clip = clipboardText, let url = parseFirstPublicURL(clip) { return url }
		// 3) Title rarely contains full URL; ignore by default.
		_ = windowTitle
		return nil
	}

	nonisolated private static func parseFirstPublicURL(_ s: String) -> URL? {
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count >= 10 else { return nil }
		
		// Quick block for sensitive or non-http strings before heavy parsing
		if trimmed.lowercased().contains("password") || trimmed.lowercased().contains("token=") {
			print("[PublicPageContextExtractor] skipped reason=sensitive_or_private_url")
			return nil
		}

		// Quick scan: split and try URL init.
		let parts = trimmed
			.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
			.filter { !$0.isEmpty }
		for p in parts {
			if p.hasPrefix("http://") || p.hasPrefix("https://") {
				if let url = URL(string: p), isPublicHTTPURL(url) { return url }
			}
		}
		return nil
	}

	nonisolated private static func isPublicHTTPURL(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
		guard let host = url.host, !host.isEmpty else { return false }
		// Block obvious local/private targets.
		let h = host.lowercased()
		if h == "localhost" || h.hasSuffix(".local") { return false }
		if h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") { return false }
		if h.contains(":") { return false } // conservative: block raw IPv6 literals for now
		return true
	}

	// MARK: - HTML fetch + extraction

	private func fetchAndExtract(url: URL, now: Date) async -> PublicPageContext {
		var req = URLRequest(url: url)
		req.httpMethod = "GET"
		req.timeoutInterval = 2.0
		req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
		req.setValue("Contextual/1.0 (public_page_metadata)", forHTTPHeaderField: "User-Agent")

		do {
			let (data, resp) = try await session.data(for: req)
			guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
				return PublicPageContext(url: url, pageTitle: nil, ogTitle: nil, ogDescription: nil, productFacts: [:], extractedAt: now, source: "url_html")
			}
			guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
				return PublicPageContext(url: url, pageTitle: nil, ogTitle: nil, ogDescription: nil, productFacts: [:], extractedAt: now, source: "url_html")
			}

			let title = Self.extractTagContent(html: html, tag: "title")
			let ogTitle = Self.extractMetaContent(html: html, key: "property", value: "og:title")
			let ogDesc = Self.extractMetaContent(html: html, key: "property", value: "og:description")

			let product = Self.extractProductFactsFromJSONLD(html: html)
			print("[PublicPageContextExtractor] extracted product_facts=\(product.count) metadata_fields=\((title != nil ? 1 : 0) + (ogTitle != nil ? 1 : 0) + (ogDesc != nil ? 1 : 0)) url_source=\(url.host ?? "unknown")")
			return PublicPageContext(url: url, pageTitle: title, ogTitle: ogTitle, ogDescription: ogDesc, productFacts: product, extractedAt: now, source: "url_html")
		} catch {
			return PublicPageContext(url: url, pageTitle: nil, ogTitle: nil, ogDescription: nil, productFacts: [:], extractedAt: now, source: "url_html")
		}
	}

	// MARK: - Test hooks

	nonisolated static func extractForTests(url: URL, html: String, now: Date = Date()) -> PublicPageContext {
		let title = Self.extractTagContent(html: html, tag: "title")
		let ogTitle = Self.extractMetaContent(html: html, key: "property", value: "og:title")
		let ogDesc = Self.extractMetaContent(html: html, key: "property", value: "og:description")
		let product = Self.extractProductFactsFromJSONLD(html: html)
		return PublicPageContext(url: url, pageTitle: title, ogTitle: ogTitle, ogDescription: ogDesc, productFacts: product, extractedAt: now, source: "url_html")
	}

	nonisolated private static func extractTagContent(html: String, tag: String) -> String? {
		// Very small, conservative extraction: <title>...</title>
		let lower = html.lowercased()
		guard let startRange = lower.range(of: "<\(tag)") else { return nil }
		guard let closeStart = lower.range(of: ">", range: startRange.upperBound..<lower.endIndex) else { return nil }
		guard let endRange = lower.range(of: "</\(tag)>", range: closeStart.upperBound..<lower.endIndex) else { return nil }
		let raw = html[closeStart.upperBound..<endRange.lowerBound]
		return decodeHTML(raw.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	nonisolated private static func extractMetaContent(html: String, key: String, value: String) -> String? {
		// Regex-free best-effort: scan for meta tags containing key="value" and content="...".
		let lower = html.lowercased()
		let needle = "\(key)=\"\(value)\""
		guard let r = lower.range(of: needle) else { return nil }
		let windowStart = lower.index(r.lowerBound, offsetBy: -400, limitedBy: lower.startIndex) ?? lower.startIndex
		let windowEnd = lower.index(r.upperBound, offsetBy: 400, limitedBy: lower.endIndex) ?? lower.endIndex
		let chunk = html[windowStart..<windowEnd]
		return extractAttribute(String(chunk), attr: "content")
	}

	nonisolated private static func extractAttribute(_ tagChunk: String, attr: String) -> String? {
		let lower = tagChunk.lowercased()
		guard let a = lower.range(of: "\(attr)=\"") else { return nil }
		let start = a.upperBound
		guard let end = lower[start...].firstIndex(of: "\"") else { return nil }
		let raw = tagChunk[start..<end]
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : decodeHTML(trimmed)
	}

	nonisolated private static func extractProductFactsFromJSONLD(html: String) -> [String: String] {
		let scripts = extractJSONLDScripts(html: html)
		for script in scripts {
			if let facts = parseProductFacts(jsonText: script), !facts.isEmpty {
				return facts
			}
		}
		return [:]
	}

	nonisolated private static func extractJSONLDScripts(html: String) -> [String] {
		let lower = html.lowercased()
		var results: [String] = []
		var searchRange = lower.startIndex..<lower.endIndex
		while let start = lower.range(of: "type=\"application/ld+json\"", range: searchRange) {
			guard let bodyStart = lower.range(of: ">", range: start.upperBound..<lower.endIndex)?.upperBound else { break }
			guard let end = lower.range(of: "</script>", range: bodyStart..<lower.endIndex)?.lowerBound else { break }
			let raw = html[bodyStart..<end]
			let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty { results.append(text) }
			searchRange = end..<lower.endIndex
		}
		return Array(results.prefix(6))
	}

	nonisolated private static func parseProductFacts(jsonText: String) -> [String: String]? {
		guard let data = jsonText.data(using: .utf8) else { return nil }
		let obj = try? JSONSerialization.jsonObject(with: data)

		func productDict(from any: Any) -> [String: Any]? {
			if let d = any as? [String: Any] {
				if let t = d["@type"] as? String, t.lowercased().contains("product") { return d }
				if let g = d["@graph"] as? [Any] {
					for item in g {
						if let found = productDict(from: item) { return found }
					}
				}
				return nil
			}
			if let arr = any as? [Any] {
				for item in arr {
					if let found = productDict(from: item) { return found }
				}
			}
			return nil
		}

		guard let product = obj.flatMap(productDict(from:)) else { return nil }

		var facts: [String: String] = [:]
		func set(_ key: String, _ value: String?) {
			guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
			facts[key] = v
		}

		set("title", product["name"] as? String)
		set("description", product["description"] as? String)

		if let brand = product["brand"] as? [String: Any] {
			set("brand", brand["name"] as? String)
		} else if let brandStr = product["brand"] as? String {
			set("brand", brandStr)
		}

		if let offers = product["offers"] as? [String: Any] {
			set("price", offers["price"] as? String)
			set("priceCurrency", offers["priceCurrency"] as? String)
		}

		if let rating = product["aggregateRating"] as? [String: Any] {
			set("ratingValue", rating["ratingValue"] as? String)
			set("ratingCount", rating["ratingCount"] as? String)
		}

		// Phase 18C: Extra extraction for power/tech specs from text if present.
		let text = ((product["name"] as? String) ?? "") + " " + ((product["description"] as? String) ?? "")
		if let capacity = extractRegex(text, pattern: "\\b\\d+[,.]?\\d*\\s*mah\\b") {
			set("capacity", capacity)
		}
		if let wattage = extractRegex(text, pattern: "\\b\\d+\\s*w\\b") {
			set("wattage", wattage)
		}
		if text.lowercased().contains("ports") {
			if let ports = extractRegex(text, pattern: "\\d+\\s*ports?\\b") {
				set("ports", ports)
			}
		}

		return facts
	}

	nonisolated private static func extractRegex(_ text: String, pattern: String) -> String? {
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		if let match = regex.firstMatch(in: text, options: [], range: range) {
			if let r = Range(match.range, in: text) {
				return String(text[r])
			}
		}
		return nil
	}

	nonisolated private static func decodeHTML(_ s: String) -> String {
		// Minimal decoding (avoid pulling in heavy HTML libs).
		return s
			.replacingOccurrences(of: "&amp;", with: "&")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
	}
}

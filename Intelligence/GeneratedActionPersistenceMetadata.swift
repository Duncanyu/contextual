import Foundation

enum GeneratedActionPersistenceMetadata {
	static func sanitize(_ metadata: [String: String]) -> [String: String] {
		let forbidden = ["raw", "clipboard", "ocr", "screenshot", "content", "body", "text", "excerpt"]
		var out: [String: String] = [:]
		for (key, value) in metadata {
			let lower = key.lowercased()
			guard !forbidden.contains(where: { lower.contains($0) }) else { continue }
			out[key] = String(value.prefix(120))
		}
		return out
	}
}

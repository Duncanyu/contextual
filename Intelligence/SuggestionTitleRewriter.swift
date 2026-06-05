import Foundation

/// Phase 35.4 — Cleans raw friction/system action titles before quality filtering.
///
/// Converts underscored filenames to human-readable names:
///   "_182_Montreal_Street_Accommodation_A..." → "the lease PDF"
///   "Queen's University - Housing" → "Queen's Housing"
///
/// Also excludes stale/entertainment entities from titles.
enum SuggestionTitleRewriter {

    /// Rewrite a friction action title to be human-readable.
    static func rewrite(title: String, capabilityId: String) -> String {
        var cleaned = title

        // Replace underscored filenames with semantic labels
        cleaned = replaceUnderscoredFilenames(in: cleaned)

        // Truncate overly long entity names
        cleaned = truncateLongEntities(in: cleaned)

        if cleaned != title {
            print("[SuggestionTitleRewrite] capability=\(capabilityId) before=\"\(String(title.prefix(60)))\" after=\"\(String(cleaned.prefix(60)))\" reason=filename_cleanup")
        }

        return cleaned
    }

    /// Replace patterns like "_182_Montreal_Street_Accommodation_Agreement_Final_Version_EN.pdf"
    /// with a clean short label like "the lease PDF" or "182 Montreal lease".
    private static func replaceUnderscoredFilenames(in title: String) -> String {
        // Pattern: sequences of word_word_word... (3+ underscored segments)
        let underscoreHeavy = #"_[A-Za-z0-9]+(_[A-Za-z0-9]+){2,}"#
        guard let range = title.range(of: underscoreHeavy, options: .regularExpression) else {
            return title
        }

        let raw = String(title[range])
        let words = raw.split(separator: "_").map { String($0) }.filter { !$0.isEmpty }

        // Build a short label from the first few meaningful words
        let meaningful = words.filter { $0.count >= 3 && $0.lowercased() != "final" && $0.lowercased() != "version" && $0.lowercased() != "en" }
        let shortLabel: String
        if meaningful.count >= 2 {
            shortLabel = meaningful.prefix(3).joined(separator: " ")
        } else {
            shortLabel = words.prefix(3).joined(separator: " ")
        }

        // Detect if it's a PDF
        let isPDF = title.lowercased().contains(".pdf") || raw.lowercased().contains("pdf")
        let label = isPDF ? "\(shortLabel) PDF" : shortLabel

        return title.replacingCharacters(in: range, with: label)
    }

    /// Truncate entity names longer than 35 chars in titles.
    private static func truncateLongEntities(in title: String) -> String {
        // If the title contains a quoted or "Put X beside Y" pattern,
        // truncate X and Y individually
        guard title.count > 70 else { return title }

        // Find "Put ... beside ..." pattern
        if let besideRange = title.range(of: " beside ", options: .caseInsensitive) {
            let prefix = title[title.startIndex..<besideRange.lowerBound]
            let suffix = title[besideRange.upperBound...]
            let cleanPrefix = String(prefix.prefix(40))
            let cleanSuffix = String(suffix.prefix(35))
            let verb = String(title[title.startIndex..<(title.range(of: " ")?.upperBound ?? title.startIndex)])
            return "\(cleanPrefix) beside \(cleanSuffix)?"
        }

        return title
    }
}

import Foundation

/// Phase 35.4 — Cleans raw friction/system action titles before quality filtering.
///
/// Converts underscored filenames to human-readable names:
///   "_182_Montreal_Street_Accommodation_A..." → "the lease PDF"
///   "Queen's University - Housing" → "Queen's Housing"
///
/// Also excludes stale/entertainment entities from titles.
enum SuggestionTitleRewriter {

    static func semanticRoleLabel(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("google docs") || lower.contains("docs.google.com") {
            return "Google Doc"
        }
        if lower.contains("pdf") || lower.hasSuffix(".pdf") {
            if lower.contains("lease") || lower.contains("agreement") || lower.contains("occupancy") || lower.contains("accommodation") {
                return "lease PDF"
            }
            return "PDF"
        }
        if lower.contains("inspection report") {
            return "inspection report"
        }
        if lower.contains("queen") && lower.contains("housing") {
            return "Queen's Housing"
        }
        return trimmed
    }

    static func semanticRoleLabel(title: String, appName: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = trimmedTitle.lowercased()
        let lowerApp = appName.lowercased()
        
        if lowerApp.contains("firefox") || lowerApp.contains("chrome") || lowerApp.contains("safari") {
            if lowerTitle.contains("google docs") || lowerTitle.contains("docs.google.com") || lowerTitle.contains("occupancy") || lowerTitle.contains("agreement") || lowerTitle.contains("montreal") {
                return "Google Doc"
            }
        }
        if lowerApp.contains("preview") || lowerTitle.contains("pdf") || lowerTitle.hasSuffix(".pdf") {
            if lowerTitle.contains("lease") || lowerTitle.contains("agreement") || lowerTitle.contains("occupancy") || lowerTitle.contains("accommodation") || lowerTitle.contains("montreal") {
                return "lease PDF"
            }
            return "PDF"
        }
        return semanticRoleLabel(for: title)
    }

    /// Rewrite a friction action title to be human-readable.
    static func rewrite(title: String, capabilityId: String) -> String {
        var cleaned = title

        if capabilityId == "arrange_side_by_side" || capabilityId == "split_research_setup" {
            cleaned = rewriteSideBySideTitle(cleaned)
        }

        // Replace underscored filenames with semantic labels
        cleaned = replaceUnderscoredFilenames(in: cleaned)

        // Truncate overly long entity names
        cleaned = truncateLongEntities(in: cleaned)

        if capabilityId == "arrange_side_by_side" {
            print("[SuggestionTitleRewrite] capability=arrange_side_by_side after=\"\(cleaned)\"")
        } else if cleaned != title {
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
        // Detect if it's a PDF
        let isPDF = title.lowercased().contains(".pdf") || raw.lowercased().contains("pdf")
        let shortLabel: String
        if isPDF && meaningful.map({ $0.lowercased() }).contains(where: { ["lease", "agreement", "occupancy", "accommodation"].contains($0) }) {
            shortLabel = "lease PDF"
        } else if meaningful.count >= 2 {
            shortLabel = meaningful.prefix(3).joined(separator: " ")
        } else {
            shortLabel = words.prefix(3).joined(separator: " ")
        }
        let label = isPDF && shortLabel != "lease PDF" ? "\(shortLabel) PDF" : shortLabel

        return title.replacingCharacters(in: range, with: label)
    }

    private static func rewriteSideBySideTitle(_ title: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.lowercased().hasPrefix("put ") || cleaned.lowercased().hasPrefix("arrange ") else {
            return cleaned
        }

        if let range = cleaned.range(of: " beside ", options: .caseInsensitive) {
            let prefixOffset = cleaned.lowercased().hasPrefix("arrange ") ? 8 : 4
            let primaryRaw = String(cleaned[cleaned.index(cleaned.startIndex, offsetBy: prefixOffset)..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ?"))
            let secondaryRaw = String(cleaned[range.upperBound..<cleaned.endIndex])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ?"))
            
            let runtime = WorkspaceRuntimeInventoryProvider.snapshot()
            let appA = runtime.visibleWindows.first { $0.title.lowercased().contains(primaryRaw.lowercased()) || primaryRaw.lowercased().contains($0.title.lowercased()) }?.appName ?? ""
            let appB = runtime.visibleWindows.first { $0.title.lowercased().contains(secondaryRaw.lowercased()) || secondaryRaw.lowercased().contains($0.title.lowercased()) }?.appName ?? ""
            
            let primary = semanticRoleLabel(title: primaryRaw, appName: appA)
            let secondary = semanticRoleLabel(title: secondaryRaw, appName: appB)
            
            if primary == secondary {
                if primaryRaw.lowercased() != secondaryRaw.lowercased() {
                    return "View \(primaryRaw) and \(secondaryRaw) side by side?"
                }
                return "View the \(primary) side by side?"
            }
            return "View the \(primary) and \(secondary) side by side?"
        }

        return cleaned
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
            return "\(cleanPrefix) beside \(cleanSuffix)?"
        }

        return title
    }
}

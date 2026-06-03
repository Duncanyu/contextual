import Foundation

public struct JarvisSuggestionValidator: Sendable {
    
    private static let rejectedPhrases = [
        "click", "open", "navigate", "search for", "find online",
        "buy", "add to cart", "install", "run", "execute",
        "create file", "modify file", "repository", "build plan", "commit"
    ]
    
    public static func validate(title: String, subtitle: String) -> Bool {
        if ProposalQualityFilter.hasPromptLeakOrCapabilityId(title) {
            print("[ProposalQualityFilter] rejected reason=raw_capability_or_prompt_leak")
            return false
        }
        let combined = "\(title) \(subtitle)".lowercased()
        
        for phrase in rejectedPhrases {
            if combined.contains(phrase) {
                print("[JarvisSuggestionValidation] rejected reason=control_language phrase=\"\(phrase)\"")
                return false
            }
        }
        
		// Phase 25.9 — Task 4: Strength Quality Filter
		let lowerTitle = title.lowercased()
		
		// 1. Reject duplicate entity titles: "Review dexter in Dexter"
		let parts = lowerTitle.components(separatedBy: " in ")
		if parts.count == 2 {
			let entity1 = parts[0].replacingOccurrences(of: "review ", with: "").trimmingCharacters(in: .whitespaces)
			let entity2 = parts[1].trimmingCharacters(in: .whitespaces)
			if entity1 == entity2 {
				print("[JarvisSuggestionValidation] rejected reason=duplicate_entity title=\"\(title)\"")
				return false
			}
		}

		// 2. Reject "Review [keyword list] before testing"
		if lowerTitle.hasPrefix("review ") && lowerTitle.contains(" before testing") {
			print("[JarvisSuggestionValidation] rejected reason=evidence_list_hallucination title=\"\(title)\"")
			return false
		}

		// 3. Reject titles starting with Review unless supported by specific evidence
		// (Simplified check: if it contains generic keywords like "dexter" or is too broad)
		if lowerTitle.hasPrefix("review ") && (lowerTitle.contains("dexter") || lowerTitle.contains("movie") || lowerTitle.contains("episode")) {
			print("[JarvisSuggestionValidation] rejected reason=entertainment_review_unsupported title=\"\(title)\"")
			return false
		}

        print("[JarvisSuggestionValidation] accepted=yes reason=context_only")
        return true
    }
}

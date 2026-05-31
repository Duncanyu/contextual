import Foundation

public struct JarvisSuggestionValidator: Sendable {
    
    private static let rejectedPhrases = [
        "click", "open", "navigate", "search for", "find online",
        "buy", "add to cart", "install", "run", "execute",
        "create file", "modify file", "repository", "build plan", "commit"
    ]
    
    public static func validate(title: String, subtitle: String) -> Bool {
        let combined = "\(title) \(subtitle)".lowercased()
        
        for phrase in rejectedPhrases {
            if combined.contains(phrase) {
                print("[JarvisSuggestionValidation] rejected reason=control_language phrase=\"\(phrase)\"")
                return false
            }
        }
        
        print("[JarvisSuggestionValidation] accepted=yes reason=context_only")
        return true
    }
}

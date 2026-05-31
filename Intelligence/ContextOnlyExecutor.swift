import Foundation

public struct ContextOnlyExecutor: Sendable {
    
    public static func execute(
        suggestion: AmbientJarvisSuggestion,
        recentTitles: [String],
        repeatedTerms: [String],
        ocrHints: [String],
        hasSelectedText: Bool
    ) async -> String {
        print("[ContextOnlyExecutor] started kind=\(suggestion.kind.rawValue)")
        
        let titlesList = recentTitles.filter { !$0.isEmpty }
        let termsList = repeatedTerms.filter { !$0.isEmpty }
        let ocrList = ocrHints.filter { !$0.isEmpty }
        
        // Formulate prompt
        let prompt = """
        Format your response strictly using these 5 numbered headings:
        1. What I noticed
        2. Possible pages/items/topics
        3. Differences inferable from context
        4. Missing information
        5. Suggested next question

        System Constraints:
        - Do NOT hallucinate any specs, attributes, or pricing.
        - Do NOT lookup the web or assume external knowledge.
        - If deep technical details are not visible in OCR, explicitly state that specs are missing under "Missing information".
        - If only titles are present in the list, explicitly state under "Differences inferable from context" that this comparison is title-based.

        Context Details:
        - Recent Titles: \(titlesList.joined(separator: " | "))
        - Repeated Terms: \(termsList.joined(separator: ", "))
        - OCR hints: \(ocrList.joined(separator: ", "))
        - Has Selected Text: \(hasSelectedText ? "Yes" : "No")
        """
        
        var output = ""
        let model = "qwen2.5:0.5b"
        
        if await ModelManager.shared.isGenerationAvailable() {
            do {
                let raw = try await LocalAIClient.shared.generate(
                    prompt: prompt,
                    model: model,
                    numPredict: 250,
                    temperature: 0.1,
                    purpose: "context_only_execution",
                    schema: nil
                )
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    output = cleaned
                }
            } catch {
                print("[ContextOnlyExecutor] generation failed, error=\(error)")
            }
        }
        
        // Structured Cautious Fallback
        if output.isEmpty {
            var sections = [String]()
            
            // 1. What I noticed
            let noticedTopic = termsList.isEmpty ? "recent items" : termsList.prefix(2).joined(separator: " and ")
            sections.append("""
            1. What I noticed
            I observed you actively researching \(noticedTopic) across multiple browser pages.
            """)
            
            // 2. Possible pages/items/topics
            let items = titlesList.isEmpty ? ["Unnamed page"] : titlesList.prefix(5)
            let itemsBulleted = items.map { "- \($0)" }.joined(separator: "\n")
            sections.append("""
            2. Possible pages/items/topics
            \(itemsBulleted)
            """)
            
            // 3. Differences inferable from context
            let onlyTitles = ocrList.isEmpty
            let diffDetails = onlyTitles 
                ? "This comparison is title-based. I noticed app transitions indicating you are switching between these different products."
                : "You are comparing items characterized by terms: \(termsList.prefix(3).joined(separator: ", "))."
            sections.append("""
            3. Differences inferable from context
            \(diffDetails)
            """)
            
            // 4. Missing information
            let missingDetails = "Specific pricing, tech specifications, and detailed attributes were not captured in the current metadata. Deep extraction would require full OCR visibility or browser control, which are currently disabled in this preview."
            sections.append("""
            4. Missing information
            \(missingDetails)
            """)
            
            // 5. Suggested next question
            sections.append("""
            5. Suggested next question
            Would you like to select and highlight text on one of these pages to supply more specific context for comparison?
            """)
            
            output = sections.joined(separator: "\n\n")
        }
        
        print("[ContextOnlyExecutor] completed output_chars=\(output.count)")
        return output
    }
}

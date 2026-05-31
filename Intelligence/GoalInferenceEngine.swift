import Foundation

public enum GoalInferenceEngine {
    
    static func inferGoal(
        workflow: WorkflowState,
        behavior: BehavioralStateRecord,
        packet: CompressedTemporalPacket,
        snapshot: CanonicalGeneratedExecutionContextSnapshot?
    ) async -> GoalInference {
        
        let prompt = """
        You are a goal inference engine for a context-aware assistant.
        Analyze the user's recent computer activity and infer their immediate cognitive goal.
        
        Rules:
        1. "goal" must be a concise string (e.g., choose_between_options, understand_topic, solve_problem, collect_information, evaluate_tradeoffs, make_decision, find_answer, organize_material).
        2. Do NOT use workflow names (shopping, coding, etc) as goals.
        3. Infer the goal dynamically from the titles, terms, and behavior.
        4. Output STRICT JSON: {"goal": "...", "confidence": 0.0, "reasoning": "..."}
        
        Context:
        - workflow: \(workflow.workflowType.rawValue)
        - behavior: \(behavior.state.rawValue)
        - app: \(packet.currentApp)
        - titles: \(packet.recentTitles.joined(separator: " | "))
        - terms: \(packet.topicTerms.joined(separator: ", "))
        - ocr: \(packet.ocrHints.joined(separator: ", "))
        """
        
        if await ModelManager.shared.isGenerationAvailable() {
            do {
                let raw = try await LocalAIClient.shared.generate(
                    prompt: prompt,
                    model: "qwen2.5:0.5b",
                    numPredict: 128,
                    temperature: 0.1,
                    purpose: "goal_inference"
                )
                if let parsed = parse(raw: raw) {
                    print("[GoalInferenceEngine] inferred goal=\(parsed.goal) confidence=\(parsed.confidence)")
                    return parsed
                }
            } catch {
                print("[GoalInferenceEngine] error: \(error)")
            }
        }
        
        return fallback(workflow: workflow, behavior: behavior, packet: packet)
    }
    
    private static func parse(raw: String) -> GoalInference? {
        guard let data = extractJSON(from: raw).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoalInference.self, from: data)
    }
    
    private static func extractJSON(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else { return raw }
        return String(trimmed[start...end])
    }
    
    private static func fallback(
        workflow: WorkflowState,
        behavior: BehavioralStateRecord,
        packet: CompressedTemporalPacket
    ) -> GoalInference {
        let goal: String
        if behavior.state == .comparing {
            goal = "choose_between_options"
        } else if workflow.workflowType == .reading || workflow.workflowType == .researching {
            goal = "understand_topic"
        } else {
            goal = "collect_information"
        }
        return GoalInference(
            goal: goal,
            confidence: 0.4,
            reasoning: "fallback based on behavior/workflow"
        )
    }
}

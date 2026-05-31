import Foundation

// MARK: - Backend Protocol

public protocol BehavioralInferenceBackend: Sendable {
    func infer(packet: BehavioralContextPacket) async -> BehavioralInference?
}

// MARK: - Ollama Backend

public struct OllamaBehavioralInferenceBackend: BehavioralInferenceBackend {
    public let modelName: String
    public let timeoutSeconds: Double
    public let endpoint: URL

    public init(
        modelName: String = "qwen2.5:0.5b",
        timeoutSeconds: Double = 4.0,
        endpoint: URL = URL(string: "http://127.0.0.1:11434/api/generate")!
    ) {
        self.modelName = modelName
        self.timeoutSeconds = timeoutSeconds
        self.endpoint = endpoint
    }

    public func infer(packet: BehavioralContextPacket) async -> BehavioralInference? {
        let prompt = BehavioralInferencePromptBuilder.build(packet: packet)

        struct Payload: Encodable {
            let model: String
            let prompt: String
            let stream: Bool
            let format: String
            let options: [String: Double]
            let keepAlive: String
            enum CodingKeys: String, CodingKey {
                case model, prompt, stream, format, options
                case keepAlive = "keep_alive"
            }
        }
        let payload = Payload(
            model: modelName,
            prompt: prompt,
            stream: false,
            format: "json",
            options: ["temperature": 0.2, "num_predict": 180],
            keepAlive: "10m"
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            struct OllamaResponse: Decodable { let response: String? }
            guard let decoded = try? JSONDecoder().decode(OllamaResponse.self, from: data),
                  let respText = decoded.response,
                  let jsonData = respText.data(using: .utf8) else {
                return nil
            }
            
            // Decodes the BehavioralInference JSON from the response text
            struct RawInference: Decodable {
                let state: String
                let confidence: Double
                let reasoning: String
            }
            
            guard let decodedInference = try? JSONDecoder().decode(RawInference.self, from: jsonData) else {
                return nil
            }
            
            let normalizedState = BehavioralState(rawValue: decodedInference.state.lowercased()) ?? .unknown
            return BehavioralInference(
                state: normalizedState,
                confidence: decodedInference.confidence,
                reasoning: decodedInference.reasoning
            )
        } catch {
            print("[BehavioralInference] failed reason=request_failed error=\(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Prompt Builder

public enum BehavioralInferencePromptBuilder {

    public static let allowedLabels: [String] = [
        "researching", "comparing", "learning", "debugging", "coding",
        "reading", "writing", "shopping", "gaming", "watching", "idle", "unknown"
    ]

    public static func build(packet: BehavioralContextPacket) -> String {
        let labels = allowedLabels.joined(separator: ", ")
        let apps = packet.dominantApps.joined(separator: ", ")
        let topics = packet.repeatedTopics.joined(separator: ", ")
        let workflows = packet.workflowHistory.joined(separator: ", ")
        let confidences = packet.workflowConfidenceHistory.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        let continuity = String(format: "%.2f", packet.contextContinuityMetrics)
        let activity = String(format: "%.2f", packet.activityMetrics)

        return """
        You are a behavioral assistant. Analyze the user's recent sequence of events and temporal patterns over the last 5 minutes to determine what they are currently doing.

        Choose ONE label from this list ONLY:
        \(labels)

        Strict rules:
        - Do NOT map a single app or window title to a behavior (e.g. do NOT assume Xcode means coding, Amazon means shopping, or PDF means studying).
        - Do NOT use examples in your prompt reasoning or logic.
        - Analyze the transition patterns, topics, workflow history, and activity signals over time.
        - Briefly explain the evidence in "reasoning".
        - Prefer "unknown" when evidence is weak, mixed, or contradictory.

        Recent activity (last \(Int(packet.spanSeconds)) seconds):
        - dominant_apps: \(apps)
        - app_transitions: \(packet.appTransitions)
        - title_transitions: \(packet.titleTransitions)
        - repeated_topics: \(topics)
        - workflow_history: \(workflows)
        - workflow_confidence_history: \(confidences)
        - context_continuity: \(continuity)
        - activity_metrics: \(activity)

        Output STRICT JSON with these keys ONLY:
        {"state":"...","confidence":0.0,"reasoning":"..."}
        """
    }
}

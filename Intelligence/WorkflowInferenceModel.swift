import Foundation

// MARK: - Result

/// Strict JSON result the inference layer expects from the local model.
public struct AmbientWorkflowInferenceResult: Sendable, Codable, Equatable {
    public let workflow: String
    public let confidence: Double
    public let why: String
    public let evidence: [String]
    public let suggestedIntentHints: [String]
    public let uncertainty: String

    public init(
        workflow: String,
        confidence: Double,
        why: String,
        evidence: [String],
        suggestedIntentHints: [String],
        uncertainty: String
    ) {
        self.workflow = workflow
        self.confidence = confidence
        self.why = why
        self.evidence = evidence
        self.suggestedIntentHints = suggestedIntentHints
        self.uncertainty = uncertainty
    }

    enum CodingKeys: String, CodingKey {
        case workflow, confidence, why, evidence, uncertainty
        case suggestedIntentHints = "suggested_intent_hints"
    }

    public static let empty = AmbientWorkflowInferenceResult(
        workflow: "unknown",
        confidence: 0.0,
        why: "no_inference",
        evidence: [],
        suggestedIntentHints: [],
        uncertainty: "no_response"
    )
}

// MARK: - Backend protocol

/// Allows the inference call to be swapped out for tests without touching the
/// orchestration layer. The production backend is `OllamaWorkflowInferenceBackend`.
public protocol WorkflowInferenceBackend: Sendable {
    func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult?
}

// MARK: - Ollama backend

/// Calls a local Ollama server running qwen2.5:0.5b. Designed for low latency
/// and tight timeouts so it can run continuously without blocking anything.
public struct OllamaWorkflowInferenceBackend: WorkflowInferenceBackend {
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

    public func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult? {
        let prompt = WorkflowInferencePromptBuilder.build(packet: packet)

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
            options: ["temperature": 0.2, "num_predict": 220],
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
            return try? JSONDecoder().decode(AmbientWorkflowInferenceResult.self, from: jsonData)
        } catch {
            print("[WorkflowInference] failed reason=request_failed error=\(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Prompt builder

/// Builds the qwen2.5:0.5b prompt. The prompt explicitly forbids classification
/// from the current app alone, requires picking from a closed label set, and
/// requests strict JSON.
public enum WorkflowInferencePromptBuilder {

    /// Closed set of allowed workflow labels. The model MUST pick one of these
    /// (or "unknown"). Anything else is normalized to "unknown" downstream.
    public static let allowedLabels: [String] = [
        "studying", "gaming", "coding", "debugging", "researching",
        "writing", "reading", "watching", "emailing", "shopping",
        "comparing", "browsing", "meeting", "idle", "unknown",
    ]

    public static func build(packet: CompressedTemporalPacket) -> String {
        let labels = allowedLabels.joined(separator: ", ")
        let recentApps = packet.recentApps.joined(separator: ", ")
        let recentTitles = packet.recentTitles.prefix(6).joined(separator: " | ")
        let topics = packet.topicTerms.joined(separator: ", ")
        let accepts = packet.recentUserAccepts.joined(separator: ", ")
        let ignores = packet.recentUserIgnores.joined(separator: ", ")
        let ocr = packet.ocrHints.joined(separator: ", ")
        let selection = packet.selectionHints.joined(separator: ", ")

        return """
        You are a workflow inference assistant. Decide what activity the user is
        most likely doing, given the SEQUENCE of recent context signals.

        Choose ONE label from this list ONLY:
        \(labels)

        Strict rules:
        - Do NOT classify based on a single current app. Use the temporal sequence.
        - Prefer "unknown" when evidence is weak, mixed, or contradictory.
        - Use recent app/title transitions and REPEATED topic terms over time.
        - Use idle/typing/pointer patterns to detect attention vs idle.
        - Briefly explain the evidence in "why".
        - Do NOT invent goals the user did not show.

        Recent activity (last \(packet.spanSeconds) seconds, \(packet.eventCount) events):
        - current_app: \(packet.currentApp)
        - recent_apps: \(recentApps)
        - recent_titles: \(recentTitles)
        - topic_terms: \(topics)
        - activity_pattern: \(packet.activityPattern)
        - idle_pattern: \(packet.idlePattern)
        - typing_pattern: \(packet.typingPattern)
        - pointer_pattern: \(packet.pointerPattern)
        - ocr_hints: \(ocr)
        - selection_hints: \(selection)
        - clipboard: \(packet.clipboardMetadata)
        - recent_user_accepts: \(accepts)
        - recent_user_ignores: \(ignores)

        Output STRICT JSON with these keys ONLY:
        {"workflow":"...","confidence":0.0,"why":"...","evidence":["..."],"suggested_intent_hints":["..."],"uncertainty":"..."}
        """
    }
}

// MARK: - Coordinator-facing entry point

/// Wraps an injected backend with input validation, label clamping, confidence
/// clamping, and the canonical `[WorkflowInference]` logs.
public enum WorkflowInferenceModel {

    public static func infer(
        packet: CompressedTemporalPacket,
        backend: WorkflowInferenceBackend
    ) async -> AmbientWorkflowInferenceResult {
        let raw = await backend.infer(packet: packet) ?? AmbientWorkflowInferenceResult.empty

        // Clamp label to closed set; clamp confidence to [0, 1].
        let normalizedLabel: String = WorkflowInferencePromptBuilder
            .allowedLabels.contains(raw.workflow.lowercased())
            ? raw.workflow.lowercased()
            : "unknown"
        let normalizedConfidence = min(max(raw.confidence, 0.0), 1.0)
        let normalizedWorkflow = AmbientWorkflowType(rawString: normalizedLabel).rawValue

        let result = AmbientWorkflowInferenceResult(
            workflow: normalizedWorkflow,
            confidence: normalizedConfidence,
            why: raw.why,
            evidence: raw.evidence,
            suggestedIntentHints: raw.suggestedIntentHints,
            uncertainty: raw.uncertainty
        )

        let confStr = String(format: "%.2f", result.confidence)
        print("[WorkflowInference] model=qwen2.5:0.5b workflow=\(result.workflow) confidence=\(confStr)")
        if !result.evidence.isEmpty {
            let ev = result.evidence.prefix(3).joined(separator: " | ")
            print("[WorkflowInference] evidence=\"\(ev)\"")
        } else if !result.why.isEmpty {
            print("[WorkflowInference] evidence=\"\(result.why.prefix(80))\"")
        }

        return result
    }
}

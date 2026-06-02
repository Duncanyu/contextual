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
    public let provenanceCorrected: Bool?
    public let correctionStrength: String?

    public init(
        workflow: String,
        confidence: Double,
        why: String,
        evidence: [String],
        suggestedIntentHints: [String],
        uncertainty: String,
        provenanceCorrected: Bool? = false,
        correctionStrength: String? = "none"
    ) {
        self.workflow = workflow
        self.confidence = confidence
        self.why = why
        self.evidence = evidence
        self.suggestedIntentHints = suggestedIntentHints
        self.uncertainty = uncertainty
        self.provenanceCorrected = provenanceCorrected
        self.correctionStrength = correctionStrength
    }

    enum CodingKeys: String, CodingKey {
        case workflow, confidence, why, evidence, uncertainty, provenanceCorrected, correctionStrength
        case suggestedIntentHints = "suggested_intent_hints"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflow = try container.decode(String.self, forKey: .workflow)
        confidence = try container.decode(Double.self, forKey: .confidence)
        why = try container.decode(String.self, forKey: .why)
        evidence = try container.decode([String].self, forKey: .evidence)
        suggestedIntentHints = try container.decodeIfPresent([String].self, forKey: .suggestedIntentHints) ?? []
        uncertainty = try container.decode(String.self, forKey: .uncertainty)
        provenanceCorrected = try container.decodeIfPresent(Bool.self, forKey: .provenanceCorrected) ?? false
        correctionStrength = try container.decodeIfPresent(String.self, forKey: .correctionStrength) ?? "none"
    }

    public static let empty = AmbientWorkflowInferenceResult(
        workflow: "unknown",
        confidence: 0.0,
        why: "no_inference",
        evidence: [],
        suggestedIntentHints: [],
        uncertainty: "no_response",
        provenanceCorrected: false,
        correctionStrength: "none"
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
        - High recent title changes usually indicate ACTIVE browsing/research/shopping/comparing,
          NOT idle. Title churn is a strong signal of interaction even when typing is low.
        - "idle" is valid only when there is LOW activity AND LOW context change
          (few title transitions, stable titles, no repeated topic terms).
        - If recent titles or topic terms look like page/search/product/navigation evidence,
          do NOT output "idle". Prefer "browsing", "researching", "shopping", "comparing",
          or "unknown" when unsure.
        - Title churn alone is NOT evidence for "reading" or "writing". If titles are changing
          frequently, the user is likely navigating pages; prefer browsing/research/shopping/comparing.
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

    private static func titleTransitions(from packet: CompressedTemporalPacket) -> Int {
        for hint in packet.selectionHints {
            if hint.hasPrefix("recent_title_changes=") {
                let n = hint.replacingOccurrences(of: "recent_title_changes=", with: "")
                return Int(n) ?? 0
            }
        }
        return 0
    }

    private static func shouldRejectIdle(packet: CompressedTemporalPacket) -> Bool {
        let transitions = titleTransitions(from: packet)
        if transitions >= 3 { return true }
        if packet.recentTitles.count >= 3 { return true }
        if packet.contextShiftDetected { return true }
        if !packet.topicTerms.isEmpty { return true }
        return false
    }

	private static func isGenericTitleChurnOnlyEvidence(_ raw: AmbientWorkflowInferenceResult) -> Bool {
		let combined = ([raw.why] + raw.evidence).joined(separator: " ").lowercased()
		guard combined.contains("recent_title_changes=") else { return false }
		// Generic if there are no other non-trivial tokens besides the churn hint.
		let stripped = combined
			.replacingOccurrences(of: "recent_title_changes=", with: "")
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		// Accept numeric-only + "recent_title_changes" as generic.
		let nonNumeric = stripped.filter { Int($0) == nil }
		return nonNumeric.isEmpty
	}

	private static func packetTokens(_ packet: CompressedTemporalPacket) -> [String] {
		let titles = WorkflowIntelligenceCoordinator.titleTokens(packet.recentTitles)
		return (packet.topicTerms + packet.ocrHints + titles).map { $0.lowercased() }
	}

	private static func matchedKeywords(workflow: String, packet: CompressedTemporalPacket) -> [String] {
		let keys = WorkflowIntelligenceCoordinator.diagnosticKeywords[workflow] ?? []
		let tokens = packetTokens(packet)
		return WorkflowIntelligenceCoordinator.matched(in: tokens, for: keys)
	}

	private static func strongestCompetingWorkflow(
		excluding picked: String,
		packet: CompressedTemporalPacket
	) -> (workflow: String, matched: [String])? {
		let candidates: [String] = ["shopping", "comparing", "researching"]
		var best: (String, [String])? = nil
		for w in candidates where w != picked {
			let m = matchedKeywords(workflow: w, packet: packet)
			if m.count > (best?.1.count ?? 0) {
				best = (w, m)
			}
		}
		// Browsing: no keyword list, but strong title churn implies active navigation.
		let transitions = titleTransitions(from: packet)
		if transitions >= 3 && packet.recentTitles.count >= 3, picked != "browsing" {
			if best == nil || best!.1.isEmpty {
				best = ("browsing", ["title_churn"])
			}
		}
		return best
	}

    public static func infer(
        packet: CompressedTemporalPacket,
        backend: WorkflowInferenceBackend,
        applyProvenanceGuard: Bool = true
    ) async -> AmbientWorkflowInferenceResult {
        let rawOpt = await backend.infer(packet: packet)
        
        let raw: AmbientWorkflowInferenceResult
        if let r = rawOpt {
            raw = r
        } else {
            // Phase 20B/C Deterministic Generic Fallback
            let transitions = titleTransitions(from: packet)
            
            // Generate basic evidence heuristics based on counts rather than magic strings.
            let appIsBrowser = ["Firefox", "Safari", "Google Chrome", "Browser"].contains(packet.currentApp)
            
            // A basic form of entity identification purely by repetition shape.
            let distinctTitles = Set(packet.recentTitles.filter { !$0.isEmpty }).count
            let repeatedTopicTerms = packet.topicTerms.count
            
            // Determine matched sources without looking at what the text actually is
            var matchedSources: [String] = []
            if distinctTitles > 0 { matchedSources.append("titles") }
            if !packet.topicTerms.isEmpty { matchedSources.append("metadata") }
            
            if packet.contextShiftDetected {
                // Phase 20G.1 — if a context epoch shift is in progress, do not
                // apply the deterministic shopping fallback. That fallback is
                // intentionally coarse and would re-lock a stale shopping state
                // right as the user switches to a new topic cluster.
                print("[WorkflowFallback] blocked reason=stale_epoch_conflict old_workflow=shopping")
                raw = .empty
            } else if appIsBrowser && transitions >= 2 && distinctTitles >= 2 && repeatedTopicTerms >= 2 {
                print("[WorkflowFallback] applied workflow=shopping reason=evidence_pattern matched_entities=\(distinctTitles) matched_sources=\(matchedSources.joined(separator: ","))")
                raw = AmbientWorkflowInferenceResult(
                    workflow: "shopping",
                    confidence: 0.65,
                    why: "deterministic_temporal_fallback",
                    evidence: ["model_failed", "strong_temporal_signals", "evidence_pattern"],
                    suggestedIntentHints: [],
                    uncertainty: "fallback",
                    provenanceCorrected: true,
                    correctionStrength: "strong_provenance_correction"
                )
            } else {
                raw = .empty
            }
        }

        // Clamp label to closed set; clamp confidence to [0, 1].
        let normalizedLabel: String = WorkflowInferencePromptBuilder
            .allowedLabels.contains(raw.workflow.lowercased())
            ? raw.workflow.lowercased()
            : "unknown"
        let normalizedConfidence = min(max(raw.confidence, 0.0), 1.0)
        let normalizedWorkflow = AmbientWorkflowType(rawString: normalizedLabel).rawValue

        var result = AmbientWorkflowInferenceResult(
            workflow: normalizedWorkflow,
            confidence: normalizedConfidence,
            why: raw.why,
            evidence: raw.evidence,
            suggestedIntentHints: raw.suggestedIntentHints,
            uncertainty: raw.uncertainty
        )

		// Phase B.1.8 — Generic title-churn evidence is not sufficient for high-confidence
		// idle/reading/writing classifications.
		let transitions = titleTransitions(from: packet)
		let genericChurnOnly = isGenericTitleChurnOnlyEvidence(raw)
		if genericChurnOnly && transitions >= 3 && ["idle", "reading", "writing"].contains(result.workflow) && result.confidence > 0.5 {
			let from = result.workflow
			let fromConf = result.confidence
			let toConf = 0.40
			print("[WorkflowInferenceGuard] downgraded=\(from) reason=generic_title_churn_only confidence_from=\(String(format: "%.2f", fromConf)) confidence_to=\(String(format: "%.2f", toConf))")
			
			result = AmbientWorkflowInferenceResult(
				workflow: from,
				confidence: toConf,
				why: raw.why,
				evidence: raw.evidence,
				suggestedIntentHints: raw.suggestedIntentHints,
				uncertainty: raw.uncertainty
			)
		}

		let finalResult = await postGuardedResult(packet: packet, raw: raw, result: result)

		if applyProvenanceGuard {
			return WorkflowInferenceGuard.apply(result: finalResult, packet: packet)
		} else {
			return finalResult
		}
    }

	private static func postGuardedResult(
		packet: CompressedTemporalPacket,
		raw: AmbientWorkflowInferenceResult,
		result: AmbientWorkflowInferenceResult
	) async -> AmbientWorkflowInferenceResult {
        // Pre-model packet sanity guard (Phase B.1.7): prevent "idle" when there are
        // clear active context changes (title churn, topic terms, or context shifts).
        if result.workflow == "idle", shouldRejectIdle(packet: packet) {
            let transitions = titleTransitions(from: packet)
            let titleCount = packet.recentTitles.count
            let termCount = packet.topicTerms.count
            print("[WorkflowInferenceGuard] rejected=idle reason=active_context_changes title_transitions=\(transitions) recent_titles=\(titleCount) terms=\(termCount)")

            let guarded = AmbientWorkflowInferenceResult(
                workflow: "unknown",
                confidence: min(0.25, result.confidence),
                why: "rejected_idle_active_context_changes",
                evidence: ["rejected_idle_active_context_changes"],
                suggestedIntentHints: result.suggestedIntentHints,
                uncertainty: "guard_rejected_idle"
            )
            let confStr = String(format: "%.2f", guarded.confidence)
            print("[WorkflowInference] model=qwen2.5:0.5b workflow=\(guarded.workflow) confidence=\(confStr)")
            print("[WorkflowInference] evidence=\"\(guarded.why)\"")
            return guarded
        }

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

// MARK: - Workflow Inference Provenance Guard (Phase B.1.9)

public struct WorkflowInferenceGuard {

	private static func titleTransitions(from packet: CompressedTemporalPacket) -> Int {
		for hint in packet.selectionHints {
			if hint.hasPrefix("recent_title_changes=") {
				let n = hint.replacingOccurrences(of: "recent_title_changes=", with: "")
				return Int(n) ?? 0
			}
		}
		return 0
	}

	private static func packetTokens(_ packet: CompressedTemporalPacket) -> [String] {
		let titles = WorkflowIntelligenceCoordinator.titleTokens(packet.recentTitles)
		let apps = (packet.recentApps + [packet.currentApp]).map { $0.lowercased() }
		return (packet.topicTerms + packet.ocrHints + titles + apps).map { $0.lowercased() }
	}

	private static func matchedKeywords(workflow: String, packet: CompressedTemporalPacket) -> [String] {
		let keys = WorkflowIntelligenceCoordinator.diagnosticKeywords[workflow] ?? []
		let tokens = packetTokens(packet)
		return WorkflowIntelligenceCoordinator.matched(in: tokens, for: keys)
	}

	private static func strongestCompetingWorkflow(
		excluding picked: String,
		packet: CompressedTemporalPacket
	) -> (workflow: String, matched: [String])? {
		let candidates: [String] = ["shopping", "comparing", "researching"]
		var best: (String, [String])? = nil
		for w in candidates where w != picked {
			let m = matchedKeywords(workflow: w, packet: packet)
			if m.count > (best?.1.count ?? 0) {
				best = (w, m)
			}
		}
		// Browsing: no keyword list, but strong title churn implies active navigation.
		let transitions = titleTransitions(from: packet)
		if transitions >= 3 && packet.recentTitles.count >= 3, picked != "browsing" {
			if best == nil || best!.1.isEmpty {
				best = ("browsing", ["title_churn"])
			}
		}
		return best
	}

	public static func apply(
		result: AmbientWorkflowInferenceResult,
		packet: CompressedTemporalPacket
	) -> AmbientWorkflowInferenceResult {
		let picked = result.workflow
		let keys = WorkflowIntelligenceCoordinator.diagnosticKeywords[picked]
		let pickedMatches = matchedKeywords(workflow: picked, packet: packet)
		let hasZeroSupport = (keys != nil) && pickedMatches.isEmpty

		if hasZeroSupport {
			let bestCompetitor = strongestCompetingWorkflow(excluding: picked, packet: packet)
			let strongCompetitorExists = bestCompetitor != nil && bestCompetitor!.workflow != "browsing" && !bestCompetitor!.matched.isEmpty

			if result.confidence >= 0.80 {
				let originalConfidence = result.confidence
				print("[WorkflowInferenceGuard] rejected=\(picked) reason=zero_provenance_high_confidence confidence=\(String(format: "%.2f", originalConfidence))")

				if strongCompetitorExists, let best = bestCompetitor {
					let matchedStr = best.matched.prefix(4).joined(separator: ",")
					print("[WorkflowInferenceGuard] corrected from=\(picked) to=\(best.workflow) reason=zero_support_strong_competitor matched=\(matchedStr)")
					return AmbientWorkflowInferenceResult(
						workflow: best.workflow,
						confidence: 0.75,
						why: "corrected_zero_support_strong_competitor",
						evidence: ["corrected_from=\(picked) matched=\(matchedStr)"],
						suggestedIntentHints: result.suggestedIntentHints,
						uncertainty: "guard_corrected",
						provenanceCorrected: true,
						correctionStrength: "strong"
					)
				} else {
					return AmbientWorkflowInferenceResult(
						workflow: "unknown",
						confidence: 0.35,
						why: "rejected_zero_provenance_high_confidence",
						evidence: ["rejected_zero_provenance_high_confidence"],
						suggestedIntentHints: result.suggestedIntentHints,
						uncertainty: "guard_rejected",
						provenanceCorrected: false,
						correctionStrength: "none"
					)
				}
			} else if strongCompetitorExists, let best = bestCompetitor {
				let matchedStr = best.matched.prefix(4).joined(separator: ",")
				print("[WorkflowInferenceGuard] corrected from=\(picked) to=\(best.workflow) reason=zero_support_strong_competitor matched=\(matchedStr)")
				return AmbientWorkflowInferenceResult(
					workflow: best.workflow,
					confidence: 0.75,
					why: "corrected_zero_support_strong_competitor",
					evidence: ["corrected_from=\(picked) matched=\(matchedStr)"],
					suggestedIntentHints: result.suggestedIntentHints,
					uncertainty: "guard_corrected",
					provenanceCorrected: true,
					correctionStrength: "strong"
				)
			}
		}

		return result
	}
}

import Foundation

/// Phase 20D.5 — generator is now evidence-driven rather than
/// workflow-whitelist driven. Every suppression path emits a
/// `[JarvisSuppression]` log so no gate is silent, and a
/// `[JarvisPipeline]` decision line is emitted whether the suggestion is
/// shown or suppressed.
public struct JarvisSuggestionGenerator: Sendable {

    /// Confidence-floor on the workflow trust score. 0.50 is intentionally
    /// lower than the previous 0.60 so a stabilized debugging/research/
    /// studying/writing session can surface a suggestion before its trust
    /// score has fully matured.
    public static let trustScoreFloor: Double = 0.50

    public static func generate(
        workflowState: WorkflowState,
        behavioralRecord: BehavioralStateRecord,
        packet: CompressedTemporalPacket,
        recentTitles: [String],
        repeatedTerms: [String],
        forceShow: Bool = false
    ) async -> AmbientJarvisSuggestion? {

        let workflow = workflowState.workflowType
        let behavior = behavioralRecord.state
        print("[JarvisSuggestionGenerator] started workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) force_show=\(forceShow)")

        // Phase 20D.5 — no more workflow whitelist. Workflows are only
        // suppressed when they are structurally meaningless for ambient
        // assistance: `unknown` or `idle`.
        if workflow == .unknown || workflow == .idle {
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=workflow_not_actionable")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=workflow_not_actionable")
            return nil
        }

        // Phase 20D.5 — no more behavior whitelist. Behaviors are only
        // suppressed when they signal no engagement (`unknown` / `idle`).
        if behavior == .unknown || behavior == .idle {
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=behavior_not_actionable")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=behavior_not_actionable")
            return nil
        }

        // Confidence floor — log explicitly when we miss it. Manual invoke
        // bypasses this gate because the user is explicitly asking now.
        let trust = workflowState.workflowTrustScore
        if !forceShow && trust < Self.trustScoreFloor {
            let trustStr = String(format: "%.2f", trust)
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=confidence_too_low trust=\(trustStr) floor=\(Self.trustScoreFloor)")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=confidence_too_low")
            return nil
        }

        // Context-sufficiency — need at least one repeated term or two
        // distinct titles. (This isn't workflow-specific; it just prevents
        // surfacing on a single uninteresting tick.) Manual invoke also
        // bypasses this gate.
        let hasRepeatedTerms = !repeatedTerms.isEmpty || !packet.topicTerms.isEmpty
        let hasRepeatedTitles = recentTitles.count > 1 || packet.recentTitles.count > 1
        if !forceShow && !hasRepeatedTerms && !hasRepeatedTitles {
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=insufficient_context")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=insufficient_context")
            return nil
        }

        // 2. Wording generation. The prompt now interpolates the workflow as
        // DATA — no per-workflow code path. The model is allowed to vary
        // wording across debugging / studying / research / shopping naturally.
        let terms = Array(repeatedTerms.isEmpty ? packet.topicTerms : repeatedTerms)
        let titles = Array(recentTitles.isEmpty ? packet.recentTitles : recentTitles)

        var generatedTitle = ""
        let model = "qwen2.5:0.5b"

        if await ModelManager.shared.isGenerationAvailable() {
            let termsDesc = terms.prefix(3).joined(separator: ", ")
            let titlesDesc = titles.prefix(3).joined(separator: " | ")
            let prompt = """
            Generate a short, friendly observation (max 12 words) about what the user appears to be doing right now. Start with "Looks like you're" and use the workflow/behavior/terms below.

            Workflow: \(workflow.rawValue)
            Behavior: \(behavior.rawValue)
            Recent terms: \(termsDesc)
            Recent titles: \(titlesDesc)

            Strict rules:
            - Do NOT use action verbs (click, open, navigate, search, buy, install, run).
            - Do NOT invent specifics not in the terms/titles.
            - Output one line only.
            """

            do {
                let raw = try await LocalAIClient.shared.generate(
                    prompt: prompt,
                    model: model,
                    numPredict: 24,
                    temperature: 0.3,
                    purpose: "jarvis_suggestion",
                    schema: nil
                )
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
                if !cleaned.isEmpty && cleaned.count < 140 {
                    generatedTitle = cleaned
                }
            } catch {
                print("[JarvisSuggestionGenerator] wording generation failed, error=\(error)")
            }
        }

        // Deterministic fallback — generic across workflows. Workflow rawValue
        // is the only piece of data interpolated, exactly like the model
        // prompt; this is data substitution, not workflow branching.
        if generatedTitle.isEmpty {
            generatedTitle = "Looks like you're \(workflow.rawValue). Want a hand making sense of it?"
        }

        let subtitle = "Context-only — preview based on your recent activity."

        // Safety check.
        guard JarvisSuggestionValidator.validate(title: generatedTitle, subtitle: subtitle) else {
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=control_language_in_wording")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=control_language_in_wording")
            return nil
        }

        // Intent is workflow-derived (data) — engine still drives semantics
        // via `judgment + intent`, never via `kind`.
        let intent = "understand_\(workflow.rawValue)_context"
        let intentGoal = "Help the user make sense of their recent \(workflow.rawValue) activity using only screen context."

        let suggestion = AmbientJarvisSuggestion(
            title: generatedTitle,
            subtitle: subtitle,
            whyNow: "\(behavior.rawValue) behavior in \(workflow.rawValue) workflow",
            workflow: workflow.rawValue,
            behavior: behavior.rawValue,
            confidence: max(workflowState.confidence, behavioralRecord.confidence),
            kind: .compare_context,
			intent: intent,
			intentConfidence: max(workflowState.confidence, behavioralRecord.confidence),
			intentGoal: intentGoal,
            executionMode: .context_only_preview,
            previewOnly: true,
            sourceEvidence: terms.joined(separator: ",")
        )

        print("[JarvisSuggestionGenerator] generated kind=\(suggestion.kind.rawValue) intent=\(intent) title=\"\(suggestion.title)\"")
        print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=\(intent) judgment=upstream artifact=upstream decision=shown reason=evidence_sufficient")
        return suggestion
    }
}

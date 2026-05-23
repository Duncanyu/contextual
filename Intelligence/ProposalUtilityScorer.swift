// ProposalUtilityScorer.swift
// Generalized situational usefulness evaluator for generated proposals.
//
// Called AFTER planner candidate generation, BEFORE HookScriptDiscovery.
// Rejects or boosts proposals based on semantic utility signals derived
// from the goal, capability categories, and live context — no hardcoded
// website/app rules.
//
// Signals:
//   title_overlap       — goal tokens that already appear in the window title (high = redundant)
//   transformation_depth — capability categories that indicate synthesis vs. pure sensing
//   redundancy_score    — goal describes visible state rather than transforming it
//   actionability       — goal produces useful output (extraction/comparison/reasoning)
//   workflow_alignment  — capability categories match the inferred workflow
//
// Utility = weighted combination.
// Threshold: reject < 0.22, boost > 0.70.
//
// Logs:
//   [ProposalUtility] title_overlap=... transformation_depth=... redundancy_score=...
//   [ProposalUtility] utility_score=...
//   [ProposalUtility] rejected reason=low_situational_utility score=...
//   [ProposalUtility] boosted reason=high_workflow_alignment score=...

import Foundation

// MARK: - Result

struct ProposalUtilityResult {
    let score: Double                 // 0.0 … 1.0
    let decision: Decision
    let titleOverlap: Double
    let transformationDepth: Double
    let redundancyScore: Double
    let actionability: Double
    let workflowAlignment: Double

    enum Decision: Equatable {
        case accept
        case boost(reason: String)
        case reject(reason: String)
    }

    var shouldReject: Bool {
        if case .reject = decision { return true }
        return false
    }
}

// MARK: - Scorer

enum ProposalUtilityScorer {

    // MARK: - Entry point

    /// Evaluate the situational utility of a proposed goal+capability pair.
    ///
    /// - Parameters:
    ///   - goal: The planner's possibleUserGoal string.
    ///   - cats: Normalised capability category tokens from the planner.
    ///   - snapshot: Live canonical context snapshot.
    ///   - situational: Situational context (workflow, app, title).
    static func evaluate(
        goal: String,
        cats: [String],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        situational: SituationalContextSnapshot
    ) -> ProposalUtilityResult {

        let goalTokens   = tokenise(goal)
        let titleTokens  = tokenise(snapshot.windowTitle)
        let catSet       = Set(cats.map { $0.lowercased() })

        // 1. Title overlap — fraction of goal tokens already in the window title.
        //    High overlap means the goal is merely restating what's visible.
        let titleOverlap: Double = {
            guard !goalTokens.isEmpty else { return 0 }
            let overlap = goalTokens.intersection(titleTokens)
            return Double(overlap.count) / Double(goalTokens.count)
        }()

        // 2. Transformation depth — capability categories that indicate meaningful
        //    processing rather than pure sensing or pass-through.
        let transformationDepth: Double = {
            if catSet.contains("compare")  { return 1.0 }
            if catSet.contains("organize") { return 0.90 }
            if catSet.contains("extract")  { return 0.70 }
            if catSet.contains("reason")   { return 0.65 }
            if catSet.contains("utility")  { return 0.55 }
            if catSet.contains("memory")   { return 0.45 }
            if catSet.contains("output")   { return 0.30 }
            if catSet.contains("context")  { return 0.15 }
            return 0.20   // unknown cats default
        }()

        // 3. Redundancy score — goal tokens matching contextSummary / OCR suggest
        //    it is describing what is already present rather than transforming it.
        let redundancyScore: Double = {
            let contextText = [
                snapshot.contextSummary,
                snapshot.recentOCRExcerpt,
                snapshot.selectedText
            ].compactMap { $0 }.joined(separator: " ")
            guard !goalTokens.isEmpty, !contextText.isEmpty else { return 0 }
            let ctxTokens = tokenise(contextText)
            let overlap = goalTokens.intersection(ctxTokens)
            let raw = Double(overlap.count) / Double(goalTokens.count)
            // Penalise only when overlap is substantial AND no synthesis verb present.
            let synthesisVerbs: Set<String> = [
                "summarize", "compare", "explain", "analyze", "extract",
                "organize", "identify", "rank", "evaluate", "synthesize"
            ]
            let hasSynthesisVerb = !goalTokens.intersection(synthesisVerbs).isEmpty
            return hasSynthesisVerb ? raw * 0.4 : raw
        }()

        // 4. Actionability — does the goal produce output that reduces user effort?
        //    Inferred from synthesis-type verbs in the goal and high-value cats.
        let actionability: Double = {
            let actionVerbs: Set<String> = [
                "summarize", "compare", "extract", "explain", "analyze",
                "identify", "rank", "organize", "evaluate", "create",
                "generate", "build", "classify", "detect", "find"
            ]
            let goalHasActionVerb = !goalTokens.intersection(actionVerbs).isEmpty
            let catHasHighValue = catSet.contains("compare") || catSet.contains("extract")
                               || catSet.contains("reason")  || catSet.contains("organize")
            if goalHasActionVerb && catHasHighValue { return 1.0 }
            if goalHasActionVerb || catHasHighValue { return 0.65 }
            return 0.25
        }()

        // 5. Workflow alignment — capability categories match the inferred workflow.
        let workflowAlignment: Double = {
            let wf = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
            switch wf {
            case .debugging:
                let matches = catSet.intersection(["reason", "extract", "utility", "compare"])
                return matches.isEmpty ? 0.30 : 0.85
            case .browsing, .research, .studying:
                let matches = catSet.intersection(["extract", "compare", "organize", "reason"])
                return matches.isEmpty ? 0.35 : 0.80
            case .writing, .editing:
                let matches = catSet.intersection(["reason", "organize", "utility"])
                return matches.isEmpty ? 0.30 : 0.75
            case .reviewing, .comparing:
                let matches = catSet.intersection(["compare", "extract", "reason"])
                return matches.isEmpty ? 0.30 : 0.90
            default:
                return 0.50
            }
        }()

        // Weighted utility score.
        // Weights: transformation (35%) + low-title-overlap (20%) + actionability (20%)
        //        + low-redundancy (15%) + workflow (10%)
        let utility = 0.35 * transformationDepth
                    + 0.20 * (1.0 - min(1.0, titleOverlap))
                    + 0.20 * actionability
                    + 0.15 * (1.0 - min(1.0, redundancyScore))
                    + 0.10 * workflowAlignment

        print("[ProposalUtility] title_overlap=\(fmt(titleOverlap)) transformation_depth=\(fmt(transformationDepth)) redundancy_score=\(fmt(redundancyScore)) actionability=\(fmt(actionability)) workflow_alignment=\(fmt(workflowAlignment))")
        print("[ProposalUtility] utility_score=\(fmt(utility)) goal=\"\(String(goal.prefix(60)))\" cats=[\(cats.joined(separator: ","))]")

        // Decision thresholds
        if utility < 0.22 {
            let reason: String
            if titleOverlap > 0.70 {
                reason = "high_title_overlap"
            } else if redundancyScore > 0.70 {
                reason = "high_redundancy"
            } else if transformationDepth < 0.20 {
                reason = "low_transformation_depth"
            } else {
                reason = "low_situational_utility"
            }
            print("[ProposalUtility] rejected reason=\(reason) score=\(fmt(utility))")
            return ProposalUtilityResult(
                score: utility, decision: .reject(reason: reason),
                titleOverlap: titleOverlap, transformationDepth: transformationDepth,
                redundancyScore: redundancyScore, actionability: actionability,
                workflowAlignment: workflowAlignment
            )
        }

        if utility >= 0.70 {
            let boostReason = workflowAlignment >= 0.80 ? "high_workflow_alignment"
                            : transformationDepth >= 0.90 ? "high_transformation_depth"
                            : "high_utility"
            print("[ProposalUtility] boosted reason=\(boostReason) score=\(fmt(utility))")
            return ProposalUtilityResult(
                score: utility, decision: .boost(reason: boostReason),
                titleOverlap: titleOverlap, transformationDepth: transformationDepth,
                redundancyScore: redundancyScore, actionability: actionability,
                workflowAlignment: workflowAlignment
            )
        }

        return ProposalUtilityResult(
            score: utility, decision: .accept,
            titleOverlap: titleOverlap, transformationDepth: transformationDepth,
            redundancyScore: redundancyScore, actionability: actionability,
            workflowAlignment: workflowAlignment
        )
    }

    // MARK: - Helpers

    private static func tokenise(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 4 }
        )
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}

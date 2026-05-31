import Foundation

/// Picks the artifact *type label* from a `ContextJudgment`. That label is the
/// only structural information the engine uses to render — section content is
/// always populated from evidence (model or fallback from judgment.rationale).
///
/// **No switch on workflow.** **No switch on goal-string.** The only inputs
/// are judgment fields, and the function is < 15 lines.
///
/// Output labels:
///   - clarification_brief  — when the items are not directly comparable
///   - recommendation_brief — product choice + valid comparison
///   - research_brief       — knowledge acquisition
///   - diagnostic_brief     — diagnostic activity
///   - knowledge_brief      — fallback for everything else
public enum ArtifactSelector {

    public static func type(for judgment: ContextJudgment) -> String {
        // Invalid comparison ALWAYS produces a clarification brief — even if
        // the decision type still says productChoice. This is the structural
        // guard against the "Anker Power Bank vs SOLIX F3800" demo failure.
        if judgment.comparisonValidity == .invalid {
            let reason = "judgment_invalid_comparison"
            print("[ArtifactSelector] type=clarification_brief reason=\(reason)")
            return "clarification_brief"
        }
        let label: String
        switch judgment.decisionType {
        case .productChoice:        label = "recommendation_brief"
        case .knowledgeAcquisition: label = "research_brief"
        case .diagnostic:           label = "diagnostic_brief"
        case .unclear:              label = "knowledge_brief"
        }
        print("[ArtifactSelector] type=\(label) reason=judgment")
        return label
    }
}

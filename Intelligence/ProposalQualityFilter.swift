import Foundation

/// Phase 26.2 — Filters out low-quality generated action proposals.
///
/// Rejects:
///   - "Review [keyword list]" patterns (e.g. "Review first, realism, shooter before testing")
///   - "Review X in Y" generic web titles (e.g. "Review editor in Piskel - Free online sprite editor")
///   - Checklists from title_only evidence without real content
///   - Generic game design checklists from title_only
///
/// Required logs: [ProposalQualityFilter]
enum ProposalQualityFilter {

	struct AcceptanceResult {
		let accepted: Bool
		let reason: String?
	}

    static func hasPromptLeakOrCapabilityId(_ title: String) -> Bool {
        let lower = title.lowercased()
        let capabilityIds: Set<String> = [
            "summarize_context", "create_next_steps", "generate_quiz", "create_review_plan",
            "create_study_outline", "synthesize_sources", "explain_context", "summarize_reference",
            "extract_action_items", "draft_reply", "compare_options", "decision_matrix",
            "create_checklist", "improve_project"
        ]
        for capId in capabilityIds {
            if lower.contains(capId) {
                return true
            }
        }
        let snakePattern = #"[a-zA-Z0-9]+_[a-zA-Z0-9]+"#
        if title.range(of: snakePattern, options: .regularExpression) != nil {
            return true
        }
        let actionVerbColonPattern = #"^[A-Za-z]+:\s"#
        if title.range(of: actionVerbColonPattern, options: .regularExpression) != nil {
            return true
        }
        if lower.contains("generated summary") {
            return true
        }
        let promptPhrases = [
            "concise summary", "generate a concise", "create a summary", "generate a summary",
            "output type", "max 10 words", "short action proposal", "action verb", "helpful assistant",
            "you are a", "based on your", "summarize_context:"
        ]
        for phrase in promptPhrases {
            if lower.contains(phrase) {
                return true
            }
        }
        return false
    }

    /// Returns true if the proposal passes quality filtering.
    /// Returns false (rejected) if the proposal is low-quality junk.
    static func accept(
        title: String,
        capabilityId: String,
        evidenceQuality: String,
        hasRealContent: Bool
    ) -> Bool {
		acceptanceResult(
			title: title,
			capabilityId: capabilityId,
			evidenceQuality: evidenceQuality,
			hasRealContent: hasRealContent
		).accepted
	}

	static func acceptanceResult(
		title: String,
		capabilityId: String,
		evidenceQuality: String,
		hasRealContent: Bool
	) -> AcceptanceResult {
        if hasPromptLeakOrCapabilityId(title) {
            print("[ProposalQualityFilter] rejected reason=raw_capability_or_prompt_leak")
            return AcceptanceResult(accepted: false, reason: "raw_capability_or_prompt_leak")
        }
        let lower = title.lowercased()

        // ── Reject "Review [keyword list]" ──────────────────────────────
        // Pattern: "Review X, Y, Z before ..." or "Review X, Y, Z"
        if lower.hasPrefix("review ") {
            // Check for comma-separated keyword list
            let afterReview = String(lower.dropFirst(7))
            let commaCount = afterReview.filter { $0 == "," }.count
            if commaCount >= 2 {
                print("[ProposalQualityFilter] rejected reason=keyword_list_review title=\"\(title.prefix(60))\"")
                return AcceptanceResult(accepted: false, reason: "keyword_list_review")
            }

            // Check for "Review X in Y" — generic web title pattern
            if afterReview.contains(" in ") && afterReview.contains(" - ") {
                print("[ProposalQualityFilter] rejected reason=generic_title_review title=\"\(title.prefix(60))\"")
                return AcceptanceResult(accepted: false, reason: "generic_title_review")
            }

            // Check for very generic "Review editor/viewer/settings" patterns
            let genericSuffixes = ["editor", "viewer", "settings", "page", "site", "website", "tool"]
            if genericSuffixes.contains(where: { afterReview.hasPrefix($0) || afterReview.contains(" \($0) ") }) {
                print("[ProposalQualityFilter] rejected reason=generic_title_review title=\"\(title.prefix(60))\"")
                return AcceptanceResult(accepted: false, reason: "generic_title_review")
            }
        }

        // ── Reject fake debugging actions from title-only ───────────────
        let debuggingKeywords = ["diagnose", "investigate", "fix", "debug", "failure", "crash", "error", "stack trace"]
        let isDebuggingTitle = debuggingKeywords.contains(where: { lower.contains($0) })
        if isDebuggingTitle && evidenceQuality == "title_only" && !hasRealContent {
            // Check for explicit error markers in title as a small exception
            let errorMarkers = ["error:", "failed:", "crash:", "exception:"]
            if !errorMarkers.contains(where: { lower.contains($0) }) {
                print("[ProposalQualityFilter] rejected reason=debugging_without_error_evidence title=\"\(title.prefix(60))\"")
                return AcceptanceResult(accepted: false, reason: "debugging_without_error_evidence")
            }
        }

        // ── Reject title_only checklists when no real content ───────────
        let checklistCapabilities: Set<String> = [
            "create_next_steps", "create_checklist", "create_game_design_checklist",
            "create_controls_polish_checklist", "create_asset_sound_checklist",
            "generate_test_checklist",
        ]
        if checklistCapabilities.contains(capabilityId) && evidenceQuality == "title_only" && !hasRealContent {
            print("[ProposalQualityFilter] rejected reason=title_only_checklist_too_weak"
                + " capability=\(capabilityId)"
                + " title=\"\(title.prefix(60))\"")
            return AcceptanceResult(accepted: false, reason: "title_only_checklist_too_weak")
        }

        return AcceptanceResult(accepted: true, reason: nil)
    }
}

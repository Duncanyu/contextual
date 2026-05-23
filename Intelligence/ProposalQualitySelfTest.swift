// ProposalQualitySelfTest.swift
// Self-tests for Task 1 (utility scoring) and Task 2 (hook runtime).
//
// Triggered by: CONTEXTUAL_RUN_PROPOSAL_QUALITY_SELFTEST=1
//
// Expected output:
//   [ProposalQualitySelfTest] started
//   [ProposalQualitySelfTest] case=low_utility_rejection result=pass
//   [ProposalQualitySelfTest] case=high_utility_boost result=pass
//   [ProposalQualitySelfTest] case=synthesis_goal_accepted result=pass
//   [ProposalQualitySelfTest] case=summarize_visible_page_produces_output result=pass
//   [ProposalQualitySelfTest] case=extract_product_specs_produces_output result=pass
//   [ProposalQualitySelfTest] case=compare_product_specs_produces_output result=pass
//   [ProposalQualitySelfTest] case=hook_chain_composition result=pass
//   [ProposalQualitySelfTest] case=float_eligible_high_utility result=pass
//   [ProposalQualitySelfTest] case=float_suppressed_low_novelty result=pass
//   [ProposalQualitySelfTest] ok=true failures=0

import Foundation

@MainActor
enum ProposalQualitySelfTest {

    static func run() async {
        print("[ProposalQualitySelfTest] started")
        var failures = 0

        func pass(_ name: String) {
            print("[ProposalQualitySelfTest] case=\(name) result=pass")
        }
        func fail(_ name: String, _ reason: String) {
            print("[ProposalQualitySelfTest] case=\(name) result=fail reason=\(reason)")
            failures += 1
        }

        let now = Date()

        // Product page snapshot — rich OCR, browsing workflow
        let productSnapshot = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Safari",
            windowTitle: "Spigen Rugged Armor AirPods 4 Case - Matte Black",
            inferredWorkflow: .browsing,
            selectedText: nil,
            clipboardText: nil,
            recentOCRExcerpt: "Spigen Rugged Armor AirPods 4 Case. Price $19.99. Rating 4.6 stars. 1,234 ratings. Compatible with AirPods 4. Available in Matte Black.",
            workflowConfidence: 0.74
        )
        let situational = SituationalContextSynthesizer.synthesize(from: productSnapshot, referenceTime: now)

        // Notes page snapshot — writing workflow, no OCR
        let notesSnapshot = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Notes",
            windowTitle: "Meeting notes Q4 review",
            inferredWorkflow: .writing,
            selectedText: nil,
            clipboardText: nil,
            recentOCRExcerpt: nil,
            workflowConfidence: 0.60
        )
        let notesSituational = SituationalContextSynthesizer.synthesize(from: notesSnapshot, referenceTime: now)

        // ── Task 1: Utility Scoring ──────────────────────────────────────────────

        // Case 1: Low-utility rejection — goal is an exact restatement of the title with only sensing
        // capability (context) and no transformation. Pure "show me what I can already see" pattern.
        let lowUtility = ProposalUtilityScorer.evaluate(
            goal: "Show spigen rugged armor airpods case matte black listing",
            cats: ["context"],
            snapshot: productSnapshot,
            situational: situational
        )
        if lowUtility.shouldReject {
            pass("low_utility_rejection")
        } else {
            fail("low_utility_rejection", "expected reject got score=\(String(format: "%.2f", lowUtility.score)) decision=\(lowUtility.decision)")
        }

        // Case 2: High-utility — compare+extract on a product page is clearly transformative.
        let highUtility = ProposalUtilityScorer.evaluate(
            goal: "Compare specifications and identify best value for money",
            cats: ["compare", "extract"],
            snapshot: productSnapshot,
            situational: situational
        )
        if !highUtility.shouldReject && highUtility.score >= 0.45 {
            pass("high_utility_boost")
        } else {
            fail("high_utility_boost", "expected high-utility got score=\(String(format: "%.2f", highUtility.score)) rejected=\(highUtility.shouldReject)")
        }

        // Case 3: Synthesis goal on a notes page → accepted (not rejected).
        let synthUtility = ProposalUtilityScorer.evaluate(
            goal: "Summarize key action items and organize into a checklist",
            cats: ["organize", "extract"],
            snapshot: notesSnapshot,
            situational: notesSituational
        )
        if !synthUtility.shouldReject {
            pass("synthesis_goal_accepted")
        } else {
            fail("synthesis_goal_accepted", "expected accept got score=\(String(format: "%.2f", synthUtility.score))")
        }

        // ── Task 2: Hook Runtime ─────────────────────────────────────────────────

        // Case 4: summarize_visible_page → produces non-empty output
        let summaryResult = await HookExecutionSandbox.shared.execute(
            chain: ["observe_current_context", "summarize_visible_page"],
            snapshot: productSnapshot,
            mode: .sample
        )
        if summaryResult.success, let out = summaryResult.finalOutput, !out.isEmpty {
            pass("summarize_visible_page_produces_output")
        } else {
            fail("summarize_visible_page_produces_output",
                 "success=\(summaryResult.success) output=\(summaryResult.finalOutput?.prefix(40) ?? "nil") failed_at=\(summaryResult.failedAt ?? "none")")
        }

        // Case 5: extract_product_specs → output contains structured attributes
        let specsResult = await HookExecutionSandbox.shared.execute(
            chain: ["observe_current_context", "extract_product_specs"],
            snapshot: productSnapshot,
            mode: .sample
        )
        let specsOut = specsResult.finalOutput ?? ""
        if specsResult.success && (specsOut.contains("price") || specsOut.contains("rating") || specsOut.contains("name")) {
            pass("extract_product_specs_produces_output")
        } else {
            fail("extract_product_specs_produces_output",
                 "success=\(specsResult.success) output=\(specsOut.prefix(80)) failed_at=\(specsResult.failedAt ?? "none")")
        }

        // Case 6: compare_product_specs → consumes product_attributes, produces comparison
        let compareResult = await HookExecutionSandbox.shared.execute(
            chain: ["observe_current_context", "extract_product_specs", "compare_product_specs"],
            snapshot: productSnapshot,
            mode: .sample
        )
        if compareResult.success, let out = compareResult.finalOutput, !out.isEmpty {
            pass("compare_product_specs_produces_output")
        } else {
            fail("compare_product_specs_produces_output",
                 "success=\(compareResult.success) output=\(compareResult.finalOutput?.prefix(80) ?? "nil")")
        }

        // Case 7: Full chain → extract + compare + present_table → produces final table
        let compositionResult = await HookExecutionSandbox.shared.execute(
            chain: ["observe_current_context", "extract_product_specs", "compare_product_specs", "present_table"],
            snapshot: productSnapshot,
            mode: .sample
        )
        if compositionResult.success && compositionResult.completedCount >= 3 {
            pass("hook_chain_composition")
        } else {
            fail("hook_chain_composition",
                 "success=\(compositionResult.success) completed=\(compositionResult.completedCount) failed_at=\(compositionResult.failedAt ?? "none")")
        }

        // ── Task 3: Float Eligibility (proxy via utility score) ──────────────────

        // Case 8: High-utility + strong cats → score passes float threshold
        let floatUtility = ProposalUtilityScorer.evaluate(
            goal: "Compare and analyze all visible product specs to find best value",
            cats: ["compare", "extract", "reason"],
            snapshot: productSnapshot,
            situational: situational
        )
        if floatUtility.score >= 0.50 {
            pass("float_eligible_high_utility")
        } else {
            fail("float_eligible_high_utility",
                 "expected score>=0.50 got \(String(format: "%.2f", floatUtility.score))")
        }

        // Case 9: Circular/title-restatement goal → rejected by utility gate (suppressed upstream of float)
        let suppressedUtility = ProposalUtilityScorer.evaluate(
            goal: "Spigen Rugged Armor AirPods case Matte Black listing",
            cats: ["context"],
            snapshot: productSnapshot,
            situational: situational
        )
        if suppressedUtility.shouldReject {
            pass("float_suppressed_low_novelty")
        } else {
            fail("float_suppressed_low_novelty",
                 "expected reject got score=\(String(format: "%.2f", suppressedUtility.score))")
        }

        print("[ProposalQualitySelfTest] ok=\(failures == 0) failures=\(failures)")
    }
}

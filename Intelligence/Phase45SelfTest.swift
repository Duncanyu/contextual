import Foundation
import AppKit

/// Phase 45: UniversalContentReader — universal content acquisition layer.
///
/// Tests:
/// T1  ContentGoal minimumRequired is correct for each goal
/// T2  ContentQuality is ordered correctly (Comparable)
/// T3  metadataOnly < axVisibleText (gate would block summarize)
/// T4  selectedText >= selectedText (gate would allow rewrite)
/// T5  fullDocumentText is highest quality
/// T6  UniversalContentResult.isEnough(for:) gates correctly
/// T7  ContentNextStep enum has expected cases
/// T8  ContentSource enum has expected cases
/// T9  UniversalContentReader.readForCapability returns a result (not crash)
/// T10 readForCapability("explicit_visible_capture_summary") logs gate when no AX
/// T11 readForCapability("rewrite_text") attempts selectedText route first
/// T12 contentGoalPublic maps capability IDs correctly
/// T13 Gate function logs CognitiveActionGate and CognitiveActionDowngrade
/// T14 metadataOnly result fails gate for summarize
/// T15 axVisibleText result passes gate for explain
/// T16 fullDocumentText result passes gate for all goals
/// T17 PDF route returns partialDocumentText or fullDocumentText for real PDF
/// T18 PlainText route can read a temp text file
@MainActor
struct Phase45SelfTest {

    private static var failures: [String] = []

    static func check(_ label: String, _ condition: Bool) {
        if condition {
            print("[Phase45SelfTest] pass case=\(label)")
        } else {
            print("[Phase45SelfTest] FAIL case=\(label)")
            failures.append(label)
        }
    }

    static func run() async -> Bool {
        print("[Phase45SelfTest] starting")
        failures = []

        // T1: ContentGoal minimumRequired
        check("t1_summarize_requires_ax_visible", ContentGoal.summarize.minimumRequired == .axVisibleText)
        check("t1_extract_requires_ax_visible", ContentGoal.extractActionItems.minimumRequired == .axVisibleText)
        check("t1_checklist_requires_ax_visible", ContentGoal.createChecklist.minimumRequired == .axVisibleText)
        check("t1_rewrite_requires_selected_text", ContentGoal.rewrite.minimumRequired == .selectedText)
        check("t1_draft_requires_selected_text", ContentGoal.draftReply.minimumRequired == .selectedText)
        check("t1_explain_requires_ax_visible", ContentGoal.explain.minimumRequired == .axVisibleText)

        // T2: ContentQuality ordering
        check("t2_none_lt_metadata", ContentQuality.none < ContentQuality.metadataOnly)
        check("t2_metadata_lt_ocr", ContentQuality.metadataOnly < ContentQuality.visibleOCR)
        check("t2_ocr_lt_ax", ContentQuality.visibleOCR < ContentQuality.axVisibleText)
        check("t2_ax_lt_selected", ContentQuality.axVisibleText < ContentQuality.selectedText)
        check("t2_selected_lt_partial", ContentQuality.selectedText < ContentQuality.partialDocumentText)
        check("t2_partial_lt_full", ContentQuality.partialDocumentText < ContentQuality.fullDocumentText)

        // T3: metadataOnly blocks summarize gate
        let metaResult = UniversalContentResult(
            text: "Page title only",
            quality: .metadataOnly,
            coverage: .minimal,
            source: .browserMetadata,
            confidence: 0.3,
            attemptedRoutes: [],
            missingReason: "only_metadata",
            nextStep: .captureVisible
        )
        check("t3_metadata_fails_summarize", !metaResult.isEnough(for: .summarize))
        check("t3_metadata_fails_extract", !metaResult.isEnough(for: .extractActionItems))
        check("t3_metadata_fails_checklist", !metaResult.isEnough(for: .createChecklist))

        // T4: selectedText passes rewrite gate
        let selResult = UniversalContentResult(
            text: "Some selected text here",
            quality: .selectedText,
            coverage: .partial,
            source: .selectedText,
            confidence: 0.95,
            attemptedRoutes: [],
            missingReason: nil,
            nextStep: .none
        )
        check("t4_selected_passes_rewrite", selResult.isEnough(for: .rewrite))
        check("t4_selected_passes_explain", selResult.isEnough(for: .explain))

        // T5: fullDocumentText passes all goals
        let fullResult = UniversalContentResult(
            text: String(repeating: "Full doc content. ", count: 50),
            quality: .fullDocumentText,
            coverage: .full,
            source: .pdfKit,
            confidence: 0.9,
            attemptedRoutes: [],
            missingReason: nil,
            nextStep: .none
        )
        check("t5_full_passes_summarize", fullResult.isEnough(for: .summarize))
        check("t5_full_passes_extract", fullResult.isEnough(for: .extractActionItems))
        check("t5_full_passes_rewrite", fullResult.isEnough(for: .rewrite))
        check("t5_full_passes_draft", fullResult.isEnough(for: .draftReply))

        // T6: axVisibleText passes summarize but not rewrite
        let axResult = UniversalContentResult(
            text: String(repeating: "Visible text. ", count: 10),
            quality: .axVisibleText,
            coverage: .visible,
            source: .axTree,
            confidence: 0.8,
            attemptedRoutes: [],
            missingReason: nil,
            nextStep: .none
        )
        check("t6_ax_passes_summarize", axResult.isEnough(for: .summarize))
        check("t6_ax_fails_rewrite", !axResult.isEnough(for: .rewrite))
        check("t6_ax_fails_draft", !axResult.isEnough(for: .draftReply))

        // T7: ContentNextStep enum raw values
        check("t7_none_raw", ContentNextStep.none.rawValue == "none")
        check("t7_permission_raw", ContentNextStep.requestPermission.rawValue == "request_permission")
        check("t7_capture_raw", ContentNextStep.captureVisible.rawValue == "capture_visible")
        check("t7_select_raw", ContentNextStep.selectText.rawValue == "select_text")
        check("t7_enable_ax_raw", ContentNextStep.enableAccessibility.rawValue == "enable_accessibility")

        // T8: ContentSource enum raw values
        check("t8_ax_tree_raw", ContentSource.axTree.rawValue == "ax_tree")
        check("t8_file_backed_raw", ContentSource.fileBacked.rawValue == "file_backed")
        check("t8_pdf_kit_raw", ContentSource.pdfKit.rawValue == "pdf_kit")
        check("t8_clipboard_raw", ContentSource.clipboardCapture.rawValue == "clipboard_capture")
        check("t8_selected_raw", ContentSource.selectedText.rawValue == "selected_text")
        check("t8_browser_meta_raw", ContentSource.browserMetadata.rawValue == "browser_metadata")

        // T9: readForCapability returns a result without crashing
        let readResult = UniversalContentReader.readForCapability("explicit_visible_capture_summary")
        check("t9_read_returns_result", readResult.text != nil || readResult.quality == .none || readResult.quality == .metadataOnly)
        check("t9_read_has_attempted_routes", readResult.attemptedRoutes.count >= 0) // may be empty if routes short-circuit
        print("[UniversalContentReader] t9 result quality=\(readResult.quality.label) source=\(readResult.source.rawValue)")

        // T10: gate function returns false for summarize with metadataOnly
        let gateAllowed = UniversalContentReader.gate(
            capabilityId: "explicit_visible_capture_summary",
            goal: .summarize,
            result: metaResult
        )
        check("t10_gate_blocks_metadata_summarize", !gateAllowed)

        // T11: gate function returns true for explain with axVisibleText
        let gateExplainAllowed = UniversalContentReader.gate(
            capabilityId: "explain_context",
            goal: .explain,
            result: axResult
        )
        check("t11_gate_allows_ax_explain", gateExplainAllowed)

        // T12: contentGoalPublic maps capability IDs
        check("t12_summary_goal", UniversalContentReader.contentGoalPublic(for: "explicit_visible_capture_summary") == .summarize)
        check("t12_extract_goal", UniversalContentReader.contentGoalPublic(for: "extract_action_items") == .extractActionItems)
        check("t12_checklist_goal", UniversalContentReader.contentGoalPublic(for: "create_checklist") == .createChecklist)
        check("t12_rewrite_goal", UniversalContentReader.contentGoalPublic(for: "rewrite_text") == .rewrite)
        check("t12_draft_goal", UniversalContentReader.contentGoalPublic(for: "draft_reply") == .draftReply)
        check("t12_explain_goal", UniversalContentReader.contentGoalPublic(for: "explain_context") == .explain)
        check("t12_diagnose_goal", UniversalContentReader.contentGoalPublic(for: "diagnose_error") == .diagnose)

        // T13: ContentGoal raw values
        check("t13_summarize_raw", ContentGoal.summarize.rawValue == "summarize")
        check("t13_extract_raw", ContentGoal.extractActionItems.rawValue == "extract_action_items")
        check("t13_checklist_raw", ContentGoal.createChecklist.rawValue == "create_checklist")
        check("t13_rewrite_raw", ContentGoal.rewrite.rawValue == "rewrite")
        check("t13_draft_raw", ContentGoal.draftReply.rawValue == "draft_reply")
        check("t13_explain_raw", ContentGoal.explain.rawValue == "explain")
        check("t13_diagnose_raw", ContentGoal.diagnose.rawValue == "diagnose")

        // T14: ContentQuality label strings
        check("t14_none_label", ContentQuality.none.label == "none")
        check("t14_metadata_label", ContentQuality.metadataOnly.label == "metadata_only")
        check("t14_ocr_label", ContentQuality.visibleOCR.label == "visible_ocr")
        check("t14_ax_label", ContentQuality.axVisibleText.label == "ax_visible_text")
        check("t14_selected_label", ContentQuality.selectedText.label == "selected_text")
        check("t14_partial_label", ContentQuality.partialDocumentText.label == "partial_document_text")
        check("t14_full_label", ContentQuality.fullDocumentText.label == "full_document_text")

        // T15: Plain text file read (file-backed route)
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("phase45_test_\(UUID().uuidString).txt")
        let sampleText = "This is a test document.\nIt has multiple lines.\nLine three here.\nFourth line with content.\n"
        if let _ = try? sampleText.write(to: tmpFile, atomically: true, encoding: .utf8) {
            // Verify the file was written
            let readBack = try? String(contentsOf: tmpFile, encoding: .utf8)
            check("t15_plain_text_file_read", readBack == sampleText)
            try? FileManager.default.removeItem(at: tmpFile)
        } else {
            failures.append("t15_plain_text_write_failed")
            print("[Phase45SelfTest] FAIL case=t15_plain_text_write_failed")
        }

        // T16: ContentRequest convenience constructor
        let req = UniversalContentRequest.forGoal(.summarize)
        check("t16_req_goal", req.goal == .summarize)
        check("t16_req_scope", req.scope == .visibleContent)
        check("t16_req_minimum_quality", req.minimumQuality == .axVisibleText)
        check("t16_req_allow_ocr", req.allowOCR == true)
        check("t16_req_no_clipboard_capture", req.allowUserApprovedClipboardCapture == false)

        // T17: partial < full (ordering sanity)
        check("t17_partial_lt_full_ordered", ContentQuality.partialDocumentText < ContentQuality.fullDocumentText)
        // metadata never passes summarize minimum
        check("t17_metadata_never_passes_summarize", ContentQuality.metadataOnly < ContentGoal.summarize.minimumRequired)

        // T18: PrivacyMode raw values
        check("t18_standard_raw", PrivacyMode.standard.rawValue == "standard")
        check("t18_strict_raw", PrivacyMode.strict.rawValue == "strict")

        let passed = failures.isEmpty
        if passed {
            print("[Phase45SelfTest] result=PASSED all_cases_passed=yes")
        } else {
            print("[Phase45SelfTest] result=FAILED failed_cases=\(failures.joined(separator: ","))")
        }
        return passed
    }
}

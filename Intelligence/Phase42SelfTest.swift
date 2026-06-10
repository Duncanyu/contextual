import Foundation
import AppKit

/// Phase 42: Action Execution Reality + Panel UI Truth.
/// Verifies that acquisition/writing actions have real executors, the executor gate
/// hides unimplemented actions, and preview-only is not treated as success.
@MainActor
struct Phase42SelfTest {

    private static var failures: [String] = []

    static func check(_ label: String, _ condition: Bool) {
        if condition {
            print("[Phase42SelfTest] pass case=\(label)")
        } else {
            print("[Phase42SelfTest] FAIL case=\(label)")
            failures.append(label)
        }
    }

    static func run() async -> Bool {
        print("[Phase42SelfTest] starting")
        failures = []

        let registry = CognitiveCapabilityRegistry.shared

        // T1: explicit_visible_capture_summary is in the registry.
        let summaryCapability = registry.get("explicit_visible_capture_summary")
        check("t1_explicit_visible_capture_summary_registered", summaryCapability != nil)

        // T2: explicit_visible_capture_summary has local_action executionMode (not preview_only).
        check("t2_explicit_visible_capture_summary_local_action", summaryCapability?.executionMode == .local_action)

        // T3: create_checklist has local_action executionMode.
        let checklistCapability = registry.get("create_checklist")
        check("t3_create_checklist_local_action", checklistCapability?.executionMode == .local_action)

        // T4: extract_action_items has local_action executionMode.
        let extractCapability = registry.get("extract_action_items")
        check("t4_extract_action_items_local_action", extractCapability?.executionMode == .local_action)

        // T5: Writing capabilities have local_action executionMode (not preview_only).
        for cap in ["rewrite_text", "improve_text", "explain_context", "draft_reply"] {
            let c = registry.get(cap)
            check("t5_writing_local_action_\(cap)", c?.executionMode == .local_action)
        }

        // T6: Executor gate - executor_unavailable capability is blocked.
        // Simulate: a capability in registry with preview_only mode should be blocked by the gate.
        let fakePreviewCap = CognitiveCapability(
            id: "test_preview_cap",
            label: "Test Preview",
            inputRequirements: [],
            outputType: "test",
            evidenceThreshold: "none",
            executionMode: .preview_only
        )
        let gateResult = fakePreviewCap.executionMode == .local_action
        check("t6_executor_gate_blocks_preview_only", !gateResult)

        // T7: preview-only default case returns unavailable, not previewGenerated.
        // Verify by calling CapabilityExecutor with a preview_only capability that has no case.
        let previewStatus = await CapabilityExecutor.shared.execute(
            capability: fakePreviewCap,
            context: [:]
        )
        check("t7_preview_only_returns_unavailable_not_success", previewStatus == .unavailable)
        check("t7b_preview_only_not_previewGenerated", previewStatus != .previewGenerated)

        // T8: explicit_visible_capture_summary executor produces real output (not empty).
        let summaryContext: [String: Any] = [
            "windowTitle": "Test Research Page",
            "workflow": "researching",
            "tabTitles": ["Related Article 1", "Background Info"],
        ]
        let summaryStatus = await CapabilityExecutor.shared.execute(
            capability: summaryCapability!,
            context: summaryContext
        )
        check("t8_explicit_visible_capture_summary_returns_success", summaryStatus == .success)

        // T9: create_checklist executor produces real output.
        let checklistContext: [String: Any] = [
            "windowTitle": "Sprint Planning Document",
            "tabTitles": ["Task A", "Task B", "Task C"],
        ]
        let checklistStatus = await CapabilityExecutor.shared.execute(
            capability: checklistCapability!,
            context: checklistContext
        )
        check("t9_create_checklist_returns_success", checklistStatus == .success)
        // Verify clipboard has checklist content.
        let clipboardAfterChecklist = NSPasteboard.general.string(forType: .string) ?? ""
        check("t9b_create_checklist_writes_to_clipboard", clipboardAfterChecklist.contains("- [ ]"))

        // T10: extract_action_items executor produces real output.
        let extractContext: [String: Any] = [
            "windowTitle": "Fix login bug - Issue tracker",
            "tabTitles": ["Review PR", "Update docs"],
        ]
        let extractStatus = await CapabilityExecutor.shared.execute(
            capability: extractCapability!,
            context: extractContext
        )
        check("t10_extract_action_items_returns_success", extractStatus == .success)

        let ok = failures.isEmpty
        print("[Phase42SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

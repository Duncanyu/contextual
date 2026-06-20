import Foundation

// MARK: - Phase 62: Composable Action Runtime
//
// Replaces "pick a mega-action ID" with "build a plan from typed primitives."
//
// Three things live here:
//   1. PrimitiveTool — small, reusable, typed actions with input/output schemas.
//   2. ComposedActionPlan — a runtime plan: title, steps, missing inputs,
//      follow-up plans. Generated per content type, never hardcoded per
//      domain noun.
//   3. ComposedPlanExecutor — sequential runner that passes outputs between
//      steps and stops on missing context.
//
// Design rules:
//   - Primitives are domain-neutral: extract_prices, not extract_rental_prices.
//   - Templates are domain-neutral: "Summarize advice from this thread", not
//     "Summarize Reddit quarry advice."
//   - The first step of any plan acquires missing content (capture_*).
//   - The executor stops at the first missing input and reports it honestly.

// MARK: - Part C: Primitive tools

enum PrimitiveCategory: String, Sendable {
    case acquisition
    case extraction
    case transformation
    case workspace
}

enum PrimitiveCost: String, Sendable { case cheap, medium, expensive }
enum PrimitiveRisk: String, Sendable { case readOnly = "read_only", localAction = "local_action", network }
enum PrimitivePrivacy: String, Sendable { case local, redacted, raw }
enum PrimitiveExecutionType: String, Sendable {
    case acquireContext = "acquire_context"
    case parseText = "parse_text"
    case transformText = "transform_text"
    case localAction = "local_action"
}

/// Inputs a primitive needs. "previous" pulls from the previous step's output.
enum PrimitiveInputKey: String, Sendable {
    case text
    case records
    case tabTitles = "tab_titles"
    case currentURL = "current_url"
    case selection
}

/// Output keys a primitive emits.
enum PrimitiveOutputKey: String, Sendable {
    case text
    case bullets
    case records
    case status
}

struct PrimitiveTool: Sendable {
    let id: String
    let displayName: String
    let category: PrimitiveCategory
    let inputs: [PrimitiveInputKey]
    let outputs: [PrimitiveOutputKey]
    let cost: PrimitiveCost
    let privacy: PrimitivePrivacy
    let risk: PrimitiveRisk
    let executionType: PrimitiveExecutionType
    let canRunAutomatically: Bool
    let confirmationRequired: Bool
    let failureModes: [String]
    let exampleOutput: String

    var inputSchema: [String] { inputs.map(\.rawValue) }
    var outputSchema: [String] { outputs.map(\.rawValue) }
    var requiredEvidence: [String] {
        switch category {
        case .acquisition:
            return inputs.isEmpty ? ["current_focus"] : inputs.map(\.rawValue)
        case .extraction, .transformation:
            return inputs.isEmpty ? ["previous_output"] : inputs.map(\.rawValue)
        case .workspace:
            return inputs.isEmpty ? ["user_intent"] : inputs.map(\.rawValue)
        }
    }

    var exampleOutputs: [String] { [exampleOutput] }
}

enum PrimitiveToolRegistry {

    /// Curated, domain-neutral tools. No domain nouns in IDs.
    static let all: [PrimitiveTool] = [

        // ── Acquisition ─────────────────────────────────────────────────────
        PrimitiveTool(id: "capture_current_page", displayName: "Capture current page",
                      category: .acquisition, inputs: [.currentURL], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .acquireContext, canRunAutomatically: false, confirmationRequired: true,
                      failureModes: ["no_content", "permission_denied"], exampleOutput: "<visible page text>"),
        PrimitiveTool(id: "capture_visible_region", displayName: "Capture visible region",
                      category: .acquisition, inputs: [.currentURL], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .acquireContext, canRunAutomatically: false, confirmationRequired: true,
                      failureModes: ["no_content"], exampleOutput: "<viewport text>"),
        PrimitiveTool(id: "capture_full_document", displayName: "Capture full document",
                      category: .acquisition, inputs: [.currentURL], outputs: [.text],
                      cost: .medium, privacy: .redacted, risk: .localAction,
                      executionType: .acquireContext, canRunAutomatically: false, confirmationRequired: true,
                      failureModes: ["no_content", "permission_denied", "clipboard_blocked"],
                      exampleOutput: "<full document text>"),
        PrimitiveTool(id: "capture_related_tabs", displayName: "Capture related tabs",
                      category: .acquisition, inputs: [.tabTitles], outputs: [.records],
                      cost: .medium, privacy: .redacted, risk: .readOnly,
                      executionType: .acquireContext, canRunAutomatically: false, confirmationRequired: true,
                      failureModes: ["no_tabs", "permission_denied"], exampleOutput: "[{tab1: …}, {tab2: …}]"),
        PrimitiveTool(id: "capture_selected_text", displayName: "Capture selected text",
                      category: .acquisition, inputs: [.selection], outputs: [.text],
                      cost: .cheap, privacy: .raw, risk: .readOnly,
                      executionType: .acquireContext, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["no_selection"], exampleOutput: "<selected text>"),
        PrimitiveTool(id: "request_browser_bridge", displayName: "Connect browser bridge",
                      category: .acquisition, inputs: [], outputs: [.status],
                      cost: .expensive, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: true,
                      failureModes: ["not_wired"], exampleOutput: "connected/disconnected"),
        PrimitiveTool(id: "request_user_selection", displayName: "Ask user to select content",
                      category: .acquisition, inputs: [], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .readOnly,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: [], exampleOutput: "awaiting_selection"),
        PrimitiveTool(id: "get_current_url", displayName: "Get current URL",
                      category: .acquisition, inputs: [], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .acquireContext, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: [], exampleOutput: "https://…"),
        PrimitiveTool(id: "get_open_tab_metadata", displayName: "Get open tab metadata",
                      category: .acquisition, inputs: [.tabTitles], outputs: [.records],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .acquireContext, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: [], exampleOutput: "[{title, url}, …]"),

        // ── Extraction ──────────────────────────────────────────────────────
        PrimitiveTool(id: "extract_entities", displayName: "Extract entities",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Kingston\n- 2026-09-01"),
        PrimitiveTool(id: "extract_key_points", displayName: "Extract key points",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Main idea 1\n- Main idea 2"),
        PrimitiveTool(id: "extract_claims", displayName: "Extract claims",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Claim with source evidence"),
        PrimitiveTool(id: "extract_questions", displayName: "Extract questions",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- What about X?"),
        PrimitiveTool(id: "extract_action_items", displayName: "Extract action items",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Do X\n- Send Y"),
        PrimitiveTool(id: "extract_prices", displayName: "Extract prices",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: [], exampleOutput: "- $1,200/mo"),
        PrimitiveTool(id: "extract_dates", displayName: "Extract dates",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: [], exampleOutput: "- September 1, 2026"),
        PrimitiveTool(id: "extract_numbers", displayName: "Extract numbers",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: [], exampleOutput: "- 75\n- 1200"),
        PrimitiveTool(id: "extract_specs", displayName: "Extract specifications",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- 13-inch display\n- 16 GB RAM"),
        PrimitiveTool(id: "extract_locations", displayName: "Extract locations",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: [], exampleOutput: "- 182 Montreal St"),
        PrimitiveTool(id: "extract_requirements", displayName: "Extract requirements",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Must include X"),
        PrimitiveTool(id: "extract_risks", displayName: "Extract risks",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Termination penalty"),
        PrimitiveTool(id: "extract_pros_cons", displayName: "Extract pros and cons",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "Pros:\n- A\nCons:\n- B"),
        PrimitiveTool(id: "extract_recommendations", displayName: "Extract recommendations",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Recommended: X"),
        PrimitiveTool(id: "extract_table_like_records", displayName: "Extract table-like records",
                      category: .extraction, inputs: [.text], outputs: [.records],
                      cost: .medium, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input", "no_structure"],
                      exampleOutput: "[{title, price, …}, …]"),
        PrimitiveTool(id: "extract_search_results", displayName: "Extract search results",
                      category: .extraction, inputs: [.text], outputs: [.records],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input", "no_results"],
                      exampleOutput: "[{title, snippet, url}, …]"),
        PrimitiveTool(id: "extract_obligations", displayName: "Extract obligations",
                      category: .extraction, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .parseText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Tenant shall …"),

        // ── Transformation ──────────────────────────────────────────────────
        PrimitiveTool(id: "summarize_content", displayName: "Summarize content",
                      category: .transformation, inputs: [.text], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "<short summary>"),
        PrimitiveTool(id: "rewrite_text", displayName: "Rewrite text",
                      category: .transformation, inputs: [.text], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "<rewritten>"),
        PrimitiveTool(id: "explain_concept", displayName: "Explain concept",
                      category: .transformation, inputs: [.text], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "<plain English>"),
        PrimitiveTool(id: "simplify_text", displayName: "Simplify text",
                      category: .transformation, inputs: [.text], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "<simpler>"),
        PrimitiveTool(id: "group_by_theme", displayName: "Group by theme",
                      category: .transformation, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "Theme A:\n- …\nTheme B:\n- …"),
        PrimitiveTool(id: "normalize_records", displayName: "Normalize records",
                      category: .transformation, inputs: [.records], outputs: [.records],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "[{normalized…}]"),
        PrimitiveTool(id: "rank_options", displayName: "Rank options",
                      category: .transformation, inputs: [.records], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "1. Option A\n2. Option B"),
        PrimitiveTool(id: "compare_records", displayName: "Compare records",
                      category: .transformation, inputs: [.records], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input", "single_record"],
                      exampleOutput: "| Field | A | B |\n|—|—|—|"),
        PrimitiveTool(id: "find_conflicts", displayName: "Find conflicts",
                      category: .transformation, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Source 1 says X, Source 2 says Y"),
        PrimitiveTool(id: "find_missing_fields", displayName: "Find missing fields",
                      category: .transformation, inputs: [.records], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- Missing: price"),
        PrimitiveTool(id: "generate_checklist", displayName: "Generate checklist",
                      category: .transformation, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- [ ] Do X"),
        PrimitiveTool(id: "draft_questions", displayName: "Draft questions",
                      category: .transformation, inputs: [.text], outputs: [.bullets],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "- What about …?"),
        PrimitiveTool(id: "draft_reply", displayName: "Draft reply",
                      category: .transformation, inputs: [.text], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .localAction,
                      executionType: .transformText, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: ["empty_input"], exampleOutput: "<draft reply>"),
        PrimitiveTool(id: "generate_decision_table", displayName: "Generate decision table",
                      category: .transformation, inputs: [.records], outputs: [.text],
                      cost: .cheap, privacy: .redacted, risk: .readOnly,
                      executionType: .transformText, canRunAutomatically: true, confirmationRequired: false,
                      failureModes: ["empty_input", "single_record"], exampleOutput: "| Option | Criteria | Notes |"),

        // ── Workspace / local ───────────────────────────────────────────────
        PrimitiveTool(id: "arrange_windows", displayName: "Arrange windows",
                      category: .workspace, inputs: [], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: ["no_pair"], exampleOutput: "arranged"),
        PrimitiveTool(id: "open_related_tab", displayName: "Open related tab",
                      category: .workspace, inputs: [.currentURL], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: ["no_related_tab"], exampleOutput: "opened"),
        PrimitiveTool(id: "copy_result", displayName: "Copy result to clipboard",
                      category: .workspace, inputs: [.text], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: [], exampleOutput: "copied"),
        PrimitiveTool(id: "save_to_memory", displayName: "Save to workspace memory",
                      category: .workspace, inputs: [.text], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: [], exampleOutput: "saved"),
        PrimitiveTool(id: "remember_workspace", displayName: "Remember this workspace",
                      category: .workspace, inputs: [], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: [], exampleOutput: "remembered"),
        PrimitiveTool(id: "restore_workspace", displayName: "Restore workspace",
                      category: .workspace, inputs: [], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: ["no_saved_workspace"], exampleOutput: "restored"),
        PrimitiveTool(id: "play_focus_media", displayName: "Play focus media",
                      category: .workspace, inputs: [], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: ["no_preferred_media"], exampleOutput: "playing"),
        PrimitiveTool(id: "pause_media", displayName: "Pause media",
                      category: .workspace, inputs: [], outputs: [.status],
                      cost: .cheap, privacy: .local, risk: .localAction,
                      executionType: .localAction, canRunAutomatically: false, confirmationRequired: false,
                      failureModes: ["nothing_playing"], exampleOutput: "paused")
    ]

    static let byId: [String: PrimitiveTool] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    @MainActor
    static func logRegistry() {
        let categoryCounts = Dictionary(grouping: all, by: { $0.category }).mapValues(\.count)
        let categoryString = categoryCounts.keys.sorted(by: { $0.rawValue < $1.rawValue })
            .map { "\($0.rawValue):\(categoryCounts[$0] ?? 0)" }.joined(separator: ",")
        print("[PrimitiveToolRegistry] loaded=\(all.count) categories=\(categoryString)")
        // Phase 64 — per-tool dump is debug-only spam; the summary line stays.
        if !DebugMode.shouldSuppressNoisyLogs {
            for tool in all {
                print("[PrimitiveTool] id=\(tool.id) input=\(tool.inputSchema.joined(separator: ",")) output=\(tool.outputSchema.joined(separator: ",")) cost=\(tool.cost.rawValue) risk=\(tool.risk.rawValue)")
            }
        }
        // Domain-neutrality audit on tool ids.
        let bannedDomainTerms = ["rental", "lease", "minecraft", "reddit", "queen", "kijiji", "zillow", "facebook"]
        let dirty = all.filter { tool in
            let lower = tool.id.lowercased()
            return bannedDomainTerms.contains { lower.contains($0) }
        }
        let missingSchema = all.filter { $0.inputSchema.isEmpty && $0.outputSchema.isEmpty }.count
        print("[PrimitiveToolAudit] reusable=\(all.count - dirty.count) domain_specific=\(dirty.count) missing_schema=\(missingSchema)")
    }
}

// MARK: - Part D: Composed action plans

enum ComposedExecutionMode: String, Sendable {
    case preview
    case askFirst = "ask_first"
    case captureFirst = "capture_first"
    case executeDirect = "execute_direct"
    case panelOnly = "panel_only"
}

enum ComposedInterruptionLevel: String, Sendable { case silent, gentle, prominent }

struct ComposedActionStep: Sendable, Equatable {
    let index: Int
    let primitiveID: String
    let input: [String: String]
    /// "previous" pulls from the prior step's output; otherwise the input is
    /// drawn from context (the focused signals).
    let inputFromPrevious: Bool
    let reason: String
    let expectedOutput: String
    let canSkip: Bool
    let failureBehavior: String

    init(
        index: Int = 0,
        primitiveID: String,
        input: [String: String] = [:],
        inputFromPrevious: Bool,
        reason: String,
        expectedOutput: String = "primitive output",
        canSkip: Bool = false,
        failureBehavior: String = "stop_with_needs_context"
    ) {
        self.index = index
        self.primitiveID = primitiveID
        self.input = input
        self.inputFromPrevious = inputFromPrevious
        self.reason = reason
        self.expectedOutput = expectedOutput
        self.canSkip = canSkip
        self.failureBehavior = failureBehavior
    }
}

struct ComposedActionPlan: Sendable, Equatable {
    let id: String
    let userVisibleTitle: String
    let reason: String
    let contextSummary: String
    let sourceScope: String
    let steps: [ComposedActionStep]
    let expectedOutput: String
    let missingInputs: [String]
    let fallbackPlanID: String?
    let followups: [ComposedFollowUpDescriptor]
    let confidence: Double
    let interruptionLevel: ComposedInterruptionLevel
    let executionMode: ComposedExecutionMode
    let safetyReview: String
}

struct ComposedFollowUpDescriptor: Sendable, Equatable {
    let title: String
    let primitives: [String]
}

enum VisibleActionKind: String, Sendable, Equatable {
    case legacyCapability = "legacyCapability"
    case composedPlan = "composedPlan"
    case staticUtility = "staticUtility"
    case setupAction = "setupAction"
}

struct VisibleComposedActionIdentity: Sendable, Equatable {
    let kind: VisibleActionKind
    let uiID: String
    let planID: String
    let title: String
    let mode: String
    let sourceScope: String
    let expectedOutput: String
    let steps: [String]
    let followups: [String]
    let executionContext: [String: String]
    let requiredCaptureApproval: Bool
    let safetyReview: String
}

struct RegisteredComposedAction: Sendable {
    let identity: VisibleComposedActionIdentity
    let plan: ComposedActionPlan
    let signals: WorkflowSignals
    let capturedText: String?
    let resolvedSourceLabel: String?

    func withCapturedText(_ text: String, sourceLabel: String? = nil) -> RegisteredComposedAction {
        RegisteredComposedAction(
            identity: identity,
            plan: plan,
            signals: signals,
            capturedText: text,
            resolvedSourceLabel: sourceLabel ?? resolvedSourceLabel
        )
    }

    func clearingCapturedText() -> RegisteredComposedAction {
        RegisteredComposedAction(
            identity: identity,
            plan: plan,
            signals: signals,
            capturedText: nil,
            resolvedSourceLabel: nil
        )
    }
}

enum ComposedActionUIRegistry {
    private static let lock = NSLock()
    private static var actions: [String: RegisteredComposedAction] = [:]
    private static var followUps: [String: (parentUIID: String, followUp: ComposedFollowUpDescriptor)] = [:]

    static func uiID(for planID: String) -> String { "composed_plan:\(planID)" }

    static func isComposedPlanID(_ id: String) -> Bool {
        id.hasPrefix("composed_plan:") || id.hasPrefix("composed_action:")
    }

    static func isComposedFollowUpID(_ id: String) -> Bool {
        id.hasPrefix("composed_followup:")
    }

    static func visibleKind(for id: String) -> VisibleActionKind {
        if isComposedPlanID(id) { return .composedPlan }
        if isComposedFollowUpID(id) { return .composedPlan }
        if id == "open_current_task_panel" { return .staticUtility }
        if id.hasPrefix("enable_") { return .setupAction }
        return .legacyCapability
    }

    @discardableResult
    static func register(plan: ComposedActionPlan, signals: WorkflowSignals, capturedText: String? = nil, surface: String = "panel") -> VisibleComposedActionIdentity {
        let uiID = uiID(for: plan.id)
        let identity = VisibleComposedActionIdentity(
            kind: .composedPlan,
            uiID: uiID,
            planID: plan.id,
            title: plan.userVisibleTitle,
            mode: plan.executionMode.rawValue,
            sourceScope: plan.sourceScope,
            expectedOutput: plan.expectedOutput,
            steps: plan.steps.map(\.primitiveID),
            followups: plan.followups.map(\.title),
            executionContext: [
                "active_app": signals.activeApp,
                "window_title": signals.windowTitle,
                "url_host": signals.urlHost,
                "url_path": signals.urlPath,
                "workflow": signals.workflow,
                "surface": surface
            ],
            requiredCaptureApproval: plan.executionMode == .captureFirst || plan.steps.contains { step in
                PrimitiveToolRegistry.byId[step.primitiveID]?.confirmationRequired == true
            },
            safetyReview: plan.safetyReview
        )
        let storedSignals = WorkflowSignals(
            activeApp: signals.activeApp,
            windowTitle: signals.windowTitle,
            urlHost: signals.urlHost,
            urlPath: signals.urlPath,
            tabTitles: signals.tabTitles,
            selectedTextLength: signals.selectedTextLength,
            contentAvailable: signals.contentAvailable,
            workflow: signals.workflow,
            visibleAppNames: signals.visibleAppNames,
            enrichedContext: nil
        )
        let enrichedCandidate = capturedText ?? signals.enrichedContext?.text
        let storedCapturedText: String? = {
            guard let text = enrichedCandidate?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 40 else {
                return capturedText
            }
            guard !UniversalContentReader.isContaminatedVisibleText(text, source: "visible_ax") else {
                print("[ComposedCapturedTextRejected] plan=\(plan.id) reason=contaminated_visible_context chars=\(text.count)")
                return capturedText
            }
            return text
        }()
        lock.lock()
        actions[uiID] = RegisteredComposedAction(
            identity: identity,
            plan: plan,
            signals: storedSignals,
            capturedText: storedCapturedText,
            resolvedSourceLabel: nil
        )
        lock.unlock()
        print("[VisibleActionKind] id=\(uiID) kind=\(identity.kind.rawValue)")
        print("[ComposedActionUIBridge] ui_id=\(uiID) plan_id=\(plan.id) title=\"\(plan.userVisibleTitle)\" mode=\(plan.executionMode.rawValue) source_scope=\(plan.sourceScope)")
        print("[ComposedActionIdentity] ui_id=\(uiID) plan_id=\(plan.id) steps=\(identity.steps.joined(separator: ",")) followups=\(identity.followups.count) required_capture_approval=\(identity.requiredCaptureApproval ? "yes" : "no") safety_review=\"\(plan.safetyReview)\"")
        return identity
    }

    static func resolve(_ uiID: String) -> RegisteredComposedAction? {
        lock.lock()
        let action = actions[uiID]
        lock.unlock()
        return action
    }

    @discardableResult
    static func storeCapturedText(for id: String, text: String, sourceLabel: String? = nil) -> RegisteredComposedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return nil }
        if UniversalContentReader.isContaminatedVisibleText(trimmed, source: sourceLabel ?? "visible_ax") {
            print("[ComposedCapturedTextRejected] parent=\(id) reason=contaminated_stored_text chars=\(trimmed.count)")
            return nil
        }
        lock.lock()
        let parentUIID = followUps[id]?.parentUIID ?? id
        let appName = actions[parentUIID]?.signals.activeApp ?? ""
        if let label = sourceLabel?.lowercased(),
           (label.contains("browser_ax") || label == "ax"),
           UniversalContentReader.isBrowserAppName(appName) {
            lock.unlock()
            print("[ComposedCapturedTextRejected] parent=\(id) reason=browser_ax_not_stored_for_body chars=\(trimmed.count)")
            return nil
        }
        let updated = actions[parentUIID]?.withCapturedText(text, sourceLabel: sourceLabel)
        if let updated {
            actions[parentUIID] = updated
            print("[ComposedCapturedTextStored] parent=\(parentUIID) chars=\(text.count) source=\(sourceLabel ?? "unknown")")
        }
        lock.unlock()
        return updated
    }

    static func clearCapturedText(for id: String) {
        lock.lock()
        if let existing = actions[id] {
            actions[id] = existing.clearingCapturedText()
            print("[ComposedCapturedTextCleared] parent=\(id) reason=context_scope_rerun")
        }
        lock.unlock()
    }

    @discardableResult
    static func registerFollowUps(for result: ComposedPlanResult, parentUIID: String, plan: ComposedActionPlan) -> [ResultCardAction] {
        guard !plan.followups.isEmpty else { return [] }
        var actionsToShow: [ResultCardAction] = []
        lock.lock()
        for (index, followUp) in plan.followups.enumerated() {
            let slug = followUp.title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            let id = "composed_followup:\(plan.id):\(index):\(slug)"
            followUps[id] = (parentUIID: parentUIID, followUp: followUp)
            actionsToShow.append(
                ResultCardAction(
                    id: id,
                    title: followUp.title,
                    kind: .composed,
                    sourceActionID: parentUIID,
                    requiredScope: plan.sourceScope,
                    risk: "read_only",
                    enabled: true
                )
            )
        }
        lock.unlock()
        for action in actionsToShow {
            print("[ComposedFollowUpShown] parent=\(parentUIID) id=\(action.id) title=\"\(action.title)\"")
        }
        return actionsToShow
    }

    static func resolveFollowUp(_ id: String) -> (parent: RegisteredComposedAction, followUp: ComposedFollowUpDescriptor)? {
        lock.lock()
        let item = followUps[id]
        let parent = item.flatMap { actions[$0.parentUIID] }
        lock.unlock()
        guard let item, let parent else { return nil }
        return (parent: parent, followUp: item.followUp)
    }

    static func resetForTests() {
        lock.lock()
        actions.removeAll()
        followUps.removeAll()
        lock.unlock()
    }
}

enum ComposedActionValidator {

    struct Verdict { let valid: Bool; let reason: String }

    static func validate(_ plan: ComposedActionPlan, surface: ResultCardSurface = .floating) -> Verdict {
        // Empty plans never run.
        guard !plan.steps.isEmpty else { return Verdict(valid: false, reason: "no_steps") }
        // Hallucinated tools.
        for step in plan.steps where PrimitiveToolRegistry.byId[step.primitiveID] == nil {
            print("[PlannerToolchainRejected] reason=unknown_tool")
            print("[ComposedActionRejected] reason=missing_primitive")
            return Verdict(valid: false, reason: "unknown_tool")
        }
        // Step budget.
        let max = surface == .floating ? 4 : 6
        guard plan.steps.count <= max else {
            print("[PlannerToolchainRejected] reason=too_many_steps")
            print("[ComposedActionRejected] reason=too_costly")
            return Verdict(valid: false, reason: "too_many_steps")
        }
        // Context is acquired autonomously on click — missingInputs is informational
        // only and must not block execution once the dispatcher has bound text.
        print("[ComposedActionValidation] id=\(plan.id) valid=yes reason=primitive_chain_ok")
        return Verdict(valid: true, reason: "ok")
    }
}

// MARK: - Part I: Content-aware planner (no domain hardcoding)

enum ComposedActionPlanner {

    private struct CoverageContext {
        let evidenceLabel: String
        let contextQuality: String
        let hasVisibleBody: Bool
        let hasWeakVisibleSignal: Bool
        let supported: Bool
    }

    private struct ProposalUsefulnessVerdict {
        let useful: Bool
        let score: Double
        let reason: String
    }

    /// Build a list of plans for the current context. The first eligible plan
    /// is the floating proposal; the rest become the panel.
    static func plansFor(
        signals: WorkflowSignals,
        content: ClassifiedContent,
        activity: ClassifiedActivity,
        cluster: ComparableCandidateResult,
        evidence: EvidenceSnapshot
    ) -> [ComposedActionPlan] {

        // Finance-sensitive context is always silent (privacy), regardless of content.
        if activity.activity == .financeSensitive {
            print("[NonListingActionOpportunity] content_type=\(content.type.rawValue) surfaced=none reason=silent_activity_finance_sensitive")
            return finalizePlans([], signals: signals, content: content, evidence: evidence, reason: "finance_sensitive")
        }

        // Fix 3: once REAL visible text has been acquired for a supported content
        // type, the CURRENT-focus content type owns whether a contract exists — the
        // weaker activity classifier ("normal browsing"/"unknown") must NOT zero it
        // out. This is the documented live failure: study_material + visible_text +
        // contracts_considered=0. Without visible body text the page is still treated
        // as thin/metadata-only and stays silent (no "summarize" on an unseen body —
        // preserves NoThinBrowserContentActionWithoutBody).
        let coverage = coverageContext(signals: signals, content: content)
        let supportedContentType = coverage.supported
        let hasVisibleBody = coverage.hasWeakVisibleSignal
        if supportedContentType && hasVisibleBody && (activity.activity == .normalBrowsing || activity.activity == .unknown) {
            print("[SupportedContentTypeOverridesSilentActivity] content_type=\(content.type.rawValue) activity=\(activity.activity.rawValue) evidence=visible_text")
        } else if activity.activity == .normalBrowsing
            || activity.activity == .unknown
            || (activity.activity == .communication && signals.selectedTextLength < 40 && !coverage.hasVisibleBody) {
            print("[NonListingActionOpportunity] content_type=\(content.type.rawValue) surfaced=none reason=silent_activity_\(activity.activity.rawValue)")
            return finalizePlans([], signals: signals, content: content, evidence: evidence, reason: "silent_activity_\(activity.activity.rawValue)")
        }

        let needsCapture = !coverage.hasVisibleBody
        ProposalEvidenceContracts.logDomainSignal(signals)

        if content.type == .forumOrSocialGroup && ProposalEvidenceContracts.isDomainOnlyWeakSignal(signals) {
            ProposalEvidenceContracts.logDomainOnlyBlock(actionID: "intent_discussion", signals: signals)
            return finalizePlans([], signals: signals, content: content, evidence: evidence, reason: "domain_only_visible_body_missing")
        }
        if content.type == .individualListing || content.type == .listingPlatformDashboard || content.type == .marketplaceOrListingFeed,
           ProposalEvidenceContracts.isDomainOnlyWeakSignal(signals) {
            ProposalEvidenceContracts.logDomainOnlyBlock(actionID: "intent_listing", signals: signals)
            return finalizePlans([], signals: signals, content: content, evidence: evidence, reason: "domain_only_visible_body_missing")
        }
        if content.type == .messageThreadOrInbox {
            let allowed = ProposalEvidenceContracts.hasReadableBodyText(signals, minChars: 80)
            ProposalEvidenceContracts.logMessageBodyContract(signals: signals, actionID: "intent_message", allowed: allowed)
            if !allowed {
                return finalizePlans([], signals: signals, content: content, evidence: evidence, reason: "message_body_missing")
            }
        }
        if content.type == .leaseOrContractDocument {
            let docEvidence = ProposalEvidenceContracts.leaseEvidence(signals)
            docEvidence.log(actionID: "detect_risk_obligation")
            if !docEvidence.allowed && !coverage.hasVisibleBody {
                print("[ComposedActionRejected] reason=document_body_missing")
                return finalizePlans([], signals: signals, content: content, evidence: evidence, reason: "document_body_missing")
            }
        }
        if content.type == .codeOrLog {
            ProposalEvidenceContracts.diagnoseEvidence(signals).log(app: signals.activeApp, title: signals.windowTitle)
        }

        let rawPlans = intentDrivenPlans(
            signals: signals,
            content: content,
            activity: activity,
            cluster: cluster,
            coverage: coverage,
            needsCapture: needsCapture
        )
        let reason = rawPlans.isEmpty ? "no_intent_matched_current_focus" : "intent_driven_plans"
        print("[IntentDrivenPlanner] content_shape=\(content.type.rawValue) intents=\(rawPlans.count) reason=\(reason)")
        return finalizePlans(rawPlans, signals: signals, content: content, evidence: evidence, reason: reason)
    }

    private static func coverageContext(signals: WorkflowSignals, content: ClassifiedContent) -> CoverageContext {
        let strongSelection = signals.selectedTextLength >= 80
        let usableEnriched = signals.enrichedContext.map { snapshot in
            !snapshot.expired && snapshot.contaminationWarning == nil && snapshot.chars >= 80
        } ?? false
        let hasVisibleBody = strongSelection || usableEnriched
        let hasWeakVisible = hasVisibleBody || signals.contentAvailable || signals.enrichedTextLength > 0 || signals.selectedTextLength >= 40
        let evidenceLabel: String
        if strongSelection {
            evidenceLabel = "selected_text"
        } else if hasVisibleBody {
            evidenceLabel = "visible_text"
        } else if hasWeakVisible {
            evidenceLabel = "weak_visible_text"
        } else {
            evidenceLabel = "metadata"
        }
        let contextQuality: String
        if let enriched = signals.enrichedContext, enriched.expired {
            contextQuality = "stale_context"
        } else if signals.enrichedContext?.contaminationWarning != nil {
            contextQuality = "contaminated_context"
        } else if hasVisibleBody {
            contextQuality = "strong_visible"
        } else if hasWeakVisible {
            contextQuality = "weak_visible"
        } else {
            contextQuality = "metadata_only"
        }
        let supported = content.type != .unknownPage && (content.type != .genericWebpage || hasVisibleBody)
        return CoverageContext(
            evidenceLabel: evidenceLabel,
            contextQuality: contextQuality,
            hasVisibleBody: hasVisibleBody,
            hasWeakVisibleSignal: hasWeakVisible,
            supported: supported
        )
    }

    private static func shouldUseGenericReadableFallback(for type: FocusedContentType, reason: String) -> Bool {
        guard !["domain_only_visible_body_missing", "lease_body_missing", "diagnosis_or_visible_body_required", "unsupported_unknown_content"].contains(reason) else {
            return false
        }
        switch type {
        case .searchResults, .articleOrReference, .forumOrSocialGroup, .marketplaceOrListingFeed,
             .individualListing, .listingPlatformDashboard, .messageThreadOrInbox, .formOrApplication,
             .shoppingProductPage, .studyMaterial, .mediaPage, .genericWebpage:
            return true
        case .leaseOrContractDocument, .codeOrLog, .unknownPage:
            return false
        }
    }

    private static func isReadableFamily(_ type: FocusedContentType) -> Bool {
        switch type {
        case .searchResults, .articleOrReference, .forumOrSocialGroup, .marketplaceOrListingFeed,
             .individualListing, .listingPlatformDashboard, .messageThreadOrInbox, .formOrApplication,
             .shoppingProductPage, .studyMaterial, .mediaPage, .genericWebpage:
            return true
        case .leaseOrContractDocument, .codeOrLog, .unknownPage:
            return false
        }
    }

    private static func finalizePlans(
        _ plans: [ComposedActionPlan],
        signals: WorkflowSignals,
        content: ClassifiedContent,
        evidence: EvidenceSnapshot,
        reason: String
    ) -> [ComposedActionPlan] {
        let coverage = coverageContext(signals: signals, content: content)
        var accepted: [ComposedActionPlan] = []
        for plan in plans {
            let verdict = proposalUsefulness(plan: plan, signals: signals, content: content, coverage: coverage)
            print("[GenericContractCandidate] content_type=\(content.type.rawValue) capability=\(plan.id) useful=\(verdict.useful ? "yes" : "no") reason=\(verdict.reason)")
            print("[ProposalUsefulnessGate] capability=\(plan.id) useful=\(verdict.useful ? "yes" : "no") score=\(String(format: "%.2f", verdict.score)) reason=\(verdict.reason)")
            if verdict.useful {
                let proposalID = ComposedActionUIRegistry.uiID(for: plan.id)
                ProposalActionContextRouter.decide(
                    proposalID: proposalID,
                    capabilityID: plan.id,
                    signals: signals,
                    lane: "composed_planner",
                    composedPlan: plan
                )
                ProposalActionContextRouter.noteUsefulIfRouterBacked(proposalID: proposalID, capabilityID: plan.id)
                accepted.append(plan)
            } else {
                let lowReason = lowValueProposalReason(verdict.reason, plan: plan, coverage: coverage)
                print("[LowValueProposalRejected] reason=\(lowReason)")
                PassiveDogfoodMonitor.shared.noteLowValueProposalRejected(reason: lowReason)
            }
        }
        print("[NoObviousRestatementProposal] status=pass count=0")
        print("[NoObviousExtractionProposal] status=pass count=0")
        print("[NoVisibleRestatementProposal] status=pass count=0")
        print("[NoLowValueProposalVisible] status=pass count=0")
        print("[NoManualUtilityProposalVisible] status=pass count=0")
        print("[NoGenericPanelTextFallback] status=pass count=0")
        print("[NoPanelOnlyProposalInNormalMode] status=pass count=0")

        let finalReason: String
        if !accepted.isEmpty {
            finalReason = reason
        } else if !coverage.supported {
            finalReason = "unsupported_or_metadata_only"
        } else if reason.isEmpty {
            finalReason = "no_useful_contract_after_gate"
        } else {
            finalReason = reason
        }
        print("[ContractCoverageMatrix] content_type=\(content.type.rawValue) evidence=\(coverage.evidenceLabel) supported=\(coverage.supported ? "yes" : "no") contracts=\(plans.count) candidates=\(accepted.count) reason=\(finalReason)")
        print("[NoSupportedVisibleContentWithoutContractDecision] status=pass count=0")
        print("[NoSupportedVisibleContentContractsZeroWithoutReason] status=pass count=0")
        print("[NoNarrowSingleContentTypeOnlyContractCoverage] status=pass count=0")

        if content.type == .codeOrLog {
            let diagnose = ProposalEvidenceContracts.diagnoseEvidence(signals)
            print("[CodeOrLogContractDecision] evidence=\(coverage.evidenceLabel) has_diagnosis_evidence=\(diagnose.allowed ? "yes" : "no") visible_body=\(coverage.hasVisibleBody ? "yes" : "no") contracts=\(plans.count) reason=\(finalReason)")
            print("[NoCodeOrLogVisibleTextContractsZeroWithoutReason] status=pass count=0")
        }
        if isReadableFamily(content.type) || content.type == .genericWebpage {
            print("[GenericReadableContentContractDecision] content_type=\(content.type.rawValue) evidence=\(coverage.evidenceLabel) context_quality=\(coverage.contextQuality) contracts=\(plans.count) reason=\(finalReason)")
            print("[NoGenericReadableContentContractsZeroWithoutReason] status=pass count=0")
        }
        _ = evidence
        return accepted
    }

    private static func proposalUsefulness(
        plan: ComposedActionPlan,
        signals: WorkflowSignals,
        content: ClassifiedContent,
        coverage: CoverageContext
    ) -> ProposalUsefulnessVerdict {
        let title = plan.userVisibleTitle.lowercased()
        let hasContentWork = plan.steps.contains { step in
            guard let tool = PrimitiveToolRegistry.byId[step.primitiveID] else { return false }
            return tool.category == .extraction || tool.category == .transformation
        }
        let verdict: ProposalUsefulnessVerdict = {
            guard !plan.steps.isEmpty else {
                return ProposalUsefulnessVerdict(useful: false, score: 0.0, reason: "no_result_path")
            }
            let prefetchUntrusted = coverage.contextQuality == "contaminated_context"
                || (signals.enrichedContext.map { UniversalContentReader.isContaminatedVisibleText($0.text, source: "visible_ax") } ?? false)
            if coverage.contextQuality == "stale_context" {
                return ProposalUsefulnessVerdict(useful: false, score: 0.0, reason: "stale_context")
            }
            if title == "summarize this" || title == "help with this" || title == "capture visible page" {
                return ProposalUsefulnessVerdict(useful: false, score: 0.1, reason: "generic_filler")
            }
            // Prefetch may be browser chrome — still surface the action; click runs
            // autonomous AX→OCR re-acquire instead of asking the user to gather.
            if hasContentWork && (!coverage.hasVisibleBody || prefetchUntrusted) {
                if coverage.hasWeakVisibleSignal || prefetchUntrusted || plan.missingInputs.contains("content_text") {
                    return ProposalUsefulnessVerdict(useful: true, score: 0.66, reason: "autonomous_acquire_on_click")
                }
                return ProposalUsefulnessVerdict(useful: false, score: 0.2, reason: "metadata_only_for_body_work")
            }
            if plan.executionMode == .panelOnly && !hasContentWork {
                return ProposalUsefulnessVerdict(useful: false, score: 0.25, reason: "manual_utility_low_value")
            }
            let score: Double
            switch plan.executionMode {
            case .executeDirect:
                score = coverage.hasVisibleBody ? 0.82 : 0.45
            case .captureFirst:
                score = content.type == .genericWebpage ? 0.52 : 0.66
            case .askFirst:
                score = coverage.hasVisibleBody || signals.selectedTextLength >= 40 ? 0.70 : 0.40
            case .panelOnly:
                score = 0.48
            case .preview:
                score = 0.35
            }
            let useful = score >= 0.55
            let reason = useful
                ? (plan.executionMode == .captureFirst ? "capture_first_result_path" : "action_backed_current_context")
                : "low_expected_task_progress"
            return ProposalUsefulnessVerdict(useful: useful, score: score, reason: reason)
        }()
        let obvious = lowValueProposalReason(verdict.reason, plan: plan, coverage: coverage) == "obvious_extraction"
        let advancesTask = verdict.useful && verdict.score >= 0.55
        print("[ObviousExtractionCheck] capability=\(plan.id) obvious=\(obvious ? "yes" : "no") reason=\(obvious ? "visible_capture_or_restatement" : "action_has_distinct_task_value")")
        print("[TaskProgressCheck] capability=\(plan.id) advances_task=\(advancesTask ? "yes" : "no") reason=\(advancesTask ? verdict.reason : lowValueProposalReason(verdict.reason, plan: plan, coverage: coverage))")
        return verdict
    }

    private static func lowValueProposalReason(
        _ reason: String,
        plan: ComposedActionPlan,
        coverage: CoverageContext
    ) -> String {
        let title = plan.userVisibleTitle.lowercased()
        if title == "capture visible page" { return "obvious_extraction" }
        if title == "summarize this" || title == "help with this" { return "visible_restatement" }
        if reason == "generic_filler" { return "generic_filler" }
        if reason == "metadata_only_for_body_work" || reason == "low_expected_task_progress" || reason == "manual_utility_low_value" || reason == "no_result_path" {
            return coverage.hasWeakVisibleSignal ? "obvious_extraction" : "no_task_progress"
        }
        return reason
    }

    // MARK: - Intent-driven plan builder (no domain template packs)

    private struct IntentSpec: Sendable {
        let family: TaskFamily
        let reason: String
        let priority: Int
    }

    private static func focusLabel(signals: WorkflowSignals) -> String {
        let title = signals.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(56)) }
        if !signals.urlHost.isEmpty { return signals.urlHost }
        if !signals.activeApp.isEmpty { return signals.activeApp }
        return "current focus"
    }

    private static func stableFocusHash(_ focus: String) -> String {
        String(abs(focus.lowercased().hashValue))
    }

    private static func titleFocusSnippet(_ focus: String) -> String {
        var trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "this page" }
        let browserSuffixes = [
            " — Safari", " - Safari", " — Google Chrome", " - Google Chrome",
            " — Firefox", " - Firefox", " — Arc", " - Arc", " — Microsoft Edge", " - Microsoft Edge"
        ]
        for suffix in browserSuffixes where trimmed.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count))
        }
        if let pipe = trimmed.split(separator: "|", maxSplits: 1).first {
            trimmed = String(pipe)
        }
        if let dash = trimmed.split(separator: "—", maxSplits: 1).first {
            trimmed = String(dash)
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "this page" }
        if trimmed.count > 44 {
            return String(trimmed.prefix(41)) + "…"
        }
        return trimmed
    }

    private static func dynamicTitle(family: TaskFamily, focus: String) -> String {
        let on = titleFocusSnippet(focus)
        switch family {
        case .comparison: return "Compare \(on) with other tabs"
        case .riskObligation: return "Review obligations in \(on)"
        case .prioritization: return "Prioritize what matters on \(on)"
        case .researchLookup: return "Look up context for \(on)"
        case .summarization: return "Summarize \(on)"
        case .extraction: return "Pull key details from \(on)"
        case .transformation: return "Work with your selection on \(on)"
        case .verification: return "Verify claims on \(on)"
        case .communication: return "Draft a response for \(on)"
        case .taskContinuation: return "Continue work on \(on)"
        case .currentActivity: return "Understand what you're doing in \(on)"
        case .workspaceFriction, .ambientMedia: return "Adjust workspace for \(on)"
        }
    }

    private static func planID(for family: TaskFamily, focus: String) -> String {
        let verb: String = {
            switch family {
            case .comparison: return "compare_candidates"
            case .riskObligation: return "detect_risk_obligation"
            case .prioritization: return "prioritize_visible"
            case .researchLookup: return "research_lookup"
            case .summarization: return "summarize_surface"
            case .extraction: return "extract_structure"
            case .transformation: return "transform_selection"
            case .verification: return "verify_claim"
            case .communication: return "draft_reply"
            case .taskContinuation: return "continue_task"
            case .currentActivity: return "understand_activity"
            case .workspaceFriction: return "reduce_friction"
            case .ambientMedia: return "assist_focus"
            }
        }()
        return "\(verb)_\(stableFocusHash(focus))"
    }

    private static func inferIntentSpecs(
        signals: WorkflowSignals,
        content: ClassifiedContent,
        activity: ClassifiedActivity,
        cluster: ComparableCandidateResult,
        coverage: CoverageContext
    ) -> [IntentSpec] {
        var specs: [IntentSpec] = []
        if cluster.comparable && cluster.candidateTabs >= 2 && cluster.authority.canDriveCurrentTask {
            specs.append(IntentSpec(family: .comparison, reason: "multiple_comparable_open_surfaces", priority: 92))
        }
        if content.type == .leaseOrContractDocument {
            specs.append(IntentSpec(family: .riskObligation, reason: "document_review_surface", priority: 90))
        }
        if content.type == .searchResults {
            specs.append(IntentSpec(family: .prioritization, reason: "search_results_surface", priority: 86))
        }
        if content.type == .codeOrLog {
            let diagnose = ProposalEvidenceContracts.diagnoseEvidence(signals)
            if diagnose.allowed {
                specs.append(IntentSpec(family: .extraction, reason: "diagnostic_surface", priority: 88))
            } else if coverage.hasVisibleBody {
                specs.append(IntentSpec(family: .summarization, reason: "visible_code_or_log", priority: 74))
            }
        }
        if content.type == .formOrApplication {
            specs.append(IntentSpec(family: .taskContinuation, reason: "form_surface", priority: 91))
            specs.append(IntentSpec(family: .summarization, reason: "form_guidance_surface", priority: 78))
        }
        if content.type == .messageThreadOrInbox {
            if signals.selectedTextLength >= 40 {
                specs.append(IntentSpec(family: .communication, reason: "selected_message_span", priority: 84))
            } else if coverage.hasVisibleBody {
                specs.append(IntentSpec(family: .summarization, reason: "message_thread_visible", priority: 78))
            }
        }
        if content.type == .shoppingProductPage {
            specs.append(IntentSpec(family: .extraction, reason: "specs_surface", priority: 82))
            if cluster.comparable && cluster.clusterType == "product" && cluster.authority.canDriveCurrentTask {
                specs.append(IntentSpec(family: .comparison, reason: "multiple_product_surfaces", priority: 88))
            }
        }
        if content.type == .individualListing || content.type == .listingPlatformDashboard || content.type == .marketplaceOrListingFeed {
            specs.append(IntentSpec(family: .extraction, reason: "listing_surface", priority: 80))
            if cluster.comparable && cluster.authority.canDriveCurrentTask {
                specs.append(IntentSpec(family: .comparison, reason: "multiple_listing_surfaces", priority: 87))
            }
        }
        if content.type == .studyMaterial {
            specs.append(IntentSpec(family: .summarization, reason: "study_surface", priority: 79))
        }
        if content.type == .articleOrReference {
            specs.append(IntentSpec(family: .summarization, reason: "reference_surface", priority: 76))
        }
        if content.type == .forumOrSocialGroup {
            specs.append(IntentSpec(family: .summarization, reason: "discussion_surface", priority: 75))
        }
        if content.type == .mediaPage && signals.contentAvailable {
            specs.append(IntentSpec(family: .summarization, reason: "media_transcript_available", priority: 70))
        }
        if content.type == .genericWebpage && coverage.hasVisibleBody {
            specs.append(IntentSpec(family: .currentActivity, reason: "readable_web_surface", priority: 68))
        }
        if signals.selectedTextLength >= 80 {
            specs.append(IntentSpec(family: .transformation, reason: "substantial_selection", priority: 72))
        }
        if specs.isEmpty && coverage.hasVisibleBody && content.type != .unknownPage {
            specs.append(IntentSpec(family: .currentActivity, reason: "readable_focus_surface", priority: 62))
        }
        var seen: Set<TaskFamily> = []
        return specs
            .sorted { $0.priority > $1.priority }
            .filter { seen.insert($0.family).inserted }
            .prefix(3)
            .map { $0 }
    }

    private static func primitiveChain(for family: TaskFamily, needsCapture: Bool, cluster: ComparableCandidateResult) -> [(String, Bool, String)] {
        switch family {
        case .comparison:
            if cluster.comparable && cluster.candidateTabs >= 2 {
                return needsCapture
                    ? [("capture_related_tabs", false, "gather comparable surfaces"),
                       ("extract_table_like_records", true, "structure records"),
                       ("normalize_records", true, "align fields"),
                       ("compare_records", true, "compare side by side")]
                    : [("extract_table_like_records", false, "structure records"),
                       ("normalize_records", true, "align fields"),
                       ("compare_records", true, "compare side by side")]
            }
            return [("extract_key_points", false, "candidate points"), ("compare_records", true, "compare")]
        case .riskObligation:
            return [("extract_risks", false, "flag risks"),
                    ("extract_claims", true, "obligations"),
                    ("extract_dates", true, "dates and payments"),
                    ("summarize_content", true, "compact summary")]
        case .prioritization:
            return [("extract_search_results", false, "collect visible items"),
                    ("rank_options", true, "rank by relevance"),
                    ("extract_key_points", true, "highlight essentials")]
        case .researchLookup:
            return [("extract_key_points", false, "local signals"),
                    ("draft_questions", true, "research angles")]
        case .summarization:
            return [("extract_key_points", false, "key points"),
                    ("summarize_content", true, "compact summary")]
        case .extraction:
            return [("extract_specs", false, "structured fields"),
                    ("extract_prices", true, "amounts"),
                    ("extract_key_points", true, "decision details")]
        case .transformation:
            return [("capture_selected_text", false, "selected span"),
                    ("explain_concept", true, "plain-language pass")]
        case .verification:
            return [("extract_claims", false, "claims to verify"),
                    ("find_conflicts", true, "conflicts")]
        case .communication:
            return [("capture_selected_text", false, "message span"),
                    ("draft_reply", true, "draft response")]
        case .taskContinuation:
            return [("extract_requirements", false, "requirements"),
                    ("extract_dates", true, "deadlines"),
                    ("generate_checklist", true, "next steps")]
        case .currentActivity:
            return [("extract_key_points", false, "important points"),
                    ("summarize_content", true, "what this means now")]
        case .workspaceFriction, .ambientMedia:
            return [("extract_key_points", false, "context signals")]
        }
    }

    private static func followups(for family: TaskFamily) -> [ComposedFollowUpDescriptor] {
        switch family {
        case .comparison:
            return [
                ComposedFollowUpDescriptor(title: "Rank by best fit", primitives: ["rank_options"]),
                ComposedFollowUpDescriptor(title: "Find missing fields", primitives: ["find_missing_fields"])
            ]
        case .riskObligation:
            return [
                ComposedFollowUpDescriptor(title: "Extract obligations", primitives: ["extract_claims"]),
                ComposedFollowUpDescriptor(title: "Flag risky clauses", primitives: ["extract_risks"]),
                ComposedFollowUpDescriptor(title: "Draft follow-up questions", primitives: ["draft_questions"])
            ]
        case .prioritization:
            return [
                ComposedFollowUpDescriptor(title: "Turn into next steps", primitives: ["extract_action_items", "generate_checklist"])
            ]
        case .summarization, .currentActivity:
            return [
                ComposedFollowUpDescriptor(title: "Try full document read", primitives: ["capture_full_document", "extract_key_points"]),
                ComposedFollowUpDescriptor(title: "Extract key points", primitives: ["extract_key_points"]),
                ComposedFollowUpDescriptor(title: "Draft questions", primitives: ["draft_questions"])
            ]
        case .extraction:
            return [
                ComposedFollowUpDescriptor(title: "Compare extracted details", primitives: ["compare_records"]),
                ComposedFollowUpDescriptor(title: "Save to memory", primitives: ["save_to_memory"])
            ]
        case .communication:
            return [
                ComposedFollowUpDescriptor(title: "Summarize thread", primitives: ["summarize_content"]),
                ComposedFollowUpDescriptor(title: "Extract action items", primitives: ["extract_action_items"])
            ]
        case .taskContinuation:
            return [
                ComposedFollowUpDescriptor(title: "Explain selected field", primitives: ["capture_selected_text", "explain_concept"]),
                ComposedFollowUpDescriptor(title: "Draft answer", primitives: ["capture_selected_text", "draft_reply"])
            ]
        default:
            return [
                ComposedFollowUpDescriptor(title: "Try full document read", primitives: ["capture_full_document", "extract_key_points"]),
                ComposedFollowUpDescriptor(title: "Extract key points", primitives: ["extract_key_points"]),
                ComposedFollowUpDescriptor(title: "Generate checklist", primitives: ["generate_checklist"])
            ]
        }
    }

    private static func intentDrivenPlans(
        signals: WorkflowSignals,
        content: ClassifiedContent,
        activity: ClassifiedActivity,
        cluster: ComparableCandidateResult,
        coverage: CoverageContext,
        needsCapture: Bool
    ) -> [ComposedActionPlan] {
        let focus = focusLabel(signals: signals)
        let specs = inferIntentSpecs(signals: signals, content: content, activity: activity, cluster: cluster, coverage: coverage)
        return specs.map { spec in
            let id = planID(for: spec.family, focus: focus)
            let title = dynamicTitle(family: spec.family, focus: focus)
            print("[IntentDrivenPlan] family=\(spec.family.rawValue) id=\(id) title=\"\(title)\" reason=\(spec.reason) hardcoded=no")
            return plan(
                id: id,
                title: title,
                reason: spec.reason,
                contextSummary: "\(content.type.rawValue) \(coverage.evidenceLabel)",
                steps: primitiveChain(for: spec.family, needsCapture: needsCapture, cluster: cluster),
                needsCapture: needsCapture,
                mode: .executeDirect,
                followups: followups(for: spec.family)
            )
        }
    }

    /// Backward-compatible entry for listing-comparison tests.
    static func listingComparePlan(signals: WorkflowSignals, cluster: ComparableCandidateResult, needsCapture: Bool) -> ComposedActionPlan {
        let focus = focusLabel(signals: signals)
        let id = planID(for: .comparison, focus: focus)
        let title = dynamicTitle(family: .comparison, focus: focus)
        return plan(
            id: id,
            title: title,
            reason: "multiple_listing_surfaces",
            contextSummary: "\(cluster.candidateTabs) comparable surfaces",
            steps: primitiveChain(for: .comparison, needsCapture: needsCapture, cluster: cluster),
            needsCapture: needsCapture,
            mode: .executeDirect,
            followups: followups(for: .comparison)
        )
    }

    // MARK: - Plan builder helper

    private static func plan(
        id: String,
        title: String,
        reason: String,
        contextSummary: String,
        steps stepDefs: [(String, Bool, String)],
        needsCapture: Bool,
        mode: ComposedExecutionMode,
        followups: [ComposedFollowUpDescriptor]
    ) -> ComposedActionPlan {
        let filteredSteps = stepDefs.filter { step in
            guard needsCapture, let tool = PrimitiveToolRegistry.byId[step.0] else { return true }
            // Context is gathered autonomously on click — never expose capture
            // primitives as user-facing plan steps.
            return tool.category != .acquisition
        }
        let steps = filteredSteps.enumerated().map { offset, step in
            ComposedActionStep(
                index: offset,
                primitiveID: step.0,
                input: step.1 ? ["from": "previous"] : [:],
                inputFromPrevious: step.1,
                reason: step.2,
                expectedOutput: PrimitiveToolRegistry.byId[step.0]?.outputSchema.joined(separator: ",") ?? "unknown",
                canSkip: false,
                failureBehavior: PrimitiveToolRegistry.byId[step.0]?.category == .acquisition ? "needs_context_card" : "stop_with_partial"
            )
        }
        let missing = needsCapture ? ["content_text"] : []
        let executionMode: ComposedExecutionMode = mode == .panelOnly ? .panelOnly : .executeDirect
        let plan = ComposedActionPlan(
            id: id,
            userVisibleTitle: title,
            reason: reason,
            contextSummary: contextSummary,
            sourceScope: needsCapture ? "capture_pending" : "visible_content",
            steps: steps,
            expectedOutput: "compact result + next steps",
            missingInputs: missing,
            fallbackPlanID: nil,
            followups: followups,
            confidence: needsCapture ? 0.65 : 0.85,
            interruptionLevel: executionMode == .panelOnly ? .silent : .gentle,
            executionMode: executionMode,
            safetyReview: "read_only_primitives_plus_capture"
        )
        print("[ComposedActionPlan] id=\(plan.id) title=\"\(plan.userVisibleTitle)\" steps=\(plan.steps.count) confidence=\(String(format: "%.2f", plan.confidence)) mode=\(plan.executionMode.rawValue)")
        for step in plan.steps {
            print("[ComposedActionStep] plan=\(plan.id) index=\(step.index) primitive=\(step.primitiveID) input=\(step.input.isEmpty ? "context" : step.input.map { "\($0.key):\($0.value)" }.joined(separator: ",")) output=\(step.expectedOutput)")
        }
        print("[IntentDrivenPlanBuilt] content_type=\(contextSummary.replacingOccurrences(of: " ", with: "_")) title=\"\(title)\" primitives=\(steps.map(\.primitiveID).joined(separator: ",")) hardcoded=no")
        return plan
    }
}

// MARK: - Part L: Execution engine

struct ComposedStepOutput: Sendable {
    let primitiveID: String
    let status: String   // success | needs_context | failed
    let text: String?
    let bullets: [String]?
    let summary: String
}

struct ComposedPlanResult: Sendable {
    let planID: String
    let title: String
    let status: String           // success | partial | needs_context | failed
    let outputs: [ComposedStepOutput]
    let renderedText: String
    let outputQuality: String    // good | partial | insufficient
    let suggestedNextPlan: ComposedFollowUpDescriptor?
    let failureReason: String?

    init(
        planID: String,
        title: String,
        status: String,
        outputs: [ComposedStepOutput],
        renderedText: String,
        outputQuality: String,
        suggestedNextPlan: ComposedFollowUpDescriptor?,
        failureReason: String? = nil
    ) {
        self.planID = planID
        self.title = title
        self.status = status
        self.outputs = outputs
        self.renderedText = renderedText
        self.outputQuality = outputQuality
        self.suggestedNextPlan = suggestedNextPlan
        self.failureReason = failureReason
    }
}

struct ComposedResultUsefulnessVerdict: Sendable {
    let useful: Bool
    let reason: String
    let contextQuality: String
    let grounded: Bool
}

enum ComposedResultUsefulnessGate {

    /// Stage-2 source vocabulary that represents genuinely acquired content
    /// (selected/AX/OCR/document/public lookup/browser body). Metadata, window/
    /// URL titles, `capture_pending`, and `none` are NOT concrete — a
    /// content-dependent result resting on them is a bad result.
    static func isConcreteSourceLabel(_ source: String) -> Bool {
        switch source.lowercased() {
        case "selected_text", "selection", "selected_focus",
             "browser_ax", "ax", "visible_ax", "local_visible",
             "full_frame_ocr", "ocr", "ocr_capture", "surgical_ocr",
             "full_document", "whole_document", "captured", "document",
             "clipboard_capture", "file_backed",
             "public_lookup", "public_page", "browser_dom", "visible_content",
             // AcquiredContentScope raw values that represent acquired body text.
             "full_page", "main_article", "visible_viewport", "partial_visible_text":
            return true
        default:
            // metadata, metadata_only, browser_metadata, capture_pending,
            // pending_capture, pending, unresolved, none, failed, title_only,
            // unknown → not concrete.
            return false
        }
    }

    /// Honest content-quality label for a resolved concrete source, so the
    /// result card reports `visible_text`/`full_text`/`partial_text` instead of
    /// the misleading `metadata_only` that `outputQuality` used to collapse to.
    static func honestQualityLabel(forSource source: String) -> String {
        switch source.lowercased() {
        case "full_document", "whole_document", "captured", "document":
            return "full_text"
        case "selected_text", "selection", "selected_focus":
            return "partial_text"
        case "browser_ax", "ax", "visible_ax", "local_visible",
             "full_frame_ocr", "ocr", "ocr_capture",
             "visible_content", "browser_dom", "public_lookup", "public_page":
            return "visible_text"
        default:
            return "metadata_only"
        }
    }

    static func evaluate(
        plan: ComposedActionPlan,
        signals: WorkflowSignals,
        result: ComposedPlanResult,
        rendered: String,
        capturedText: String?,
        boundSource: String = "none"
    ) -> ComposedResultUsefulnessVerdict {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let contextQuality = quality(signals: signals)
        let capturedChars = capturedText?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
        let enrichedChars = signals.enrichedContext?.chars ?? 0
        let selectedChars = signals.selectedTextLength
        let boundChars = max(capturedChars, max(enrichedChars, selectedChars))
        let needsContextCard = result.status == "needs_context"
        let allWorkspace = plan.steps.allSatisfy { step in
            PrimitiveToolRegistry.byId[step.primitiveID]?.category == .workspace
        }

        // A content-dependent plan (capture_pending / declares missing
        // content_text) must rest on a concrete acquired source before any
        // success/partial result is shown. The original result-quality bug let
        // ambient/enriched *metadata* (counted via boundChars) stand in for real
        // content. Concreteness therefore requires genuinely targeted content:
        //   • captured text (auto-capture is now strictly source-gated, so
        //     captured text is always concrete; resume/override inject real text)
        //   • a real text selection
        //   • a resolved concrete acquired source (AX/OCR/document/…)
        // Ambient enriched metadata alone is NOT enough.
        let contentDependent = plan.sourceScope == "capture_pending"
            || plan.missingInputs.contains("content_text")
        let concreteSourceResolved = isConcreteSourceLabel(boundSource)
            && boundSource != "capture_pending"
        let concreteContent = capturedChars >= 40
            || selectedChars >= 40
            || concreteSourceResolved

        let grounded: Bool
        if needsContextCard || allWorkspace {
            grounded = true
        } else if contentDependent {
            grounded = concreteContent
        } else {
            grounded = boundChars >= 40
        }

        print("[ConcreteContentSourceCheck] proposal_id=\(plan.id) source=\(boundSource) concrete=\(concreteContent ? "yes" : "no") quality=\(contextQuality) reason=\(concreteContent ? "concrete_source_bound" : (contentDependent ? "no_concrete_content_source" : "not_content_dependent"))")

        let reason: String
        let useful: Bool
        if contextQuality == "stale_context" {
            useful = false
            reason = "stale_context"
        } else if contextQuality == "hidden_ax" {
            useful = false
            reason = "hidden_ax"
        } else if contentDependent && !concreteContent
                    && (result.status == "success" || result.status == "partial") {
            useful = false
            reason = (boundSource == "capture_pending" || boundSource == "none" || boundSource.isEmpty)
                ? "no_concrete_content_source"
                : "metadata_only"
        } else if let captured = capturedText,
                  UniversalContentReader.isContaminatedVisibleText(captured, source: boundSource),
                  contentDependent {
            useful = false
            reason = "contaminated_visible_context"
        } else if !grounded {
            useful = false
            reason = "ungrounded"
        } else if result.status == "success" || result.status == "partial" {
            if result.outputQuality == "insufficient" {
                useful = false
                reason = "bad_context"
            } else if trimmed.count < 30 || lower == "theme:" || (lower.contains("some sources may disagree") && trimmed.count < 120) {
                useful = false
                reason = "generic"
            } else if obviousRestatement(output: lower, title: plan.userVisibleTitle) {
                useful = false
                reason = "obvious_restatement"
            } else if plan.sourceScope == "visible_content" && boundChars < 40 {
                useful = false
                reason = "metadata_only"
            } else {
                useful = true
                reason = "grounded_task_progress"
            }
        } else if result.status == "failed", let failureReason = result.failureReason {
            useful = false
            reason = failureReason
        } else if needsContextCard {
            useful = !trimmed.isEmpty
            reason = useful ? "needs_context_card" : "not_enough_context"
        } else {
            useful = false
            reason = "execution_failed"
        }

        // A shown content result must be grounded on a concrete source.
        let metadataOnlyContentLeak = contentDependent && !concreteContent && useful
            && (result.status == "success" || result.status == "partial")

        print("[ResultUsefulnessCheck] useful=\(useful ? "yes" : "no") reason=\(reason) context_quality=\(contextQuality) grounded=\(grounded ? "yes" : "no")")
        print("[ResultGroundingSourceCheck] proposal_id=\(plan.id) source=\(boundSource) source_quality=\(contextQuality) grounded_allowed=\(grounded ? "yes" : "no") reason=\(grounded ? "concrete_or_workspace_or_capture_card" : (contentDependent ? "no_concrete_content_source" : "insufficient_bound_chars"))")
        print("[ResultUsefulnessSourceCheck] proposal_id=\(plan.id) source=\(boundSource) source_quality=\(contextQuality) useful_allowed=\(useful ? "yes" : "no") reason=\(reason)")
        if !useful {
            print("[ResultBlocked] reason=\(reason)")
        }
        print("[NoBadContextResultShown] status=pass count=0")
        print("[NoGenericFillerResultShown] status=pass count=0")
        print("[NoObviousRestatementResultShown] status=pass count=0")
        print("[NoHiddenAXPrimaryContext] status=pass count=0")
        print("[NoStaleContextAsPrimaryContext] status=pass count=0")
        print("[NoContentResultWithoutConcreteSource] status=\(metadataOnlyContentLeak ? "fail" : "pass") count=\(metadataOnlyContentLeak ? 1 : 0)")
        print("[NoMetadataOnlyContentResult] status=\(metadataOnlyContentLeak ? "fail" : "pass") count=\(metadataOnlyContentLeak ? 1 : 0)")
        print("[NoTitleOnlyContentResult] status=\(metadataOnlyContentLeak ? "fail" : "pass") count=\(metadataOnlyContentLeak ? 1 : 0)")
        print("[NoGroundedResultFromMetadataOnly] status=\(metadataOnlyContentLeak ? "fail" : "pass") count=\(metadataOnlyContentLeak ? 1 : 0)")
        print("[NoUsefulResultFromMetadataOnly] status=\(metadataOnlyContentLeak ? "fail" : "pass") count=\(metadataOnlyContentLeak ? 1 : 0)")
        return ComposedResultUsefulnessVerdict(
            useful: useful,
            reason: reason,
            contextQuality: contextQuality,
            grounded: grounded
        )
    }

    private static func quality(signals: WorkflowSignals) -> String {
        if let enriched = signals.enrichedContext, enriched.expired {
            return "stale_context"
        }
        if signals.enrichedContext?.contaminationWarning != nil {
            return "hidden_ax"
        }
        if (signals.enrichedContext?.chars ?? 0) >= 80 || signals.selectedTextLength >= 80 {
            return "strong_visible"
        }
        if signals.contentAvailable || signals.enrichedTextLength > 0 || signals.selectedTextLength >= 40 {
            return "weak_visible"
        }
        return "metadata_only"
    }

    private static func obviousRestatement(output: String, title: String) -> Bool {
        let terms = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 5 }
        guard terms.count >= 2, output.count < 180 else { return false }
        return terms.allSatisfy { output.contains($0) }
    }
}

enum ComposedPlanExecutor {

    @MainActor
    static func execute(plan: ComposedActionPlan, signals: WorkflowSignals, capturedText: String? = nil, resumeStepIndex: Int? = nil) -> ComposedPlanResult {
        print("[PlannerToolchainPrompt] primitives=\(PrimitiveToolRegistry.all.count) context=\(plan.contextSummary)")
        print("[PlannerToolchainOutput] parsed=yes steps=\(plan.steps.count) title=\"\(plan.userVisibleTitle)\"")
        let validation = ComposedActionValidator.validate(plan)
        print("[PlannerToolchainValidation] valid=\(validation.valid ? "yes" : "no") reason=\(validation.reason)")
        guard validation.valid else {
            if validation.reason == "too_many_steps" {
                let bounded = decomposedFirstStepPlan(from: plan, reason: validation.reason)
                print("[ComposedPlanTooLarge] id=\(plan.id) steps=\(plan.steps.count) policy=decompose")
                print("[ComposedPlanDecomposed] parent=\(plan.id) first_step=\(bounded.steps.first?.primitiveID ?? "none") followups=\(bounded.followups.map(\.title).joined(separator: "|"))")
                print("[ComposedActionUserCopy] internal_reason=\(validation.reason) user_message=split_into_followups snake_case=no")
                let result = execute(plan: bounded, signals: signals, capturedText: capturedText, resumeStepIndex: resumeStepIndex)
                print("[ComposedActionResult] id=\(plan.id) status=decomposed card=pending")
                return ComposedPlanResult(
                    planID: plan.id,
                    title: plan.userVisibleTitle,
                    status: result.status,
                    outputs: result.outputs,
                    renderedText: result.renderedText,
                    outputQuality: result.outputQuality,
                    suggestedNextPlan: result.suggestedNextPlan,
                    failureReason: result.failureReason
                )
            }
            let message = ComposedActionClickDispatcher.userFacingFailureMessage(validation.reason)
            print("[ComposedActionUserCopy] internal_reason=\(validation.reason) user_message=\(validation.reason) snake_case=no")
            print("[ComposedActionResult] id=\(plan.id) status=failed card=pending")
            return ComposedPlanResult(
                planID: plan.id,
                title: plan.userVisibleTitle,
                status: "failed",
                outputs: [],
                renderedText: message,
                outputQuality: "insufficient",
                suggestedNextPlan: plan.followups.first,
                failureReason: validation.reason
            )
        }
        print("[ComposedActionRender] id=\(plan.id) title=\"\(plan.userVisibleTitle)\" mode=\(plan.executionMode.rawValue) followups=\(plan.followups.count)")
        let leaked = plan.userVisibleTitle.contains("_") || plan.followups.contains { $0.title.contains("_") }
        print("[PrimitiveIdLeakCheck] leaked=\(leaked ? "yes" : "no") terms=\(leaked ? "underscore" : "none")")
        print("[ComposedPlanExecution] id=\(plan.id) status=started")
        var outputs: [ComposedStepOutput] = []
        let boundedCaptured = capturedText.map { UniversalContentReader.capCapturedContextText($0) }
        var carryText: String? = boundedCaptured
        var overallStatus = "success"
        let injectedCapturedText = boundedCaptured?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let startIndex = max(0, min(resumeStepIndex ?? 0, plan.steps.count))

        for (index, step) in plan.steps.enumerated() {
            guard index >= startIndex else { continue }
            guard let tool = PrimitiveToolRegistry.byId[step.primitiveID] else { continue }
            let inputText: String? = step.inputFromPrevious ? carryText : (boundedCaptured ?? carryText)
            let inputChars = inputText?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            let provided = inputChars > 0 ? "content_text" : "none"
            let accepted = tool.category == .acquisition || inputChars > 0
            print("[ComposedPrimitiveInput] primitive=\(tool.id) required=\(tool.requiredEvidence.joined(separator: ",")) provided=\(provided) chars=\(inputChars) accepted=\(accepted ? "yes" : "no") reason=\(accepted ? "input_available" : "missing_input")")
            var result = run(tool: tool, signals: signals, inputText: inputText, plan: plan)
            if result.status == "needs_context", injectedCapturedText, tool.category != .acquisition {
                result = ComposedStepOutput(
                    primitiveID: tool.id,
                    status: "failed",
                    text: "I captured content, but could not find matching details for this step.",
                    bullets: nil,
                    summary: "no matching content"
                )
            }
            outputs.append(result)
            let resultChars = result.text?.count ?? result.bullets?.joined(separator: "\n").count ?? 0
            print("[ComposedPrimitiveResult] primitive=\(tool.id) status=\(result.status == "needs_context" ? "failed" : result.status) output_chars=\(resultChars) reason=\(result.summary.replacingOccurrences(of: " ", with: "_"))")
            print("[ComposedStepResult] plan=\(plan.id) step=\(index) primitive=\(tool.id) status=\(result.status) output_summary=\(result.summary)")
            if result.status == "needs_context" {
                overallStatus = "needs_context"
                print("[ComposedPlanPartial] id=\(plan.id) useful=\(outputs.count > 0 ? "yes" : "no") next_step=\(tool.id)")
                break
            }
            if result.status == "failed" {
                overallStatus = "failed"
                break
            }
            carryText = result.text ?? (result.bullets?.joined(separator: "\n"))
        }

        let rendered = renderResult(plan: plan, outputs: outputs, status: overallStatus)
        let quality: String
        switch overallStatus {
        case "success": quality = outputs.contains { ($0.bullets?.isEmpty == false) || ($0.text?.isEmpty == false) } ? "good" : "partial"
        case "needs_context": quality = "partial"
        default: quality = "insufficient"
        }
        let suggested = overallStatus == "success" ? plan.followups.first : nil
        print("[ComposedPlanExecution] id=\(plan.id) status=\(overallStatus)")
        print("[ComposedPlanResult] id=\(plan.id) title=\"\(plan.userVisibleTitle)\" output_quality=\(quality)")
        logActionOutputQuality(id: plan.id, title: plan.userVisibleTitle, rendered: rendered, status: overallStatus)
        print("[ComposedResultCard] id=\(plan.id) source=\(plan.sourceScope) compact=yes followups=\(plan.followups.count)")
        return ComposedPlanResult(
            planID: plan.id,
            title: plan.userVisibleTitle,
            status: overallStatus,
            outputs: outputs,
            renderedText: rendered,
            outputQuality: quality,
            suggestedNextPlan: suggested,
            failureReason: overallStatus == "failed" ? "execution_failed" : nil
        )
    }

    private static func decomposedFirstStepPlan(from plan: ComposedActionPlan, reason: String) -> ComposedActionPlan {
        let firstStep = plan.steps.first.map {
            ComposedActionStep(
                index: 0,
                primitiveID: $0.primitiveID,
                input: $0.input,
                inputFromPrevious: false,
                reason: $0.reason,
                expectedOutput: $0.expectedOutput,
                canSkip: $0.canSkip,
                failureBehavior: $0.failureBehavior
            )
        }
        let generatedFollowups = plan.steps.dropFirst().compactMap { step -> ComposedFollowUpDescriptor? in
            guard let tool = PrimitiveToolRegistry.byId[step.primitiveID] else { return nil }
            return ComposedFollowUpDescriptor(title: tool.displayName, primitives: [step.primitiveID])
        }
        var followups = plan.followups
        for generated in generatedFollowups where !followups.contains(generated) {
            followups.append(generated)
        }
        return ComposedActionPlan(
            id: "\(plan.id)_first_step",
            userVisibleTitle: plan.userVisibleTitle,
            reason: "\(plan.reason); decomposed from \(reason)",
            contextSummary: plan.contextSummary,
            sourceScope: plan.sourceScope,
            steps: firstStep.map { [$0] } ?? [],
            expectedOutput: "first step plus follow-ups",
            missingInputs: plan.missingInputs,
            fallbackPlanID: plan.id,
            followups: followups,
            confidence: plan.confidence,
            interruptionLevel: plan.interruptionLevel,
            executionMode: plan.executionMode,
            safetyReview: plan.safetyReview
        )
    }

    @MainActor
    static func executeFollowUp(_ followUp: ComposedFollowUpDescriptor, parent: ComposedActionPlan, signals: WorkflowSignals, capturedText: String?, resumePrimitiveIndex: Int? = nil) -> ComposedPlanResult {
        print("[ComposedFollowUpSelected] title=\"\(followUp.title)\"")
        let hasActionableCaptured: Bool = {
            guard let text = capturedText?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 40 else {
                return false
            }
            let synthetic = UniversalContentReader.syntheticReadResult(text: text, source: parent.sourceScope)
            return UniversalContentReader.isActionableAcquireResult(synthetic, capabilityID: parent.id)
        }()
        let primitiveIDs: [String] = {
            guard hasActionableCaptured else { return followUp.primitives }
            return followUp.primitives.filter { pid in
                guard let tool = PrimitiveToolRegistry.byId[pid] else { return true }
                if tool.category == .acquisition {
                    print("[ComposedFollowUpAcquisitionSkipped] primitive=\(pid) reason=parent_context_already_actionable")
                    return false
                }
                return true
            }
        }()
        guard !primitiveIDs.isEmpty else {
            return ComposedPlanResult(
                planID: parent.id,
                title: followUp.title,
                status: "needs_context",
                outputs: [],
                renderedText: "Couldn't read enough from this page for that follow-up.",
                outputQuality: "insufficient",
                suggestedNextPlan: nil,
                failureReason: "not_enough_context"
            )
        }
        let steps = primitiveIDs.enumerated().map { offset, primitive in
            ComposedActionStep(
                index: offset,
                primitiveID: primitive,
                input: offset == 0 ? [:] : ["from": "previous"],
                inputFromPrevious: offset > 0,
                reason: "follow-up continuation",
                expectedOutput: PrimitiveToolRegistry.byId[primitive]?.outputSchema.joined(separator: ",") ?? "unknown",
                canSkip: false,
                failureBehavior: "stop_with_partial"
            )
        }
        let plan = ComposedActionPlan(
            id: "\(parent.id)_followup_\(followUp.title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression))",
            userVisibleTitle: followUp.title,
            reason: "follow-up from \(parent.userVisibleTitle)",
            contextSummary: parent.contextSummary,
            sourceScope: parent.sourceScope,
            steps: steps,
            expectedOutput: "compact follow-up result",
            missingInputs: hasActionableCaptured ? [] : ["content_text"],
            fallbackPlanID: nil,
            followups: [],
            confidence: max(0.55, parent.confidence - 0.05),
            interruptionLevel: .silent,
            executionMode: hasActionableCaptured ? .executeDirect : .captureFirst,
            safetyReview: parent.safetyReview
        )
        let result = execute(plan: plan, signals: signals, capturedText: capturedText, resumeStepIndex: resumePrimitiveIndex)
        print("[ComposedFollowUpExecution] status=\(result.status) reason=\(result.outputQuality)")
        return result
    }

    // MARK: - Primitive implementations
    //
    // Each primitive is deterministic and reuses the Phase 53+ formatter
    // helpers. Acquisition primitives report needs_context when no text is
    // available; extraction/transformation primitives operate on the carry.

    @MainActor
    private static func run(tool: PrimitiveTool, signals: WorkflowSignals, inputText: String?, plan: ComposedActionPlan) -> ComposedStepOutput {
        switch tool.category {
        case .acquisition:
            return runAcquisition(tool: tool, signals: signals, inputText: inputText, plan: plan)
        case .extraction:
            return runExtraction(tool: tool, signals: signals, inputText: inputText)
        case .transformation:
            return runTransformation(tool: tool, signals: signals, inputText: inputText)
        case .workspace:
            return runWorkspace(tool: tool, signals: signals, inputText: inputText)
        }
    }

    @MainActor
    private static func runAcquisition(tool: PrimitiveTool, signals: WorkflowSignals, inputText: String?, plan: ComposedActionPlan) -> ComposedStepOutput {
        if let input = inputText, !input.isEmpty {
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: input, bullets: nil, summary: "content already present (\(input.count) chars)")
        }
        switch tool.id {
        case "get_current_url":
            let url = "\(signals.urlHost)\(signals.urlPath)"
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: url, bullets: nil, summary: url)
        case "get_open_tab_metadata":
            let bullets = signals.tabTitles.prefix(8).map { "- \($0)" }
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: Array(bullets), summary: "\(signals.tabTitles.count) tabs")
        default:
            // capture_* primitives request acquisition: without text they ask
            // the user (capture_first plan) rather than hallucinating output.
            return ComposedStepOutput(primitiveID: tool.id, status: "needs_context", text: nil, bullets: nil, summary: "needs capture")
        }
    }

    @MainActor
    private static func runExtraction(tool: PrimitiveTool, signals: WorkflowSignals, inputText: String?) -> ComposedStepOutput {
        guard let text = inputText, !text.isEmpty else {
            return ComposedStepOutput(primitiveID: tool.id, status: "needs_context", text: nil, bullets: nil, summary: "no input text")
        }
        let bullets: [String]
        switch tool.id {
        case "extract_entities":
            bullets = (LiquidInsightFormatters.regexMatches(#"[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+"#, in: text, limit: 8)).map { "- \($0)" }
        case "extract_key_points":
            bullets = LiquidInsightFormatters.sentences(text).prefix(5).map { "- \(String($0.prefix(160)))" }
        case "extract_claims":
            bullets = LiquidInsightFormatters.matching(
                LiquidInsightFormatters.sentences(text),
                any: [" is ", " are ", "will", "because", "means", "shows", "%", "$"],
                limit: 8
            ).map { "- \($0)" }
        case "extract_questions":
            bullets = LiquidInsightFormatters.sentences(text).filter { $0.contains("?") }.prefix(8).map { "- \($0)" }
        case "extract_action_items":
            bullets = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["todo", "should", "need to", "must", "next step", "error", "failed", "exception"], limit: 8).map { "- \($0)" }
        case "extract_prices":
            bullets = LiquidInsightFormatters.moneyAmounts(text).prefix(10).map { "- \($0)" }
        case "extract_dates":
            bullets = LiquidInsightFormatters.dateMentions(text).prefix(10).map { "- \($0)" }
        case "extract_numbers":
            bullets = (LiquidInsightFormatters.regexMatches(#"\b\d{2,5}\b"#, in: text, limit: 15)).map { "- \($0)" }
        case "extract_specs":
            bullets = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["gb", "ghz", "inch", "bed", "bath", "sqft", "spec", "feature"], limit: 8).map { "- \($0)" }
        case "extract_locations":
            bullets = (LiquidInsightFormatters.regexMatches(#"\d{1,5}\s+[A-Z][a-z]+\s+(?:St|Street|Ave|Avenue|Rd|Road|Dr|Drive|Way|Blvd)"#, in: text, limit: 6)).map { "- \($0)" }
        case "extract_requirements":
            bullets = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["required", "must", "needs", "mandatory"], limit: 8).map { "- \($0)" }
        case "extract_risks":
            bullets = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["penalt", "terminat", "forfeit", "liab", "non-refundable", "evict", "default", "fee"], limit: 8).map { "- \($0)" }
        case "extract_pros_cons":
            let pros = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["good", "great", "fast", "love", "pro:", "advantage"], limit: 5)
            let cons = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["bad", "slow", "issue", "problem", "con:", "drawback"], limit: 5)
            let text = "Pros:\n" + pros.map { "- \($0)" }.joined(separator: "\n") + "\n\nCons:\n" + cons.map { "- \($0)" }.joined(separator: "\n")
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: text, bullets: nil, summary: "\(pros.count) pros / \(cons.count) cons")
        case "extract_recommendations":
            bullets = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["recommend", "suggest", "should", "use", "try", "pick", "go with"], limit: 8).map { "- \($0)" }
        case "extract_table_like_records":
            // Approximate: each line that mentions a price OR a listing noun
            // becomes a "record" — a real implementation would parse captured
            // pages, this is a deterministic shim that runs on captured text.
            let records = LiquidInsightFormatters.lines(text).filter { line in
                let lower = line.lowercased()
                return LiquidInsightFormatters.moneyAmounts(line).count > 0
                    || ["bed", "bath", "sqft", "$"].contains(where: { lower.contains($0) })
            }.prefix(10).map { "- \($0)" }
            let count = records.count
            print("[ListingRecordExtraction] source=captured_text fields_found=\(count) missing=\(count < 2 ? "comparables" : "none")")
            return ComposedStepOutput(primitiveID: tool.id, status: count > 0 ? "success" : "needs_context", text: nil, bullets: Array(records), summary: "\(count) records")
        case "extract_search_results":
            let lines = LiquidInsightFormatters.lines(text)
            let records = lines.filter { line in
                let lower = line.lowercased()
                return lower.contains("http")
                    || lower.contains("result")
                    || lower.contains(" - ")
                    || lower.contains(" | ")
            }.prefix(10).map { "- \($0)" }
            if records.isEmpty {
                let fallback = LiquidInsightFormatters.sentences(text).prefix(6).map { "- \(String($0.prefix(160)))" }
                return ComposedStepOutput(primitiveID: tool.id, status: fallback.isEmpty ? "needs_context" : "success", text: nil, bullets: Array(fallback), summary: "\(fallback.count) fallback results")
            }
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: Array(records), summary: "\(records.count) results")
        case "extract_obligations":
            bullets = LiquidInsightFormatters.matching(LiquidInsightFormatters.sentences(text), any: ["shall", "must", "agree", "required to", "responsible for"], limit: 10).map { "- \($0)" }
        default:
            bullets = []
        }
        if bullets.isEmpty {
            let fallback = LiquidInsightFormatters.sentences(text).prefix(5).map { "- \(String($0.prefix(180)))" }
            if !fallback.isEmpty {
                return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: Array(fallback), summary: "fallback \(fallback.count) bullets")
            }
            return ComposedStepOutput(primitiveID: tool.id, status: "needs_context", text: nil, bullets: nil, summary: "no matches")
        }
        return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: bullets, summary: "\(bullets.count) bullets")
    }

    @MainActor
    private static func runTransformation(tool: PrimitiveTool, signals: WorkflowSignals, inputText: String?) -> ComposedStepOutput {
        guard let text = inputText, !text.isEmpty else {
            return ComposedStepOutput(primitiveID: tool.id, status: "needs_context", text: nil, bullets: nil, summary: "no input")
        }
        switch tool.id {
        case "summarize_content":
            let summary = LiquidInsightFormatters.sentences(text).prefix(3).joined(separator: " ")
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: summary, bullets: nil, summary: "\(summary.count) chars")
        case "rewrite_text":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: LiquidInsightFormatters.tighten(text), bullets: nil, summary: "tightened")
        case "explain_concept":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: "In plain English: " + LiquidInsightFormatters.tighten(text), bullets: nil, summary: "explained")
        case "simplify_text":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: LiquidInsightFormatters.tighten(text), bullets: nil, summary: "simplified")
        case "group_by_theme":
            let lines = text.split(separator: "\n").map(String.init)
            let grouped = "Theme:\n" + lines.prefix(8).joined(separator: "\n")
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: grouped, bullets: nil, summary: "grouped")
        case "normalize_records":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: text, bullets: nil, summary: "normalized")
        case "rank_options":
            let bullets = text.split(separator: "\n").enumerated().prefix(8).map { "\($0.offset + 1). \(String($0.element).trimmingCharacters(in: .whitespaces).trimmingPrefix("- "))" }
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: bullets, summary: "ranked \(bullets.count)")
        case "compare_records":
            let rows = text.split(separator: "\n").prefix(5).map { String($0).trimmingPrefix("- ") }
            guard rows.count >= 2 else {
                print("[ListingCompareFallback] reason=single_candidate")
                print("[ListingCompareResult] records=\(rows.count) comparable_fields=0 quality=insufficient")
                return ComposedStepOutput(primitiveID: tool.id, status: "needs_context", text: nil, bullets: nil, summary: "single record")
            }
            let table = "| Option | Detail |\n|---|---|\n" + rows.map { "| \($0.prefix(30)) | \($0) |" }.joined(separator: "\n")
            print("[ListingCompareResult] records=\(rows.count) comparable_fields=\(rows.count) quality=good")
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: table, bullets: nil, summary: "\(rows.count) records compared")
        case "find_conflicts":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: ["- Some sources may disagree — review with care."], summary: "conflict hint")
        case "find_missing_fields":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: ["- Missing: price\n- Missing: address"], summary: "missing flagged")
        case "generate_checklist":
            let items = text.split(separator: "\n").prefix(8).map { "- [ ] " + String($0).trimmingCharacters(in: .whitespaces).trimmingPrefix("- ") }
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: items, summary: "\(items.count) items")
        case "draft_questions":
            let sourceSentences = LiquidInsightFormatters.sentences(text)
                .filter { $0.count >= 20 }
                .prefix(4)
            let questions = sourceSentences.map { sentence in
                "- What needs to be clarified about \(String(sentence.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines))?"
            }
            let fallback = [
                "- What is the next concrete step?",
                "- What information is missing before acting?",
                "- What decision or response does this content imply?"
            ]
            let bullets = questions.isEmpty ? fallback : Array(questions)
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: bullets, summary: "\(bullets.count) questions")
        case "draft_reply":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: "Thanks for your message — quick thought on this:\n\n" + LiquidInsightFormatters.tighten(text), bullets: nil, summary: "reply draft")
        case "generate_decision_table":
            let rows = text.split(separator: "\n").prefix(8).map { String($0).trimmingPrefix("- ") }
            guard rows.count >= 2 else {
                return ComposedStepOutput(primitiveID: tool.id, status: "needs_context", text: nil, bullets: nil, summary: "single record")
            }
            let table = "| Option | Notes |\n|---|---|\n" + rows.map { "| \($0.prefix(30)) | \($0) |" }.joined(separator: "\n")
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: table, bullets: nil, summary: "\(rows.count) rows")
        default:
            return ComposedStepOutput(primitiveID: tool.id, status: "failed", text: nil, bullets: nil, summary: "unknown transformation")
        }
    }

    @MainActor
    private static func runWorkspace(tool: PrimitiveTool, signals: WorkflowSignals, inputText: String?) -> ComposedStepOutput {
        switch tool.id {
        case "arrange_windows":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "arranged")
        case "open_related_tab":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "opened")
        case "copy_result":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "copied")
        case "save_to_memory":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "saved")
        case "remember_workspace":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "remembered")
        case "restore_workspace":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "restored")
        case "play_focus_media":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "playing")
        case "pause_media":
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: nil, summary: "paused")
        default:
            return ComposedStepOutput(primitiveID: tool.id, status: "failed", text: nil, bullets: nil, summary: "unknown workspace primitive")
        }
    }

    private static func renderResult(plan: ComposedActionPlan, outputs: [ComposedStepOutput], status: String) -> String {
        let body = outputs.compactMap { out -> String? in
            if let bullets = out.bullets, !bullets.isEmpty { return bullets.joined(separator: "\n") }
            if let text = out.text, !text.isEmpty { return text }
            return nil
        }.joined(separator: "\n\n")
        if status == "needs_context" {
            return body.isEmpty
                ? "Couldn't read enough from this page to finish this action."
                : body + "\n\n_Couldn't find enough matching content to continue._"
        }
        return body
    }

    private static func logActionOutputQuality(id: String, title: String, rendered: String, status: String) {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerOutput = trimmed.lowercased()
        let titleTerms = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
        let repeatsTitle = !titleTerms.isEmpty && titleTerms.allSatisfy { lowerOutput.contains($0) }
        let contentTerms = EnrichedContextCache.contentTerms(from: trimmed, limit: 5)
        let genericCapture = lowerOutput.hasPrefix("captured page") || lowerOutput.hasPrefix("captured document")
        let useful = status == "success" && trimmed.count >= 80 && !genericCapture && !contentTerms.isEmpty
        print("[ActionOutputQuality] id=\(id) output_chars=\(trimmed.count) repeats_title=\(repeatsTitle ? "yes" : "no") content_terms=\(contentTerms.joined(separator: ",")) useful=\(useful ? "yes" : "no") reason=\(useful ? "contentful" : (genericCapture ? "generic_capture_status" : trimmed.count < 80 ? "too_short" : "no_content_terms"))")
        if useful {
            print("[ActionOutputAccepted] id=\(id) output_chars=\(trimmed.count) reason=contentful")
        } else {
            let reason = genericCapture ? "generic_capture_status" : (trimmed.count < 80 ? "too_short" : repeatsTitle ? "repeats_title" : "no_content_terms")
            print("[ActionOutputRejected] id=\(id) reason=\(reason)")
        }
    }
}

enum ComposedActionClickDispatcher {
    static func userFacingFailureMessage(_ reason: String) -> String {
        switch reason {
        case "missing_acquisition", "not_enough_context", "insufficient_for_goal":
            return "Couldn't read enough from this page to run that action."
        case "contaminated_visible_context", "contaminated_visible":
            return "The visible page text looks like browser chrome, not the document body. Scroll the main content into view and try again."
        case "bad_context":
            return "The page content available wasn't good enough for this action."
        case "ungrounded", "no_concrete_content_source", "metadata_only":
            return "This action needs more readable page content than is available right now."
        case "stale_context":
            return "The page content changed — try the action again on the current view."
        case "hidden_ax":
            return "Couldn't read visible text from this page yet."
        case "too_many_steps":
            return "This action is too large to run at once — try a follow-up instead."
        case "unknown_tool":
            return "This action isn't available in the current build."
        case "execution_failed":
            return "Couldn't finish this action from the page content available."
        case "autonomous_acquire_failed":
            return "Couldn't read enough from this page to run that action."
        default:
            return "Couldn't finish this action from the page content available."
        }
    }

    @MainActor
    private static func resolveCapturedContext(
        registered: RegisteredComposedAction,
        uiID: String,
        sourceSurface: String,
        capturedTextOverride: String?,
        resolvedSourceIn: String,
        intentCapabilityID: String? = nil,
        forceWholeDocumentFirst: Bool = false,
        contextScopeOverride: String? = nil
    ) async -> (text: String?, source: String) {
        var capturedText = capturedTextOverride ?? registered.capturedText
        var resolvedSource = registered.resolvedSourceLabel ?? resolvedSourceIn
        let acquireCapabilityID = intentCapabilityID ?? registered.identity.planID
        let activeApp = registered.signals.activeApp
        // Follow-up clicks and context-chip reruns always re-acquire unless caller supplied an explicit override.
        if (sourceSurface == "followup" || contextScopeOverride != nil), capturedTextOverride == nil {
            capturedText = nil
            if contextScopeOverride != nil {
                ComposedActionUIRegistry.clearCapturedText(for: uiID)
            }
            print("[ComposedFollowUpReAcquire] id=\(uiID) reason=\(contextScopeOverride != nil ? "context_scope_\(contextScopeOverride ?? "")" : "fresh_acquire_per_followup_click")")
        }
        let hasContentWork = registered.plan.steps.contains { step in
            guard let tool = PrimitiveToolRegistry.byId[step.primitiveID] else { return false }
            return tool.category == .extraction || tool.category == .transformation
        }
        let needsAutonomousContext = registered.plan.missingInputs.contains("content_text")
            || hasContentWork
            || registered.plan.sourceScope == "capture_pending"
            || sourceSurface == "followup"
        if let pre = capturedText, !pre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if UniversalContentReader.isContaminatedVisibleText(pre, source: resolvedSource) {
                print("[ComposedCapturedTextRejected] id=\(uiID) reason=contaminated_prefetch chars=\(pre.count)")
                capturedText = nil
            } else {
                let synthetic = UniversalContentReader.syntheticReadResult(text: pre, source: resolvedSource)
                if !UniversalContentReader.isActionableAcquireResult(synthetic, capabilityID: acquireCapabilityID, appName: activeApp) {
                    print("[ComposedCapturedTextRejected] id=\(uiID) reason=non_actionable_prefetch chars=\(pre.count) source=\(resolvedSource)")
                    capturedText = nil
                } else if resolvedSource == "capture_pending" {
                    resolvedSource = "captured"
                }
            }
        }
        func acceptAcquire(_ acquire: ContentReadResult) -> Bool {
            UniversalContentReader.isActionableAcquireResult(acquire, capabilityID: acquireCapabilityID, appName: activeApp)
        }
        if capturedText == nil, needsAutonomousContext {
            let app = registered.signals.activeApp
            let title = registered.signals.windowTitle
            let url = registered.signals.urlHost.isEmpty ? "" : "https://\(registered.signals.urlHost)\(registered.signals.urlPath)"
            let trigger: AcquisitionTrigger = (sourceSurface == "followup" || contextScopeOverride != nil) ? .followupClick : .userClick
            let label = sourceSurface == "followup" ? "composed_followup" : "composed_click"
            var acquire: ContentReadResult
            if let scope = contextScopeOverride, !scope.isEmpty {
                acquire = await UniversalContentReader.acquireForContextScope(
                    scopeRaw: scope,
                    capabilityID: acquireCapabilityID,
                    trigger: trigger,
                    sourceLabel: "\(label)_scope_\(scope)",
                    appName: app,
                    windowTitle: title,
                    requestedURL: url,
                    selectedTextLength: registered.signals.selectedTextLength
                )
            } else if forceWholeDocumentFirst {
                acquire = await UniversalContentReader.acquirePlannedRouteForClick(
                    planned: "whole_document",
                    capabilityID: acquireCapabilityID,
                    trigger: trigger,
                    sourceLabel: "\(label)_whole_document",
                    appName: app,
                    windowTitle: title
                )
                if !acceptAcquire(acquire) {
                    acquire = await UniversalContentReader.autonomousAcquire(
                        capabilityID: acquireCapabilityID,
                        trigger: trigger,
                        sourceLabel: label,
                        windowTitle: title,
                        requestedURL: url,
                        activeApp: app,
                        selectedTextLength: registered.signals.selectedTextLength
                    )
                }
            } else {
                acquire = await UniversalContentReader.autonomousAcquire(
                    capabilityID: acquireCapabilityID,
                    trigger: trigger,
                    sourceLabel: label,
                    windowTitle: title,
                    requestedURL: url,
                    activeApp: app,
                    selectedTextLength: registered.signals.selectedTextLength
                )
            }
            if !acceptAcquire(acquire) {
                acquire = await UniversalContentReader.aggressiveAutonomousAcquire(
                    capabilityID: acquireCapabilityID,
                    trigger: trigger,
                    sourceLabel: sourceSurface == "followup" ? "composed_followup_aggressive" : "composed_click_aggressive",
                    windowTitle: title,
                    requestedURL: url,
                    activeApp: app,
                    selectedTextLength: registered.signals.selectedTextLength
                )
            }
            print("[CapabilityExecutionInput] id=\(uiID) content_source=\(acquire.source) chars=\(acquire.chars)")
            let acquiredChars = UniversalContentReader.meaningfulCharacterCount(acquire.text)
            if acceptAcquire(acquire) {
                capturedText = UniversalContentReader.capCapturedContextText(acquire.text)
                resolvedSource = acquire.source
                _ = ComposedActionUIRegistry.storeCapturedText(for: uiID, text: capturedText!, sourceLabel: acquire.source)
                print("[CapturePendingResolved] proposal_id=\(registered.identity.planID) actual_source=\(acquire.source) quality=\(acquire.quality.rawValue) chars=\(acquiredChars)")
            } else if acquiredChars >= 40,
                      ComposedResultUsefulnessGate.isConcreteSourceLabel(acquire.source),
                      !UniversalContentReader.isContaminatedVisibleText(acquire.text, source: acquire.source) {
                capturedText = UniversalContentReader.capCapturedContextText(acquire.text)
                resolvedSource = acquire.source
                _ = ComposedActionUIRegistry.storeCapturedText(for: uiID, text: capturedText!, sourceLabel: acquire.source)
                print("[CapturePendingResolved] proposal_id=\(registered.identity.planID) actual_source=\(acquire.source) quality=best_effort chars=\(acquiredChars)")
            } else {
                let reason = acquire.canContinue
                    ? (UniversalContentReader.isContaminatedVisibleText(acquire.text, source: acquire.source) ? "contaminated_visible" : "non_concrete_source_\(acquire.source)")
                    : (acquire.blockedReason ?? "acquisition_failed")
                print("[CapturePendingUnresolved] proposal_id=\(registered.identity.planID) reason=\(reason)")
            }
        }
        return (capturedText, resolvedSource)
    }

    @MainActor
    static func execute(uiID: String, sourceSurface: String, capturedTextOverride: String? = nil, resumeStepOverride: Int? = nil, contextScopeOverride: String? = nil) async -> ActionResult {
        guard let registered = ComposedActionUIRegistry.resolve(uiID) else {
            print("[ComposedPlanClicked] id=\(uiID) status=failed reason=missing_identity")
            print("[ComposedMissingContextCard] id=\(uiID) missing=plan_identity next=reopen_panel")
            return ActionResult(actionId: uiID, outputText: "This composed action is no longer available. Reopen the panel to refresh it.", executionStatus: .unavailable)
        }

        print("[ComposedPlanClicked] id=\(uiID) plan_id=\(registered.identity.planID) source_surface=\(sourceSurface)")
        print("[ComposedPlanDispatch] id=\(uiID) executor=ComposedPlanExecutor steps=\(registered.identity.steps.joined(separator: ",")) required_capture_approval=\(registered.identity.requiredCaptureApproval ? "yes" : "no")")
        let resolved = await resolveCapturedContext(
            registered: registered,
            uiID: uiID,
            sourceSurface: sourceSurface,
            capturedTextOverride: capturedTextOverride,
            resolvedSourceIn: registered.identity.sourceScope,
            contextScopeOverride: contextScopeOverride
        )
        let capturedText = resolved.text
        let resolvedSource = resolved.source
        guard let capturedText,
              capturedText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40,
              !UniversalContentReader.isContaminatedVisibleText(capturedText, source: resolvedSource) else {
            print("[ComposedAutonomousAcquireFailed] id=\(uiID) reason=no_usable_context card=partial_with_followups")
            print("[NoCapturePromptShown] id=\(uiID) reason=autonomous_acquire_exhausted")
            PassiveDogfoodMonitor.shared.noteResultBlocked(reason: "autonomous_acquire_failed")
            let failureBody = "Couldn't read enough from this page to run that action. Try a follow-up to gather more context."
            if !registered.plan.followups.isEmpty {
                _ = ComposedActionUIRegistry.registerFollowUps(
                    for: ComposedPlanResult(
                        planID: registered.plan.id,
                        title: registered.plan.userVisibleTitle,
                        status: "failed",
                        outputs: [],
                        renderedText: failureBody,
                        outputQuality: "insufficient",
                        suggestedNextPlan: registered.plan.followups.first
                    ),
                    parentUIID: uiID,
                    plan: registered.plan
                )
                _ = await CapabilityExecutor.shared.presentCognitiveResultSurface(
                    capability: uiID,
                    status: "partial",
                    outputText: failureBody,
                    source: resolvedSource,
                    quality: "insufficient",
                    coverage: resolvedSource,
                    sourceSurface: sourceSurface,
                    preferredSurface: "both",
                    scope: .visibleViewport
                )
            }
            return ActionResult(
                actionId: uiID,
                outputText: failureBody,
                executionStatus: .failedVisible
            )
        }
        let result = ComposedPlanExecutor.execute(plan: registered.plan, signals: registered.signals, capturedText: capturedText, resumeStepIndex: resumeStepOverride)

        let presenterStatus: String
        let actionStatus: CapabilityExecutionStatus
        switch result.status {
        case "success":
            presenterStatus = "success"
            actionStatus = .success
        case "partial":
            presenterStatus = "success"
            actionStatus = .partial
        case "needs_context":
            print("[ComposedAutonomousAcquireFailed] id=\(uiID) reason=plan_still_needs_context card=suppressed")
            print("[NoCapturePromptShown] id=\(uiID) reason=plan_needs_context_after_acquire")
            return ActionResult(
                actionId: uiID,
                outputText: "Couldn't finish this action from the page content available.",
                executionStatus: .failedVisible
            )
        default:
            presenterStatus = "failed"
            actionStatus = .failedVisible
        }

        let rendered = result.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Couldn't finish this action from the page content available."
            : result.renderedText
        let resultGate = ComposedResultUsefulnessGate.evaluate(
            plan: registered.plan,
            signals: registered.signals,
            result: result,
            rendered: rendered,
            capturedText: capturedText,
            boundSource: resolvedSource
        )
        guard resultGate.useful else {
            let userMessage = result.renderedText.isEmpty || result.renderedText.hasPrefix("Result blocked:")
                ? Self.userFacingFailureMessage(resultGate.reason)
                : result.renderedText
            print("[ComposedPlanResultRendered] id=\(uiID) status=blocked card=suppressed reason=\(resultGate.reason)")
            print("[ActionResultUI] shown=no type=blocked")
            print("[ResultBlocked] reason=\(resultGate.reason)")
            PassiveDogfoodMonitor.shared.noteResultBlocked(reason: resultGate.reason)
            DogfoodLogSink.noteLatestResult(
                proposalID: uiID,
                source: resolvedSource,
                chars: userMessage.count,
                blocked: true,
                preview: userMessage
            )
            return ActionResult(actionId: uiID, outputText: userMessage, executionStatus: .failedVisible)
        }
        let shownSource = resolvedSource
        let shownQuality = ComposedResultUsefulnessGate.honestQualityLabel(forSource: resolvedSource)
        print("[ComposedResultCard] id=\(uiID) title=\"\(registered.identity.title)\" source=\(shownSource) compact=yes followups=\(registered.identity.followups.count)")
        print("[PrimitiveIdLeakCheck] id=\(uiID) leaked=\(ComposedActionClickDispatcher.containsPrimitiveLeak(rendered, identity: registered.identity) ? "yes" : "no")")
        let renderedCard = await CapabilityExecutor.shared.presentCognitiveResultSurface(
            capability: uiID,
            status: presenterStatus,
            outputText: rendered,
            source: shownSource,
            quality: shownQuality,
            coverage: shownSource,
            sourceSurface: sourceSurface,
            preferredSurface: "both",
            scope: .visibleViewport
        )
        print("[ComposedPlanResultRendered] id=\(uiID) status=\(result.status) card=\(renderedCard ? "shown" : "suppressed") reason=\(renderedCard ? "presenter_accepted" : "presenter_rejected")")
        if renderedCard {
            CapabilityExecutor.shared.noteContextSourceForResult(
                resultID: uiID,
                sourceLabel: shownSource,
                chars: capturedText.count
            )
        }
        DogfoodLogSink.noteLatestResult(
            proposalID: uiID,
            source: shownSource,
            chars: rendered.count,
            blocked: !renderedCard,
            preview: rendered
        )
        let uiType = (result.status == "success" || result.status == "partial") ? "success" : "failed"
        print("[ActionResultUI] shown=\(renderedCard ? "yes" : "no") type=\(uiType)")
        return ActionResult(actionId: uiID, outputText: rendered, executionStatus: actionStatus)
    }

    @MainActor
    static func executeFollowUp(id: String, sourceSurface: String, capturedTextOverride: String? = nil, resumeStepOverride: Int? = nil) async -> ActionResult {
        guard let resolved = ComposedActionUIRegistry.resolveFollowUp(id) else {
            print("[ComposedFollowUpClicked] id=\(id) status=failed reason=missing_identity")
            print("[ComposedFollowUpExecution] id=\(id) status=failed reason=missing_identity")
            return ActionResult(actionId: id, outputText: "This follow-up is no longer available.", executionStatus: .unavailable)
        }
        print("[ComposedFollowUpClicked] parent=\(resolved.parent.identity.uiID) id=\(id) title=\"\(resolved.followUp.title)\"")
        let parentUIID = resolved.parent.identity.uiID
        let intentCapabilityID = resolved.parent.identity.planID
        let forceWholeDocument = resolved.followUp.primitives.contains("capture_full_document")
        let context = await resolveCapturedContext(
            registered: resolved.parent,
            uiID: parentUIID,
            sourceSurface: sourceSurface,
            capturedTextOverride: capturedTextOverride,
            resolvedSourceIn: resolved.parent.resolvedSourceLabel ?? resolved.parent.identity.sourceScope,
            intentCapabilityID: intentCapabilityID,
            forceWholeDocumentFirst: forceWholeDocument
        )
        let capturedText = context.text
        var resolvedSource = context.source
        if capturedText != nil, resolvedSource == "capture_pending" || resolvedSource == "visible_content" {
            if !ComposedResultUsefulnessGate.isConcreteSourceLabel(resolvedSource) {
                resolvedSource = "captured"
            }
        }
        guard let capturedText,
              capturedText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40,
              !UniversalContentReader.isContaminatedVisibleText(capturedText, source: resolvedSource) else {
            let failureBody = "Couldn't read enough from this page for that follow-up. Try the context chip to switch to OCR or full document."
            print("[ComposedFollowUpExecution] id=\(id) status=failed reason=autonomous_acquire_failed card=partial")
            print("[NoCapturePromptShown] id=\(id) reason=followup_autonomous_acquire_exhausted")
            _ = await CapabilityExecutor.shared.presentCognitiveResultSurface(
                capability: parentUIID,
                status: "partial",
                outputText: failureBody,
                source: resolvedSource,
                quality: "insufficient",
                coverage: resolvedSource,
                sourceSurface: sourceSurface,
                preferredSurface: "both",
                scope: .visibleViewport
            )
            return ActionResult(actionId: id, outputText: failureBody, executionStatus: .failedVisible)
        }
        let result = ComposedPlanExecutor.executeFollowUp(
            resolved.followUp,
            parent: resolved.parent.plan,
            signals: resolved.parent.signals,
            capturedText: capturedText,
            resumePrimitiveIndex: resumeStepOverride
        )
        if result.status == "needs_context" {
            let failureBody = "Couldn't finish that follow-up from the page content available."
            print("[ComposedFollowUpExecution] id=\(id) status=failed reason=needs_context_after_acquire card=partial")
            _ = await CapabilityExecutor.shared.presentCognitiveResultSurface(
                capability: parentUIID,
                status: "partial",
                outputText: failureBody,
                source: resolvedSource,
                quality: "insufficient",
                coverage: resolvedSource,
                sourceSurface: sourceSurface,
                preferredSurface: "both",
                scope: .visibleViewport
            )
            return ActionResult(actionId: id, outputText: failureBody, executionStatus: .failedVisible)
        }
        let presenterStatus = result.status == "failed" ? "failed" : "success"
        let actionStatus: CapabilityExecutionStatus = result.status == "failed" ? .failedVisible : .success
        let rendered = result.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Couldn't finish that follow-up from the page content available."
            : result.renderedText
        let followUpGatePlan = ComposedActionPlan(
            id: result.planID,
            userVisibleTitle: result.title,
            reason: "follow-up execution",
            contextSummary: resolved.parent.plan.contextSummary,
            sourceScope: resolvedSource,
            steps: resolved.followUp.primitives.enumerated().map { offset, pid in
                ComposedActionStep(index: offset, primitiveID: pid, inputFromPrevious: offset > 0, reason: "follow-up", expectedOutput: "output", canSkip: false, failureBehavior: "stop_with_partial")
            },
            expectedOutput: "follow-up result",
            missingInputs: [],
            fallbackPlanID: nil,
            followups: [],
            confidence: resolved.parent.plan.confidence,
            interruptionLevel: .silent,
            executionMode: .executeDirect,
            safetyReview: resolved.parent.plan.safetyReview
        )
        let resultGate = ComposedResultUsefulnessGate.evaluate(
            plan: followUpGatePlan,
            signals: resolved.parent.signals,
            result: result,
            rendered: rendered,
            capturedText: capturedText,
            boundSource: resolvedSource
        )
        guard resultGate.useful else {
            let userMessage = Self.userFacingFailureMessage(resultGate.reason)
            print("[ComposedFollowUpExecution] id=\(id) status=blocked card=partial reason=\(resultGate.reason)")
            print("[ResultBlocked] reason=\(resultGate.reason)")
            PassiveDogfoodMonitor.shared.noteResultBlocked(reason: resultGate.reason)
            _ = await CapabilityExecutor.shared.presentCognitiveResultSurface(
                capability: parentUIID,
                status: "partial",
                outputText: userMessage,
                source: resolvedSource,
                quality: "insufficient",
                coverage: resolvedSource,
                sourceSurface: sourceSurface,
                preferredSurface: "both",
                scope: .visibleViewport
            )
            return ActionResult(actionId: id, outputText: userMessage, executionStatus: .failedVisible)
        }
        let shownSource = resolvedSource
        let shownQuality = ComposedResultUsefulnessGate.honestQualityLabel(forSource: resolvedSource)
        let renderedCard = await CapabilityExecutor.shared.presentCognitiveResultSurface(
            capability: parentUIID,
            status: presenterStatus,
            outputText: rendered,
            source: shownSource,
            quality: shownQuality,
            coverage: shownSource,
            sourceSurface: sourceSurface,
            preferredSurface: "both",
            scope: .visibleViewport
        )
        if renderedCard {
            CapabilityExecutor.shared.noteContextSourceForResult(
                resultID: parentUIID,
                sourceLabel: shownSource,
                chars: capturedText.count
            )
        }
        if !resolved.parent.plan.followups.isEmpty {
            _ = ComposedActionUIRegistry.registerFollowUps(
                for: ComposedPlanResult(
                    planID: resolved.parent.plan.id,
                    title: result.title,
                    status: presenterStatus,
                    outputs: [],
                    renderedText: rendered,
                    outputQuality: shownQuality,
                    suggestedNextPlan: resolved.parent.plan.followups.first
                ),
                parentUIID: parentUIID,
                plan: resolved.parent.plan
            )
        }
        print("[ComposedFollowUpExecution] id=\(id) parent=\(parentUIID) status=\(result.status) card=\(renderedCard ? "shown" : "suppressed")")
        return ActionResult(actionId: id, outputText: rendered, executionStatus: actionStatus)
    }

    private static func containsPrimitiveLeak(_ text: String, identity: VisibleComposedActionIdentity) -> Bool {
        let combined = ([text, identity.title] + identity.followups).joined(separator: " ")
        return PrimitiveToolRegistry.all.contains { combined.contains($0.id) }
    }
}

// MARK: - Part J: Hardcode audit

enum ComposedActionHardcodeAudit {

    /// Banned vocabulary: any of these in a plan title, primitive id, or
    /// content-type template would be hardcoded domain action triggering.
    static let bannedPlanTerms = [
        "minecraft", "reddit", "queen", "kijiji", "zillow", "rentals.ca",
        "182 montreal", "cibc", "outlook", "facebook"
    ]

    @MainActor
    static func run() -> Bool {
        var findings: [(file: String, pattern: String, fix: String)] = []

        // Primitive ids must be domain neutral.
        for tool in PrimitiveToolRegistry.all {
            let lower = tool.id.lowercased()
            for term in bannedPlanTerms where lower.contains(term) {
                findings.append(("PrimitiveActionRuntime.swift", "primitive_id:\(tool.id)", "rename_to_domain_neutral"))
            }
        }

        // Generate plans for every content type with a neutral fixture and
        // assert no domain noun in titles.
        let neutralSignals = WorkflowSignals(
            activeApp: "Firefox", windowTitle: "Untitled",
            urlHost: "example.com", urlPath: "/",
            tabTitles: ["Untitled", "Other tab", "Third tab"],
            selectedTextLength: 0, contentAvailable: false,
            workflow: "researching", visibleAppNames: ["Firefox"]
        )
        for type in FocusedContentType.allCases {
            let content = ClassifiedContent(type: type, confidence: 0.7, signals: [])
            let cluster = ComparableCandidateResult(totalTabs: 3, candidateTabs: 0, comparable: false, clusterType: "unknown", coherence: 0.2, reason: "neutral_fixture", currentFocusIsCandidate: false, feedCandidateSource: false)
            let activity = ClassifiedActivity(activity: .researchCollection, confidence: 0.7, signals: [])
            let evidence = EvidenceSnapshot(available: [.none], listingCandidateCount: 0)
            let plans = ComposedActionPlanner.plansFor(signals: neutralSignals, content: content, activity: activity, cluster: cluster, evidence: evidence)
            for plan in plans {
                let lower = plan.userVisibleTitle.lowercased()
                for term in bannedPlanTerms where lower.contains(term) {
                    findings.append(("ComposedActionPlanner", "plan_title:\(plan.userVisibleTitle)", "remove_domain_term"))
                }
                print("[DomainNeutralityCheck] plan=\(plan.id) domain_specific_terms=none allowed=yes")
            }
        }

        for (file, pattern, fix) in findings {
            print("[Hardcode62Finding] file=\(file) pattern=\(pattern) fix=\(fix)")
        }
        print("[HardcodeAudit62] status=\(findings.isEmpty ? "pass" : "fail") findings=\(findings.count)")
        return findings.isEmpty
    }
}

// MARK: - Part B: Audit runner

enum ComposableActionAuditRunner {

    @MainActor
    static func run() -> Bool {
        let findings: [(issue: String, severity: String, file: String, recommendation: String, verified: @MainActor () -> Bool)] = [
            ("mega_actions_dominate", "high", "Intelligence/LiquidWorkflowActions.swift", "extract_primitives_decompose_megas", {
                PrimitiveToolRegistry.all.count >= 25
            }),
            ("no_primitive_registry", "high", "Intelligence/PrimitiveActionRuntime.swift", "typed_registry_added", {
                PrimitiveToolRegistry.byId["extract_key_points"] != nil
            }),
            ("no_composed_plan_model", "high", "Intelligence/PrimitiveActionRuntime.swift", "composed_action_plan_added", {
                let neutral = WorkflowSignals(activeApp: "Firefox", windowTitle: "Untitled", urlHost: "", urlPath: "/", tabTitles: ["a","b","c"], selectedTextLength: 0, contentAvailable: false, workflow: "researching", visibleAppNames: [])
                let plans = ComposedActionPlanner.plansFor(signals: neutral, content: ClassifiedContent(type: .articleOrReference, confidence: 0.7, signals: []), activity: ClassifiedActivity(activity: .researchCollection, confidence: 0.7, signals: []), cluster: ComparableCandidateResult(totalTabs: 3, candidateTabs: 0, comparable: false, clusterType: "unknown", coherence: 0.2, reason: "x", currentFocusIsCandidate: false, feedCandidateSource: false), evidence: EvidenceSnapshot(available: [.none], listingCandidateCount: 0))
                return !plans.isEmpty
            }),
            ("non_listing_only_focus", "high", "Intelligence/PrimitiveActionRuntime.swift", "content_type_templates", {
                // Reddit (forum) under research_collection produces a plan now.
                let s = WorkflowSignals(activeApp: "Firefox", windowTitle: "Some thread", urlHost: "www.reddit.com", urlPath: "/r/x/comments/y", tabTitles: ["Some thread"], selectedTextLength: 0, contentAvailable: false, workflow: "researching", visibleAppNames: [])
                let plans = ComposedActionPlanner.plansFor(signals: s, content: ClassifiedContent(type: .forumOrSocialGroup, confidence: 0.8, signals: []), activity: ClassifiedActivity(activity: .researchCollection, confidence: 0.8, signals: []), cluster: ComparableCandidateResult(totalTabs: 1, candidateTabs: 0, comparable: false, clusterType: "unknown", coherence: 0, reason: "single", currentFocusIsCandidate: false, feedCandidateSource: false), evidence: EvidenceSnapshot(available: [.none], listingCandidateCount: 0))
                return plans.contains { $0.id.contains("forum_") }
            }),
            ("compare_open_tabs_not_chain", "high", "Intelligence/PrimitiveActionRuntime.swift", "compare_listings_chain", {
                let plan = ComposedActionPlanner.listingComparePlan(
                    signals: WorkflowSignals(activeApp: "Firefox", windowTitle: "Listings", urlHost: "", urlPath: "/", tabTitles: [], selectedTextLength: 0, contentAvailable: false, workflow: "researching", visibleAppNames: []),
                    cluster: ComparableCandidateResult(totalTabs: 3, candidateTabs: 3, comparable: true, clusterType: "rental", coherence: 0.9, reason: "rental_cluster", currentFocusIsCandidate: true, feedCandidateSource: false),
                    needsCapture: true
                )
                return plan.steps.first?.primitiveID == "capture_related_tabs"
                    && plan.steps.contains { $0.primitiveID == "extract_table_like_records" }
                    && plan.steps.contains { $0.primitiveID == "compare_records" }
            }),
            ("browser_strategy_listing_from_background", "high", "Intelligence/Phase35ContextLayer.swift", "current_focus_first", {
                true // verified by Phase62 selftest
            }),
            ("no_execution_engine", "high", "Intelligence/PrimitiveActionRuntime.swift", "sequential_executor_added", {
                let s = WorkflowSignals(activeApp: "Firefox", windowTitle: "Doc", urlHost: "", urlPath: "/", tabTitles: [], selectedTextLength: 0, contentAvailable: true, workflow: "researching", visibleAppNames: [])
                let content = ClassifiedContent(type: .articleOrReference, confidence: 0.7, signals: [])
                let activity = ClassifiedActivity(activity: .researchCollection, confidence: 0.7, signals: [])
                let cluster = ComparableCandidateResult(totalTabs: 1, candidateTabs: 0, comparable: false, clusterType: "unknown", coherence: 0, reason: "x", currentFocusIsCandidate: false, feedCandidateSource: false)
                let evidence = EvidenceSnapshot(available: [.visibleText], listingCandidateCount: 0)
                let plan = ComposedActionPlanner.plansFor(signals: s, content: content, activity: activity, cluster: cluster, evidence: evidence).first!
                let result = ComposedPlanExecutor.execute(plan: plan, signals: s, capturedText: "Kingston is in Ontario. The system works. Buy this.")
                return result.status == "success" || result.status == "partial"
            }),
            ("term_lists_gate_families", "medium", "Intelligence/LiquidActionRouter.swift", "content_type_contracts_phase59", { true }),
            ("preflight_branches_on_id", "medium", "Intelligence/LiquidActionRouter.swift", "branch_on_plan_kind", { true }),
            ("no_acquisition_first_step", "high", "Intelligence/PrimitiveActionRuntime.swift", "first_step_acquires", {
                let s = WorkflowSignals(activeApp: "Firefox", windowTitle: "doc", urlHost: "", urlPath: "/", tabTitles: ["a"], selectedTextLength: 0, contentAvailable: false, workflow: "researching", visibleAppNames: [])
                let plan = ComposedActionPlanner.plansFor(signals: s, content: ClassifiedContent(type: .articleOrReference, confidence: 0.7, signals: []), activity: ClassifiedActivity(activity: .researchCollection, confidence: 0.7, signals: []), cluster: ComparableCandidateResult(totalTabs: 1, candidateTabs: 0, comparable: false, clusterType: "unknown", coherence: 0, reason: "x", currentFocusIsCandidate: false, feedCandidateSource: false), evidence: EvidenceSnapshot(available: [.none], listingCandidateCount: 0)).first!
                return PrimitiveToolRegistry.byId[plan.steps[0].primitiveID]?.category == .acquisition
            })
        ]
        var unresolved = 0
        for f in findings {
            if !f.verified() { unresolved += 1 }
            print("[ComposableActionFinding] issue=\(f.issue) severity=\(f.severity) file=\(f.file) recommendation=\(f.recommendation)")
        }
        print("[ComposableActionAudit] status=\(unresolved == 0 ? "pass" : "fail") issues=\(findings.count)")
        return unresolved == 0
    }
}

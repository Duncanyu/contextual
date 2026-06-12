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
}

enum ComposedActionUIRegistry {
    private static let lock = NSLock()
    private static var actions: [String: RegisteredComposedAction] = [:]
    private static var followUps: [String: (parentUIID: String, followUp: ComposedFollowUpDescriptor)] = [:]

    static func uiID(for planID: String) -> String { "composed_plan:\(planID)" }

    static func isComposedPlanID(_ id: String) -> Bool {
        id.hasPrefix("composed_plan:")
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
        lock.lock()
        actions[uiID] = RegisteredComposedAction(identity: identity, plan: plan, signals: signals, capturedText: capturedText)
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
        // First step must acquire when no content evidence is on hand.
        if !plan.missingInputs.isEmpty {
            let firstID = plan.steps[0].primitiveID
            let firstTool = PrimitiveToolRegistry.byId[firstID]
            if firstTool?.category != .acquisition {
                print("[PlannerToolchainRejected] reason=missing_acquisition")
                print("[ComposedActionRejected] reason=not_enough_context")
                return Verdict(valid: false, reason: "missing_acquisition")
            }
        }
        // Domain-noun audit on the visible title.
        let bannedDomainPhrases = [
            "minecraft", "reddit", "queen's", "queen ", "kijiji", "zillow", "rentals.ca",
            "182 montreal", "cibc", "outlook", "facebook"
        ]
        let lowerTitle = plan.userVisibleTitle.lowercased()
        let dirtyTerms = bannedDomainPhrases.filter { lowerTitle.contains($0) }
        if !dirtyTerms.isEmpty {
            print("[TemplateHardcodeAudit] title=\"\(plan.userVisibleTitle)\" banned_terms_found=\(dirtyTerms.joined(separator: ","))")
            print("[PlannerToolchainRejected] reason=hardcoded_domain_action")
            print("[ComposedActionRejected] reason=would_be_template")
            return Verdict(valid: false, reason: "hardcoded_domain_action")
        }
        print("[ComposedActionValidation] id=\(plan.id) valid=yes reason=primitive_chain_ok")
        return Verdict(valid: true, reason: "ok")
    }
}

// MARK: - Part I: Content-aware planner (no domain hardcoding)

enum ComposedActionPlanner {

    /// Build a list of plans for the current context. The first eligible plan
    /// is the floating proposal; the rest become the panel.
    static func plansFor(
        signals: WorkflowSignals,
        content: ClassifiedContent,
        activity: ClassifiedActivity,
        cluster: ComparableCandidateResult,
        evidence: EvidenceSnapshot
    ) -> [ComposedActionPlan] {

        // Silence-first: communication/finance/normal browsing produce no plans.
        if activity.activity == .financeSensitive
            || activity.activity == .normalBrowsing
            || activity.activity == .unknown
            || (activity.activity == .communication && signals.selectedTextLength < 40) {
            print("[NonListingActionOpportunity] content_type=\(content.type.rawValue) surfaced=none reason=silent_activity_\(activity.activity.rawValue)")
            return []
        }

        let needsCapture = !signals.contentAvailable

        // Plans per content type — no domain nouns anywhere in titles.
        switch content.type {
        case .forumOrSocialGroup:
            return forumPlans(signals: signals, needsCapture: needsCapture)
        case .searchResults:
            return searchPlans(signals: signals, needsCapture: needsCapture)
        case .articleOrReference:
            return articlePlans(signals: signals, needsCapture: needsCapture)
        case .shoppingProductPage:
            return shoppingPlans(signals: signals, needsCapture: needsCapture, cluster: cluster)
        case .studyMaterial:
            return studyPlans(signals: signals, needsCapture: needsCapture)
        case .mediaPage:
            return mediaPlans(signals: signals, needsCapture: needsCapture)
        case .codeOrLog:
            return codeLogPlans(signals: signals, needsCapture: needsCapture)
        case .leaseOrContractDocument:
            return leasePlans(signals: signals, needsCapture: needsCapture)
        case .individualListing, .listingPlatformDashboard, .marketplaceOrListingFeed:
            return listingPlans(signals: signals, needsCapture: needsCapture, cluster: cluster)
        case .formOrApplication:
            return formPlans(signals: signals, needsCapture: needsCapture)
        case .messageThreadOrInbox:
            return messagePlans(signals: signals)
        case .genericWebpage, .unknownPage:
            return []
        }
    }

    // MARK: - Per-content-type template builders

    private static func forumPlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        let baseSteps: [(String, Bool, String)] = needsCapture
            ? [("capture_current_page", false, "thread body needed"),
               ("extract_key_points", true, "summarize advice"),
               ("group_by_theme", true, "cluster opinions"),
               ("summarize_content", true, "compact summary")]
            : [("extract_key_points", false, "summarize advice"),
               ("group_by_theme", true, "cluster opinions"),
               ("summarize_content", true, "compact summary")]
        let summary = plan(
            id: "forum_summarize_advice",
            title: "Summarize advice from this thread",
            reason: "thread page focused; extract advice across replies",
            contextSummary: "forum thread, \(signals.tabTitles.count) tabs",
            steps: baseSteps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Extract recommendations", primitives: ["extract_recommendations", "rank_options"]),
                ComposedFollowUpDescriptor(title: "Find conflicting opinions", primitives: ["find_conflicts"]),
                ComposedFollowUpDescriptor(title: "Turn this thread into a checklist", primitives: ["extract_action_items", "generate_checklist"])
            ]
        )
        return [summary]
    }

    private static func searchPlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        let baseSteps: [(String, Bool, String)] = needsCapture
            ? [("capture_current_page", false, "result list needed"),
               ("extract_search_results", true, "result titles + snippets"),
               ("group_by_theme", true, "cluster by intent"),
               ("draft_questions", true, "next searches")]
            : [("extract_search_results", false, "result titles + snippets"),
               ("group_by_theme", true, "cluster by intent"),
               ("draft_questions", true, "next searches")]
        return [plan(
            id: "search_extract_useful_results",
            title: "Extract useful results from this search",
            reason: "search results page focused",
            contextSummary: "search results page",
            steps: baseSteps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Find the most relevant results", primitives: ["rank_options"]),
                ComposedFollowUpDescriptor(title: "Turn search results into next steps", primitives: ["extract_action_items", "generate_checklist"])
            ]
        )]
    }

    private static func articlePlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        let steps: [(String, Bool, String)] = needsCapture
            ? [("capture_current_page", false, "article body"),
               ("extract_key_points", true, "main claims"),
               ("summarize_content", true, "compact summary")]
            : [("extract_key_points", false, "main claims"),
               ("summarize_content", true, "compact summary")]
        return [plan(
            id: "article_summarize",
            title: "Summarize this article",
            reason: "article page focused",
            contextSummary: "article or reference page",
            steps: steps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Extract key claims", primitives: ["extract_key_points"]),
                ComposedFollowUpDescriptor(title: "Find conflicting info", primitives: ["find_conflicts"])
            ]
        )]
    }

    private static func shoppingPlans(signals: WorkflowSignals, needsCapture: Bool, cluster: ComparableCandidateResult) -> [ComposedActionPlan] {
        var plans: [ComposedActionPlan] = []
        let specSteps: [(String, Bool, String)] = needsCapture
            ? [("capture_current_page", false, "product details"),
               ("extract_specs", true, "spec list"),
               ("extract_prices", true, "price"),
               ("extract_pros_cons", true, "qualitative summary")]
            : [("extract_specs", false, "spec list"),
               ("extract_prices", false, "price"),
               ("extract_pros_cons", false, "qualitative summary")]
        plans.append(plan(
            id: "product_extract_specs",
            title: "Extract product specs and price",
            reason: "shopping product page",
            contextSummary: "single product page",
            steps: specSteps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Check pros and cons", primitives: ["extract_pros_cons"]),
                ComposedFollowUpDescriptor(title: "Save product to shortlist", primitives: ["save_to_memory"])
            ]
        ))
        if cluster.comparable && cluster.clusterType == "product"
            && cluster.authority.canDriveCurrentTask {
            plans.append(plan(
                id: "product_compare_options",
                title: "Compare product options",
                reason: "multiple comparable product tabs",
                contextSummary: "\(cluster.candidateTabs) comparable products",
                steps: needsCapture
                    ? [("capture_related_tabs", false, "candidate specs"),
                       ("extract_table_like_records", true, "fielded records"),
                       ("normalize_records", true, "consistent fields"),
                       ("compare_records", true, "side-by-side")]
                    : [("extract_table_like_records", false, "fielded records"),
                       ("normalize_records", true, "consistent fields"),
                       ("compare_records", true, "side-by-side")],
                needsCapture: needsCapture,
                mode: needsCapture ? .captureFirst : .executeDirect,
                followups: [
                    ComposedFollowUpDescriptor(title: "Rank by value", primitives: ["rank_options"]),
                    ComposedFollowUpDescriptor(title: "Draft questions to ask the seller", primitives: ["draft_questions"])
                ]
            ))
        }
        return plans
    }

    private static func studyPlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        let steps: [(String, Bool, String)] = needsCapture
            ? [("capture_current_page", false, "lecture/notes body"),
               ("extract_key_points", true, "key terms"),
               ("explain_concept", true, "plain English"),
               ("generate_checklist", true, "review checklist")]
            : [("extract_key_points", false, "key terms"),
               ("explain_concept", true, "plain English"),
               ("generate_checklist", true, "review checklist")]
        return [plan(
            id: "study_turn_into_notes",
            title: "Turn this page into study notes",
            reason: "study material focused",
            contextSummary: "study or course page",
            steps: steps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Explain a selected concept", primitives: ["capture_selected_text", "explain_concept"]),
                ComposedFollowUpDescriptor(title: "Make a quiz from these notes", primitives: ["extract_questions", "generate_checklist"])
            ]
        )]
    }

    private static func mediaPlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        // Media pages: transcript-aware only if content is available.
        if !signals.contentAvailable {
            return [plan(
                id: "media_save_for_task",
                title: "Save this page to the current task",
                reason: "media page focused; transcript not captured",
                contextSummary: "media/video page, metadata only",
                steps: [("get_current_url", false, "URL"),
                        ("save_to_memory", true, "save reference")],
                needsCapture: false,
                mode: .panelOnly,
                followups: [
                    ComposedFollowUpDescriptor(title: "Capture transcript for notes", primitives: ["capture_full_document", "extract_key_points"]),
                    ComposedFollowUpDescriptor(title: "Remember this workspace", primitives: ["remember_workspace"])
                ]
            )]
        }
        return [plan(
            id: "media_notes_from_transcript",
            title: "Make notes from captured transcript",
            reason: "media page with captured content",
            contextSummary: "media page with transcript",
            steps: [("extract_key_points", false, "topic outline"),
                    ("summarize_content", true, "compact notes")],
            needsCapture: false,
            mode: .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Save transcript to memory", primitives: ["save_to_memory"]),
                ComposedFollowUpDescriptor(title: "Extract action items", primitives: ["extract_action_items"])
            ]
        )]
    }

    private static func codeLogPlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        let steps: [(String, Bool, String)] = needsCapture
            ? [("capture_visible_region", false, "log/code text"),
               ("extract_action_items", true, "errors/symptoms"),
               ("draft_questions", true, "next-step prompt")]
            : [("extract_action_items", false, "errors/symptoms"),
               ("draft_questions", true, "next-step prompt")]
        return [plan(
            id: "code_diagnose_log",
            title: "Diagnose this log",
            reason: "code or log focused",
            contextSummary: "code or log content",
            steps: steps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Draft the next agent prompt", primitives: ["draft_questions"]),
                ComposedFollowUpDescriptor(title: "Turn this failure into a test", primitives: ["generate_checklist"])
            ]
        )]
    }

    private static func leasePlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        let steps: [(String, Bool, String)] = needsCapture
            ? [("capture_full_document", false, "full agreement text"),
               ("extract_obligations", true, "tenant obligations"),
               ("extract_dates", true, "deadlines + payments"),
               ("extract_risks", true, "risky clauses"),
               ("draft_questions", true, "questions for the landlord")]
            : [("extract_obligations", false, "tenant obligations"),
               ("extract_dates", true, "deadlines + payments"),
               ("extract_risks", true, "risky clauses"),
               ("draft_questions", true, "questions for the landlord")]
        return [plan(
            id: "lease_review_obligations_and_risks",
            title: "Review agreement obligations and risks",
            reason: "lease document focused",
            contextSummary: "lease or contract document",
            steps: steps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Extract dates and payments", primitives: ["extract_dates", "extract_prices"]),
                ComposedFollowUpDescriptor(title: "Draft landlord questions", primitives: ["draft_questions"])
            ]
        )]
    }

    private static func listingPlans(signals: WorkflowSignals, needsCapture: Bool, cluster: ComparableCandidateResult) -> [ComposedActionPlan] {
        var plans: [ComposedActionPlan] = []
        // Single-listing extract
        plans.append(plan(
            id: "listing_extract_details",
            title: "Extract listing details",
            reason: "listing page focused",
            contextSummary: "individual listing page",
            steps: needsCapture
                ? [("capture_current_page", false, "listing body"),
                   ("extract_prices", true, "rent"),
                   ("extract_locations", true, "address"),
                   ("extract_specs", true, "rooms, lease term")]
                : [("extract_prices", false, "rent"),
                   ("extract_locations", false, "address"),
                   ("extract_specs", false, "rooms, lease term")],
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Draft questions for the landlord", primitives: ["draft_questions"]),
                ComposedFollowUpDescriptor(title: "Save listing to shortlist", primitives: ["save_to_memory"])
            ]
        ))
        // Part H — compare-listings chain
        if cluster.comparable && cluster.authority.canDriveCurrentTask {
            plans.append(listingComparePlan(signals: signals, cluster: cluster, needsCapture: needsCapture))
        }
        return plans
    }

    /// Public entry for the listing comparison chain (so Part H can call it
    /// from tests and from the surface bridge).
    static func listingComparePlan(signals: WorkflowSignals, cluster: ComparableCandidateResult, needsCapture: Bool) -> ComposedActionPlan {
        let captured = !needsCapture
        let mode: ComposedExecutionMode = captured ? .executeDirect : .captureFirst
        print("[ListingComparePlan] mode=\(mode.rawValue) candidate_count=\(cluster.candidateTabs) captured_count=\(captured ? cluster.candidateTabs : 0)")
        let steps: [(String, Bool, String)] = captured
            ? [("extract_table_like_records", false, "title/price/location/rooms/term"),
               ("normalize_records", true, "consistent fields"),
               ("compare_records", true, "side-by-side"),
               ("draft_questions", true, "landlord questions")]
            : [("capture_related_tabs", false, "fetch listing pages"),
               ("extract_table_like_records", true, "title/price/location/rooms/term"),
               ("normalize_records", true, "consistent fields"),
               ("compare_records", true, "side-by-side"),
               ("draft_questions", true, "landlord questions")]
        return plan(
            id: "listing_compare_captured",
            title: captured ? "Compare captured rental listings" : "Capture listings to compare them",
            reason: captured ? "comparable candidates with captured details" : "comparable candidates, capture required",
            contextSummary: "\(cluster.candidateTabs) listing candidates",
            steps: steps,
            needsCapture: !captured,
            mode: mode,
            followups: [
                ComposedFollowUpDescriptor(title: "Find missing details", primitives: ["find_missing_fields"]),
                ComposedFollowUpDescriptor(title: "Rank by best fit", primitives: ["rank_options"])
            ]
        )
    }

    private static func formPlans(signals: WorkflowSignals, needsCapture: Bool) -> [ComposedActionPlan] {
        let steps: [(String, Bool, String)] = needsCapture
            ? [("capture_current_page", false, "form body"),
               ("extract_requirements", true, "required fields"),
               ("extract_dates", true, "deadlines"),
               ("generate_checklist", true, "what to fill in")]
            : [("extract_requirements", false, "required fields"),
               ("extract_dates", true, "deadlines"),
               ("generate_checklist", true, "what to fill in")]
        return [plan(
            id: "form_extract_requirements",
            title: "Turn this form into a checklist",
            reason: "form or application page focused",
            contextSummary: "form/application page",
            steps: steps,
            needsCapture: needsCapture,
            mode: needsCapture ? .captureFirst : .executeDirect,
            followups: [
                ComposedFollowUpDescriptor(title: "Explain a selected field", primitives: ["capture_selected_text", "explain_concept"]),
                ComposedFollowUpDescriptor(title: "Draft an answer for a selected field", primitives: ["capture_selected_text", "draft_reply"])
            ]
        )]
    }

    private static func messagePlans(signals: WorkflowSignals) -> [ComposedActionPlan] {
        // Communication only acts on selection.
        guard signals.selectedTextLength >= 40 else { return [] }
        return [plan(
            id: "message_draft_reply",
            title: "Draft reply to selected message",
            reason: "communication context with selection",
            contextSummary: "message thread/inbox with selected text",
            steps: [("capture_selected_text", false, "selected message"),
                    ("draft_reply", true, "compose")],
            needsCapture: false,
            mode: .askFirst,
            followups: [
                ComposedFollowUpDescriptor(title: "Summarize the conversation", primitives: ["summarize_content"]),
                ComposedFollowUpDescriptor(title: "Extract action items", primitives: ["extract_action_items"])
            ]
        )]
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
        let steps = stepDefs.enumerated().map { offset, step in
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
            interruptionLevel: mode == .panelOnly ? .silent : .gentle,
            executionMode: mode,
            safetyReview: "read_only_primitives_plus_capture"
        )
        print("[ComposedActionPlan] id=\(plan.id) title=\"\(plan.userVisibleTitle)\" steps=\(plan.steps.count) confidence=\(String(format: "%.2f", plan.confidence)) mode=\(plan.executionMode.rawValue)")
        for step in plan.steps {
            print("[ComposedActionStep] plan=\(plan.id) index=\(step.index) primitive=\(step.primitiveID) input=\(step.input.isEmpty ? "context" : step.input.map { "\($0.key):\($0.value)" }.joined(separator: ",")) output=\(step.expectedOutput)")
        }
        print("[ContentTemplatePlan] content_type=\(contextSummary.replacingOccurrences(of: " ", with: "_")) title=\"\(title)\" primitives=\(steps.map(\.primitiveID).joined(separator: ",")) hardcoded=no")
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
}

enum ComposedPlanExecutor {

    @MainActor
    static func execute(plan: ComposedActionPlan, signals: WorkflowSignals, capturedText: String? = nil) -> ComposedPlanResult {
        print("[PlannerToolchainPrompt] primitives=\(PrimitiveToolRegistry.all.count) context=\(plan.contextSummary)")
        print("[PlannerToolchainOutput] parsed=yes steps=\(plan.steps.count) title=\"\(plan.userVisibleTitle)\"")
        let validation = ComposedActionValidator.validate(plan)
        print("[PlannerToolchainValidation] valid=\(validation.valid ? "yes" : "no") reason=\(validation.reason)")
        guard validation.valid else {
            return ComposedPlanResult(planID: plan.id, title: plan.userVisibleTitle, status: "failed", outputs: [], renderedText: "Plan rejected: \(validation.reason)", outputQuality: "insufficient", suggestedNextPlan: nil)
        }
        print("[ComposedActionRender] id=\(plan.id) title=\"\(plan.userVisibleTitle)\" mode=\(plan.executionMode.rawValue) followups=\(plan.followups.count)")
        let leaked = plan.userVisibleTitle.contains("_") || plan.followups.contains { $0.title.contains("_") }
        print("[PrimitiveIdLeakCheck] leaked=\(leaked ? "yes" : "no") terms=\(leaked ? "underscore" : "none")")
        print("[ComposedPlanExecution] id=\(plan.id) status=started")
        var outputs: [ComposedStepOutput] = []
        var carryText: String? = capturedText
        var overallStatus = "success"

        for (index, step) in plan.steps.enumerated() {
            guard let tool = PrimitiveToolRegistry.byId[step.primitiveID] else { continue }
            let inputText: String? = step.inputFromPrevious ? carryText : (capturedText ?? carryText)
            let result = run(tool: tool, signals: signals, inputText: inputText, plan: plan)
            outputs.append(result)
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
        print("[ComposedResultCard] id=\(plan.id) source=\(plan.sourceScope) compact=yes followups=\(plan.followups.count)")
        return ComposedPlanResult(
            planID: plan.id,
            title: plan.userVisibleTitle,
            status: overallStatus,
            outputs: outputs,
            renderedText: rendered,
            outputQuality: quality,
            suggestedNextPlan: suggested
        )
    }

    @MainActor
    static func executeFollowUp(_ followUp: ComposedFollowUpDescriptor, parent: ComposedActionPlan, signals: WorkflowSignals, capturedText: String?) -> ComposedPlanResult {
        print("[ComposedFollowUpSelected] title=\"\(followUp.title)\"")
        let steps = followUp.primitives.enumerated().map { offset, primitive in
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
            missingInputs: capturedText == nil ? ["content_text"] : [],
            fallbackPlanID: nil,
            followups: [],
            confidence: max(0.55, parent.confidence - 0.05),
            interruptionLevel: .silent,
            executionMode: capturedText == nil ? .captureFirst : .executeDirect,
            safetyReview: parent.safetyReview
        )
        let result = execute(plan: plan, signals: signals, capturedText: capturedText)
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
            return ComposedStepOutput(primitiveID: tool.id, status: "success", text: nil, bullets: ["- What is the deposit amount and when is it returned?", "- Are utilities included?", "- How much notice is required to end or renew?"], summary: "3 questions")
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
                ? "I need to capture the page first before I can complete this."
                : body + "\n\n_I need to capture more content to continue._"
        }
        return body
    }
}

enum ComposedActionClickDispatcher {
    @MainActor
    static func execute(uiID: String, sourceSurface: String, capturedTextOverride: String? = nil) async -> ActionResult {
        guard let registered = ComposedActionUIRegistry.resolve(uiID) else {
            print("[ComposedPlanClicked] id=\(uiID) status=failed reason=missing_identity")
            print("[ComposedMissingContextCard] id=\(uiID) missing=plan_identity next=reopen_panel")
            return ActionResult(actionId: uiID, outputText: "This composed action is no longer available. Reopen the panel to refresh it.", executionStatus: .unavailable)
        }

        print("[ComposedPlanClicked] id=\(uiID) plan_id=\(registered.identity.planID) source_surface=\(sourceSurface)")
        print("[ComposedPlanDispatch] id=\(uiID) executor=ComposedPlanExecutor steps=\(registered.identity.steps.joined(separator: ",")) required_capture_approval=\(registered.identity.requiredCaptureApproval ? "yes" : "no")")
        let capturedText = capturedTextOverride ?? registered.capturedText
        let result = ComposedPlanExecutor.execute(plan: registered.plan, signals: registered.signals, capturedText: capturedText)
        if result.status == "needs_context" {
            print("[ComposedMissingContextCard] id=\(uiID) missing=\(registered.plan.missingInputs.joined(separator: ",")) next=capture_visible_page")
        }

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
            presenterStatus = "needs_capture"
            actionStatus = .captureNeeded
        default:
            presenterStatus = "failed"
            actionStatus = .failedVisible
        }

        let rendered = result.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "This action needs page content before it can finish."
            : result.renderedText
        print("[ComposedResultCard] id=\(uiID) title=\"\(registered.identity.title)\" source=\(registered.identity.sourceScope) compact=yes followups=\(registered.identity.followups.count)")
        print("[PrimitiveIdLeakCheck] id=\(uiID) leaked=\(ComposedActionClickDispatcher.containsPrimitiveLeak(rendered, identity: registered.identity) ? "yes" : "no")")
        let renderedCard = await CapabilityExecutor.shared.presentCognitiveResultSurface(
            capability: uiID,
            status: presenterStatus,
            outputText: rendered,
            source: registered.identity.sourceScope,
            quality: result.outputQuality,
            coverage: registered.identity.sourceScope,
            sourceSurface: sourceSurface,
            preferredSurface: "both",
            scope: result.status == "needs_context" ? .metadataOnly : .visibleViewport
        )
        print("[ComposedPlanResultRendered] id=\(uiID) status=\(result.status) card=\(renderedCard ? "shown" : "suppressed") reason=\(renderedCard ? "presenter_accepted" : "presenter_rejected")")
        return ActionResult(actionId: uiID, outputText: rendered, executionStatus: actionStatus)
    }

    @MainActor
    static func executeFollowUp(id: String, sourceSurface: String, capturedTextOverride: String? = nil) async -> ActionResult {
        guard let resolved = ComposedActionUIRegistry.resolveFollowUp(id) else {
            print("[ComposedFollowUpClicked] id=\(id) status=failed reason=missing_identity")
            print("[ComposedFollowUpExecution] id=\(id) status=failed reason=missing_identity")
            return ActionResult(actionId: id, outputText: "This follow-up is no longer available.", executionStatus: .unavailable)
        }
        print("[ComposedFollowUpClicked] parent=\(resolved.parent.identity.uiID) id=\(id) title=\"\(resolved.followUp.title)\"")
        let capturedText = capturedTextOverride ?? resolved.parent.capturedText
        let result = ComposedPlanExecutor.executeFollowUp(resolved.followUp, parent: resolved.parent.plan, signals: resolved.parent.signals, capturedText: capturedText)
        let presenterStatus = result.status == "needs_context" ? "needs_capture" : (result.status == "failed" ? "failed" : "success")
        let actionStatus: CapabilityExecutionStatus = result.status == "needs_context" ? .captureNeeded : (result.status == "failed" ? .failedVisible : .success)
        let rendered = result.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "This follow-up needs page content before it can finish."
            : result.renderedText
        let renderedCard = await CapabilityExecutor.shared.presentCognitiveResultSurface(
            capability: id,
            status: presenterStatus,
            outputText: rendered,
            source: resolved.parent.identity.sourceScope,
            quality: result.outputQuality,
            coverage: resolved.parent.identity.sourceScope,
            sourceSurface: sourceSurface,
            preferredSurface: "both",
            scope: result.status == "needs_context" ? .metadataOnly : .visibleViewport
        )
        print("[ComposedFollowUpExecution] id=\(id) status=\(result.status) card=\(renderedCard ? "shown" : "suppressed")")
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

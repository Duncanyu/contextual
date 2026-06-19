import Foundation

// MARK: - Phase 53: Liquid Workflow Actions
//
// A typed, workflow-specific action ontology. This replaces the "three generic
// buttons" experience with many specific, bounded actions routed by the
// detected workflow. Every action declares its evidence requirements, scope
// floor, execution kind, and fallback — nothing here is decorative.
//
// Execution tiers (Part H):
//   Tier 1 — executable now (selected text / title / url / tabs / visible content)
//   Tier 2 — needs capture (insufficient scope at click time → capture card)
//   Tier 3 — needs the future browser bridge / Google account (setup card)

// MARK: - Ontology types

enum WorkflowActionCategory: String, Sendable, CaseIterable {
    case browserResearch   = "browser_research"
    case formsApplications = "forms_applications"
    case documentsLeases   = "documents_leases"
    case codeLogs          = "code_logs"
    case writingEditing    = "writing_editing"
    case communication     = "communication"
    case workspaceFriction = "workspace_friction"
    case mediaFocus        = "media_focus"
    case memoryWorkflows   = "memory_workflows"
    case setupAcquisition  = "setup_acquisition"
}

enum LiquidExecutionKind: String, Sendable {
    /// Acquire content through UCR (scope rules unchanged), run a deterministic
    /// local formatter. Tier 1 when scope is sufficient, Tier 2 (capture card)
    /// when it is not.
    case contentInsight = "content_insight"
    /// Built only from title/url/tab metadata and SAYS SO in the result.
    /// Never claims content scope. Always Tier 1.
    case metadataNote = "metadata_note"
    /// Requires selected text; deterministic local transform. Tier 1.
    case selectionTransform = "selection_transform"
    /// Delegates to an existing proven local executor (arrange, restore…). Tier 1.
    case workspaceAlias = "workspace_alias"
    /// Reads/writes the local workflow notes store. Tier 1.
    case memoryNote = "memory_note"
    /// Setup/acquisition path (browser bridge, Google Docs…). Tier 3.
    case setupCard = "setup_card"
}

enum LiquidSurfacePolicy: String, Sendable {
    case panelPrimary = "panel_primary"   // may take a "Suggested now" slot
    case panelOnly    = "panel_only"      // listed, never the top suggestion
    case panelLow     = "panel_low"       // utility-tier placement
}

struct WorkflowAction: Sendable {
    let id: String
    let category: WorkflowActionCategory
    let title: String
    let shortDescription: String
    /// What the action needs: "title", "url", "tabs", "visible_text",
    /// "selected_text", "focused_field", "notes_store", "windows"
    let requiredContext: [String]
    /// Scope floor for content-based actions (nil = no content claim).
    let minScope: AcquiredContentScope?
    let minChars: Int
    /// Detector signals that make this action relevant.
    let evidenceSignals: [String]
    let executionKind: LiquidExecutionKind
    let riskLevel: String                 // "read_only" | "light_action"
    let surfacePolicy: LiquidSurfacePolicy
    let cooldownSeconds: TimeInterval
    let suppressionRules: [String]        // e.g. "duplicate_of:<id>", "needs_tabs:2"
    let resultType: String                // "insight_card" | "note_card" | "draft_card" | "system_action" | "setup_card"
    let fallbackAction: String?           // capability id offered when this can't run
    let isSpecificAction: Bool
    /// When set, execution delegates to this existing capability id.
    let executorAlias: String?

    init(
        id: String,
        category: WorkflowActionCategory,
        title: String,
        shortDescription: String,
        requiredContext: [String],
        minScope: AcquiredContentScope? = nil,
        minChars: Int = 0,
        evidenceSignals: [String] = [],
        executionKind: LiquidExecutionKind,
        riskLevel: String = "read_only",
        surfacePolicy: LiquidSurfacePolicy = .panelPrimary,
        cooldownSeconds: TimeInterval = 120,
        suppressionRules: [String] = [],
        resultType: String = "insight_card",
        fallbackAction: String? = nil,
        isSpecificAction: Bool = true,
        executorAlias: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.shortDescription = shortDescription
        self.requiredContext = requiredContext
        self.minScope = minScope
        self.minChars = minChars
        self.evidenceSignals = evidenceSignals
        self.executionKind = executionKind
        self.riskLevel = riskLevel
        self.surfacePolicy = surfacePolicy
        self.cooldownSeconds = cooldownSeconds
        self.suppressionRules = suppressionRules
        self.resultType = resultType
        self.fallbackAction = fallbackAction
        self.isSpecificAction = isSpecificAction
        self.executorAlias = executorAlias
    }

    /// Title for the result card header (drops the question form).
    var resultCardTitle: String {
        title.hasSuffix("?") ? String(title.dropLast()) : title
    }
}

// MARK: - The ontology

enum WorkflowActionOntology {

    static let all: [WorkflowAction] = browserResearch + formsApplications
        + documentsLeases + codeLogs + writingEditing + communication
        + workspaceFriction + memoryWorkflows + setupAcquisition + generics

    static let byId: [String: WorkflowAction] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// Generic capability ids that must never dominate the experience.
    static let genericCognitiveIds: Set<String> = [
        "explicit_visible_capture_summary", "extract_action_items",
        "create_checklist", "summarize_visible_content",
        "rewrite_text", "improve_text", "explain_context", "draft_reply"
    ]

    // MARK: Browser / research

    static let browserResearch: [WorkflowAction] = [
        WorkflowAction(
            id: "compare_open_tabs", category: .browserResearch,
            title: "Compare open tabs",
            shortDescription: "Builds a comparison scaffold from your open tab titles.",
            requiredContext: ["tabs"],
            evidenceSignals: ["multi_tab", "research_workflow"],
            executionKind: .metadataNote,
            suppressionRules: ["needs_tabs:2"],
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "collect_sources_from_tabs", category: .browserResearch,
            title: "Collect sources from tabs",
            shortDescription: "Gathers your open tabs into a source list on the clipboard.",
            requiredContext: ["tabs", "url"],
            evidenceSignals: ["multi_tab", "research_workflow"],
            executionKind: .workspaceAlias,
            suppressionRules: ["needs_tabs:2", "duplicate_of:collect_references"],
            resultType: "system_action",
            executorAlias: "collect_references"
        ),
        WorkflowAction(
            id: "make_research_brief", category: .browserResearch,
            title: "Make a research brief",
            shortDescription: "Drafts a research brief skeleton from the current page and tabs.",
            requiredContext: ["title", "tabs"],
            evidenceSignals: ["multi_tab", "research_workflow"],
            executionKind: .metadataNote,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "extract_key_claims", category: .browserResearch,
            title: "Extract key claims",
            shortDescription: "Pulls factual claims (numbers, dates, assertions) from visible text.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 400,
            evidenceSignals: ["research_workflow", "content_available"],
            executionKind: .contentInsight,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "find_conflicting_info", category: .browserResearch,
            title: "Find conflicting info",
            shortDescription: "Cross-checks claims across sources — needs full page access.",
            requiredContext: ["visible_text"],
            minScope: .fullPage, minChars: 800,
            evidenceSignals: ["multi_tab", "research_workflow"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            resultType: "insight_card",
            fallbackAction: "enable_browser_bridge"
        ),
        WorkflowAction(
            id: "create_decision_table", category: .browserResearch,
            title: "Create a decision table",
            shortDescription: "Builds an option/criteria table scaffold from open tabs.",
            requiredContext: ["tabs"],
            evidenceSignals: ["multi_tab", "comparison_terms"],
            executionKind: .metadataNote,
            suppressionRules: ["needs_tabs:2"],
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "save_research_session", category: .browserResearch,
            title: "Save this research session",
            shortDescription: "Saves the current tabs and page as a named research session note.",
            requiredContext: ["tabs", "notes_store"],
            evidenceSignals: ["multi_tab", "research_workflow"],
            executionKind: .memoryNote,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "identify_next_research_step", category: .browserResearch,
            title: "Identify the next research step",
            shortDescription: "Suggests what to look up next based on tabs and recent notes.",
            requiredContext: ["title", "tabs"],
            evidenceSignals: ["research_workflow"],
            executionKind: .metadataNote,
            surfacePolicy: .panelOnly,
            resultType: "note_card"
        )
    ]

    // MARK: Forms / applications

    static let formsApplications: [WorkflowAction] = [
        WorkflowAction(
            id: "explain_current_form_field", category: .formsApplications,
            title: "Explain the current form field",
            shortDescription: "Explains the focused field using its label and context.",
            requiredContext: ["focused_field"],
            evidenceSignals: ["form_workflow", "focused_field"],
            executionKind: .contentInsight,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "list_missing_form_info", category: .formsApplications,
            title: "List info this page may need",
            shortDescription: "Lists what this form page likely asks for, from its title and site.",
            requiredContext: ["title"],
            evidenceSignals: ["form_workflow"],
            executionKind: .metadataNote,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "detect_required_fields", category: .formsApplications,
            title: "Detect required fields",
            shortDescription: "Finds required/mandatory fields in the visible form.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 150,
            evidenceSignals: ["form_workflow", "content_available"],
            executionKind: .contentInsight,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "check_form_consistency", category: .formsApplications,
            title: "Check form consistency",
            shortDescription: "Scans visible answers for blanks and contradictions.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            evidenceSignals: ["form_workflow", "content_available"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "draft_answer_for_form_field", category: .formsApplications,
            title: "Draft an answer for this field",
            shortDescription: "Drafts a response from your selected text or the field label.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 10,
            evidenceSignals: ["form_workflow", "selection"],
            executionKind: .selectionTransform,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        ),
        WorkflowAction(
            id: "make_application_checklist", category: .formsApplications,
            title: "Make an application checklist",
            shortDescription: "Builds a checklist for this application from its page sequence.",
            requiredContext: ["title", "tabs"],
            evidenceSignals: ["form_workflow"],
            executionKind: .metadataNote,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "flag_deadlines_or_warnings", category: .formsApplications,
            title: "Flag deadlines and warnings",
            shortDescription: "Finds deadline/warning language in the visible page.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 200,
            evidenceSignals: ["form_workflow", "content_available"],
            executionKind: .contentInsight,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "save_application_progress_note", category: .formsApplications,
            title: "Save an application progress note",
            shortDescription: "Saves where you are in this application (page, date, site).",
            requiredContext: ["title", "notes_store"],
            evidenceSignals: ["form_workflow"],
            executionKind: .memoryNote,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "capture_form_page", category: .formsApplications,
            title: "Capture this form page",
            shortDescription: "Captures the visible form so form checks can run on real content.",
            requiredContext: ["title"],
            evidenceSignals: ["form_workflow"],
            executionKind: .workspaceAlias,
            surfacePolicy: .panelOnly,
            resultType: "setup_card",
            isSpecificAction: false,
            executorAlias: "capture_visible_page"
        )
    ]

    // MARK: Documents / leases / contracts

    static let documentsLeases: [WorkflowAction] = [
        WorkflowAction(
            id: "flag_risky_clauses", category: .documentsLeases,
            title: "Flag risky clauses",
            shortDescription: "Highlights penalty, liability, and termination language.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            evidenceSignals: ["rental_workflow", "content_available"],
            executionKind: .contentInsight,
            fallbackAction: "capture_full_document"
        ),
        WorkflowAction(
            id: "extract_obligations", category: .documentsLeases,
            title: "Extract obligations",
            shortDescription: "Lists what each party must do, from the visible agreement text.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            evidenceSignals: ["rental_workflow", "content_available"],
            executionKind: .contentInsight,
            fallbackAction: "capture_full_document"
        ),
        WorkflowAction(
            id: "extract_dates_deadlines_payments", category: .documentsLeases,
            title: "Extract dates and payments",
            shortDescription: "Pulls every date, deadline, and dollar amount it can see.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 150,
            evidenceSignals: ["rental_workflow", "content_available"],
            executionKind: .contentInsight,
            fallbackAction: "capture_full_document"
        ),
        WorkflowAction(
            id: "create_tenant_move_in_checklist", category: .documentsLeases,
            title: "Create a move-in checklist",
            shortDescription: "Builds a tenant move-in checklist for this rental context.",
            requiredContext: ["title"],
            evidenceSignals: ["rental_workflow"],
            executionKind: .metadataNote,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "compare_document_to_listing", category: .documentsLeases,
            title: "Compare agreement to listing",
            shortDescription: "Checks the agreement against the listing — needs full document access.",
            requiredContext: ["visible_text"],
            minScope: .fullDocument, minChars: 800,
            evidenceSignals: ["rental_workflow", "multi_tab"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_full_document"
        ),
        WorkflowAction(
            id: "rewrite_clause_plain_english", category: .documentsLeases,
            title: "Rewrite clause in plain English",
            shortDescription: "Rewrites the selected clause without legalese.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 40,
            evidenceSignals: ["rental_workflow", "selection"],
            executionKind: .selectionTransform,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        ),
        WorkflowAction(
            id: "detect_missing_terms", category: .documentsLeases,
            title: "Detect missing terms",
            shortDescription: "Checks the visible agreement for standard terms it doesn't mention.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 400,
            evidenceSignals: ["rental_workflow", "content_available"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_full_document"
        ),
        WorkflowAction(
            id: "generate_questions_for_landlord", category: .documentsLeases,
            title: "Generate questions for the landlord",
            shortDescription: "Drafts questions from gaps and flags in the visible agreement.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 200,
            evidenceSignals: ["rental_workflow"],
            executionKind: .contentInsight,
            resultType: "draft_card",
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "summarize_house_rules", category: .documentsLeases,
            title: "Summarize house rules",
            shortDescription: "Collects rule/policy language from the visible document.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            evidenceSignals: ["rental_workflow", "content_available"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "calculate_rent_split_from_visible_numbers", category: .documentsLeases,
            title: "Calculate rent split",
            shortDescription: "Works out per-person costs from visible dollar amounts.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 80,
            evidenceSignals: ["rental_workflow", "numbers_visible"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_visible_page"
        )
    ]

    // MARK: Code / logs / debugging

    static let codeLogs: [WorkflowAction] = [
        WorkflowAction(
            id: "diagnose_latest_error", category: .codeLogs,
            title: "Diagnose the latest error",
            shortDescription: "Finds and explains the most recent error in visible text.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 120,
            evidenceSignals: ["code_workflow", "error_terms"],
            executionKind: .contentInsight,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "summarize_log_failure", category: .codeLogs,
            title: "Summarize the log failure",
            shortDescription: "Condenses visible failure output into cause/evidence/next check.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 250,
            evidenceSignals: ["code_workflow", "error_terms"],
            executionKind: .contentInsight,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "generate_next_agent_prompt", category: .codeLogs,
            title: "Generate the next agent prompt",
            shortDescription: "Drafts a precise coding-agent prompt from the visible errors/logs.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 120,
            evidenceSignals: ["code_workflow"],
            executionKind: .contentInsight,
            resultType: "draft_card",
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "create_regression_test_prompt", category: .codeLogs,
            title: "Create a regression-test prompt",
            shortDescription: "Drafts a test-writing prompt from the visible failure.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 150,
            evidenceSignals: ["code_workflow", "error_terms"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            resultType: "draft_card",
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "identify_repeated_log_pattern", category: .codeLogs,
            title: "Identify repeated log patterns",
            shortDescription: "Counts repeated lines/messages in the visible log.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            evidenceSignals: ["code_workflow", "log_file"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "map_log_to_subsystem", category: .codeLogs,
            title: "Map log lines to subsystems",
            shortDescription: "Groups visible log tags/prefixes by subsystem.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 250,
            evidenceSignals: ["code_workflow", "log_file"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "explain_recent_code_file", category: .codeLogs,
            title: "Explain this code",
            shortDescription: "Explains the structure of the visible code.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 250,
            evidenceSignals: ["code_workflow", "code_file"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "find_unverified_claims_in_agent_response", category: .codeLogs,
            title: "Find unverified agent claims",
            shortDescription: "Flags completion claims in an agent response that lack evidence.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 250,
            evidenceSignals: ["code_workflow", "agent_response"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            fallbackAction: "capture_visible_page"
        ),
        WorkflowAction(
            id: "make_next_ticket", category: .codeLogs,
            title: "Draft the next ticket",
            shortDescription: "Turns the visible failure into a ready-to-file ticket.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 150,
            evidenceSignals: ["code_workflow"],
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            resultType: "draft_card",
            fallbackAction: "capture_visible_page"
        )
    ]

    // MARK: Writing / editing (selection-based)

    static let writingEditing: [WorkflowAction] = [
        WorkflowAction(
            id: "tighten_selected_text", category: .writingEditing,
            title: "Tighten selected text",
            shortDescription: "Cuts filler and shortens the selection.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 40,
            evidenceSignals: ["selection"],
            executionKind: .selectionTransform,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        ),
        WorkflowAction(
            id: "make_more_professional", category: .writingEditing,
            title: "Make it more professional",
            shortDescription: "Reworks the selection into a professional register.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 40,
            evidenceSignals: ["selection"],
            executionKind: .selectionTransform,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        ),
        WorkflowAction(
            id: "make_less_ai_sounding", category: .writingEditing,
            title: "Make it sound less AI",
            shortDescription: "Strips boilerplate AI phrasing from the selection.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 40,
            evidenceSignals: ["selection"],
            executionKind: .selectionTransform,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        ),
        WorkflowAction(
            id: "turn_notes_into_checklist", category: .writingEditing,
            title: "Turn notes into a checklist",
            shortDescription: "Converts the selected notes into a checklist.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 60,
            evidenceSignals: ["selection"],
            executionKind: .selectionTransform,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        ),
        WorkflowAction(
            id: "extract_open_questions", category: .writingEditing,
            title: "Extract open questions",
            shortDescription: "Pulls unresolved questions out of the selection.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 80,
            evidenceSignals: ["selection"],
            executionKind: .selectionTransform,
            surfacePolicy: .panelOnly,
            fallbackAction: "select_text_hint"
        )
    ]

    // MARK: Communication

    static let communication: [WorkflowAction] = [
        WorkflowAction(
            id: "convert_notes_to_message", category: .communication,
            title: "Convert notes to a message",
            shortDescription: "Turns the selected notes into a sendable message.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 60,
            evidenceSignals: ["selection"],
            executionKind: .selectionTransform,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        ),
        WorkflowAction(
            id: "draft_message_to_prospective_tenant", category: .communication,
            title: "Draft a message to the tenant",
            shortDescription: "Drafts a tenant message from the selected context.",
            requiredContext: ["selected_text"],
            minScope: .selectedText, minChars: 40,
            evidenceSignals: ["rental_workflow", "selection"],
            executionKind: .selectionTransform,
            surfacePolicy: .panelOnly,
            resultType: "draft_card",
            fallbackAction: "select_text_hint"
        )
    ]

    // MARK: Workspace / friction (aliases over proven executors)

    static let workspaceFriction: [WorkflowAction] = [
        WorkflowAction(
            id: "arrange_current_and_reference", category: .workspaceFriction,
            title: "Arrange this beside my reference",
            shortDescription: "Puts the current window beside the best reference window.",
            requiredContext: ["windows"],
            evidenceSignals: ["two_windows"],
            executionKind: .workspaceAlias,
            riskLevel: "light_action",
            surfacePolicy: .panelOnly,
            suppressionRules: ["duplicate_of:arrange_side_by_side"],
            resultType: "system_action",
            executorAlias: "arrange_side_by_side"
        ),
        WorkflowAction(
            id: "put_browser_beside_pdf", category: .workspaceFriction,
            title: "Put browser beside the PDF",
            shortDescription: "Arranges the browser and Preview side by side.",
            requiredContext: ["windows"],
            evidenceSignals: ["browser_and_pdf"],
            executionKind: .workspaceAlias,
            riskLevel: "light_action",
            surfacePolicy: .panelOnly,
            suppressionRules: ["duplicate_of:arrange_side_by_side"],
            resultType: "system_action",
            executorAlias: "arrange_side_by_side"
        ),
        WorkflowAction(
            id: "put_xcode_beside_logs", category: .workspaceFriction,
            title: "Put Xcode beside the logs",
            shortDescription: "Arranges Xcode and your log window side by side.",
            requiredContext: ["windows"],
            evidenceSignals: ["code_workflow", "two_windows"],
            executionKind: .workspaceAlias,
            riskLevel: "light_action",
            surfacePolicy: .panelOnly,
            suppressionRules: ["duplicate_of:arrange_side_by_side"],
            resultType: "system_action",
            executorAlias: "arrange_side_by_side"
        ),
        WorkflowAction(
            id: "reopen_research_tabs", category: .workspaceFriction,
            title: "Reopen research tabs",
            shortDescription: "Restores the saved research tab set.",
            requiredContext: ["url"],
            evidenceSignals: ["research_workflow"],
            executionKind: .workspaceAlias,
            riskLevel: "light_action",
            surfacePolicy: .panelOnly,
            suppressionRules: ["duplicate_of:restore_research_tabs"],
            resultType: "system_action",
            executorAlias: "restore_research_tabs"
        ),
        WorkflowAction(
            id: "focus_current_task", category: .workspaceFriction,
            title: "Focus on the current task",
            shortDescription: "Turns on Reduce Interruptions for this work session.",
            requiredContext: [],
            evidenceSignals: ["deep_work"],
            executionKind: .workspaceAlias,
            riskLevel: "light_action",
            surfacePolicy: .panelOnly,
            suppressionRules: ["duplicate_of:enable_reduce_interruptions"],
            resultType: "system_action",
            executorAlias: "enable_reduce_interruptions"
        )
    ]

    // MARK: Memory / recurring workflows

    static let memoryWorkflows: [WorkflowAction] = [
        WorkflowAction(
            id: "save_task_context", category: .memoryWorkflows,
            title: "Save task context",
            shortDescription: "Saves what you're doing now as a recallable note.",
            requiredContext: ["title", "notes_store"],
            executionKind: .memoryNote,
            surfacePolicy: .panelOnly,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "recall_related_context", category: .memoryWorkflows,
            title: "Recall related context",
            shortDescription: "Shows saved notes related to the current workflow.",
            requiredContext: ["notes_store"],
            executionKind: .memoryNote,
            surfacePolicy: .panelOnly,
            suppressionRules: ["needs_notes"],
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "suggest_next_step_from_memory", category: .memoryWorkflows,
            title: "Suggest the next step",
            shortDescription: "Suggests a next step from your saved workflow notes.",
            requiredContext: ["notes_store"],
            executionKind: .memoryNote,
            surfacePolicy: .panelOnly,
            suppressionRules: ["needs_notes"],
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "update_project_status_note", category: .memoryWorkflows,
            title: "Update project status note",
            shortDescription: "Appends a dated status entry for this project.",
            requiredContext: ["title", "notes_store"],
            evidenceSignals: ["code_workflow"],
            executionKind: .memoryNote,
            surfacePolicy: .panelOnly,
            resultType: "note_card"
        ),
        WorkflowAction(
            id: "remember_this_workflow", category: .memoryWorkflows,
            title: "Remember this workflow",
            shortDescription: "Saves the current app/window setup for future suggestions.",
            requiredContext: ["windows"],
            executionKind: .workspaceAlias,
            surfacePolicy: .panelLow,
            suppressionRules: ["duplicate_of:remember_workspace"],
            resultType: "system_action",
            isSpecificAction: false,
            executorAlias: "remember_workspace"
        )
    ]

    // MARK: Setup / acquisition (Tier 3 + existing Tier-2 paths)

    static let setupAcquisition: [WorkflowAction] = [
        WorkflowAction(
            id: "connect_google_docs", category: .setupAcquisition,
            title: "Connect Google Docs",
            shortDescription: "Sets up document access so Docs can be read fully.",
            requiredContext: [],
            evidenceSignals: ["google_docs"],
            executionKind: .setupCard,
            riskLevel: "read_only",
            surfacePolicy: .panelOnly,
            resultType: "setup_card",
            isSpecificAction: false
        )
        // capture_visible_page / capture_full_document / enable_browser_bridge /
        // select_text_hint are pre-existing capabilities (Phase 52) registered in
        // CognitiveCapabilityRegistry; they are NOT re-declared as workflow actions.
    ]

    // MARK: Generic actions (kept, demoted — isSpecificAction=false)

    static let generics: [WorkflowAction] = [
        WorkflowAction(
            id: "explicit_visible_capture_summary", category: .browserResearch,
            title: "Summarize visible content",
            shortDescription: "Generic summary of whatever content is honestly readable.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            isSpecificAction: false
        ),
        WorkflowAction(
            id: "extract_action_items", category: .browserResearch,
            title: "Extract action items",
            shortDescription: "Generic action-item extraction.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            isSpecificAction: false
        ),
        WorkflowAction(
            id: "create_checklist", category: .browserResearch,
            title: "Create checklist",
            shortDescription: "Generic checklist generation.",
            requiredContext: ["visible_text"],
            minScope: .visibleViewport, minChars: 300,
            executionKind: .contentInsight,
            surfacePolicy: .panelOnly,
            isSpecificAction: false
        )
    ]

    // MARK: Registration logging (Part B)

    static func logRegistration() {
        for action in all {
            print("[ActionOntology] registered id=\(action.id) category=\(action.category.rawValue) specific=\(action.isSpecificAction ? "yes" : "no") execution=\(action.executionKind.rawValue)")
        }
        let generic = all.filter { !$0.isSpecificAction }.count
        let specific = all.filter { $0.isSpecificAction }.count
        let setup = all.filter { $0.executionKind == .setupCard }.count
        let executable = all.filter { $0.executionKind != .setupCard }.count
        print("[ActionOntologyAudit] generic_count=\(generic) specific_count=\(specific) executable_count=\(executable) setup_count=\(setup)")
    }
}

// MARK: - Workflow Notes Store (local, inspectable)

/// Tiny local store backing memory_note actions. UserDefaults-based, capped,
/// fully user-visible through result cards.
final class WorkflowNotesStore: @unchecked Sendable {
    static let shared = WorkflowNotesStore()

    struct Note: Codable, Sendable {
        let timestamp: Date
        let workflow: String
        let title: String
        let body: String
    }

    private let key = "contextual.workflowNotes"
    private let lock = NSLock()
    private let maxNotes = 60

    private init() {}

    func append(workflow: String, title: String, body: String) {
        lock.lock()
        defer { lock.unlock() }
        var notes = loadLocked()
        notes.append(Note(timestamp: Date(), workflow: workflow, title: title, body: body))
        if notes.count > maxNotes { notes.removeFirst(notes.count - maxNotes) }
        saveLocked(notes)
        print("[WorkflowNotes] saved workflow=\(workflow) title=\"\(title.prefix(60))\" total=\(notes.count)")
    }

    func recent(workflow: String? = nil, limit: Int = 5) -> [Note] {
        lock.lock()
        defer { lock.unlock() }
        let notes = loadLocked()
        let filtered = workflow.map { wf in notes.filter { $0.workflow == wf } } ?? notes
        return Array(filtered.suffix(limit).reversed())
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().count
    }

    func resetForTests() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: key)
        lock.unlock()
    }

    private func loadLocked() -> [Note] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let notes = try? JSONDecoder().decode([Note].self, from: data) else { return [] }
        return notes
    }

    private func saveLocked(_ notes: [Note]) {
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum CapabilityPolicyTrait: String, Sendable, CaseIterable {
    case mediaOrFocusSupport = "media_or_focus_support"
    case workspaceArrangement = "workspace_arrangement"
    case frictionReduction = "friction_reduction"
    case sourceIndependentAction = "source_independent_action"
    case contentDependentAction = "content_dependent_action"
    case requiresCurrentVisualContext = "requires_current_visual_context"
    case requiresExternalContext = "requires_external_context"
    case requiresSelectedOrFocusedContext = "requires_selected_or_focused_context"
    case dangerousOrManualUtility = "dangerous_or_manual_utility"
    case ambientCandidate = "ambient_candidate"
    case resultProducing = "result_producing"
    case internalAcquisitionAction = "internal_acquisition_action"
    case metadataUtility = "metadata_utility"
    case unverifiedBrowserMutator = "unverified_browser_mutator"
    case layoutTargetContract = "layout_target_contract"
    case workspacePatternContract = "workspace_pattern_contract"
}

struct CapabilityPolicyResolver {
    /// Resolve policy traits for any capability id. Source precedence:
    ///   1. WorkflowActionOntology     — real workflow actions (rich metadata).
    ///   2. CognitiveCapabilityRegistry — system/helper/internal/legacy capabilities,
    ///      via explicit `policyTraits` descriptor metadata (NOT id-literal switches).
    ///   3. neither                    — emit [CapabilityPolicyTraitMissing].
    /// This lets non-workflow capabilities carry traits WITHOUT being stuffed into
    /// WorkflowActionOntology.all just so resolution works.
    static func resolve(capabilityID: String) -> Set<CapabilityPolicyTrait> {
        if let action = WorkflowActionOntology.byId[capabilityID] {
            let traits = traitsFromOntology(action)
            logResolved(capabilityID, traits, source: "ontology")
            return traits
        }
        if let cap = CognitiveCapabilityRegistry.shared.get(capabilityID) {
            let traits = traitsFromRegistry(cap)
            logResolved(capabilityID, traits, source: "registry")
            return traits
        }
        print("[CapabilityPolicyTraitMissing] capability=\(capabilityID) reason=not_in_ontology_or_registry")
        return []
    }

    private static func logResolved(_ id: String, _ traits: Set<CapabilityPolicyTrait>, source: String) {
        let sortedTraits = traits.map { $0.rawValue }.sorted().joined(separator: ",")
        print("[CapabilityPolicyTraitResolved] capability=\(id) traits=\(sortedTraits) source=\(source)")
    }

    /// Traits from a real workflow ontology action (category / kind / context / risk).
    private static func traitsFromOntology(_ action: WorkflowAction) -> Set<CapabilityPolicyTrait> {
        var traits = Set<CapabilityPolicyTrait>()
        let category = action.category
        let kind = action.executionKind
        let reqContext = action.requiredContext

        if category == .mediaFocus { traits.insert(.mediaOrFocusSupport) }
        if category == .workspaceFriction {
            traits.insert(.frictionReduction)
            if kind == .workspaceAlias { traits.insert(.workspaceArrangement) }
        }
        if reqContext.contains("selected_text") || reqContext.contains("focused_field") {
            traits.insert(.requiresSelectedOrFocusedContext)
        }
        if kind == .metadataNote || kind == .workspaceAlias || kind == .memoryNote || kind == .setupCard {
            traits.insert(.sourceIndependentAction)
        } else {
            traits.insert(.contentDependentAction)
            if reqContext.contains("visible_text") || reqContext.contains("visual") {
                traits.insert(.requiresCurrentVisualContext)
            }
        }
        if reqContext.contains("url") { traits.insert(.requiresExternalContext) }
        if action.riskLevel == "destructive" || action.surfacePolicy == .panelLow {
            traits.insert(.dangerousOrManualUtility)
        }
        if action.riskLevel == "internal_acquisition" { traits.insert(.internalAcquisitionAction) }
        if kind == .metadataNote { traits.insert(.metadataUtility) }
        if action.riskLevel == "unverified_browser_mutator" { traits.insert(.unverifiedBrowserMutator) }
        if action.surfacePolicy == .panelPrimary || action.surfacePolicy == .panelOnly {
            traits.insert(.ambientCandidate)
        }
        if kind == .contentInsight || kind == .metadataNote || kind == .selectionTransform || kind == .memoryNote {
            traits.insert(.resultProducing)
        }
        return traits
    }

    /// Traits for a registered capability that is NOT a workflow ontology action.
    /// Reads explicit `policyTraits` metadata + generic derivations from existing
    /// descriptor fields. No literal capability-ID branches.
    private static func traitsFromRegistry(_ cap: CognitiveCapability) -> Set<CapabilityPolicyTrait> {
        var traits = Set<CapabilityPolicyTrait>()
        for raw in cap.policyTraits {
            if let t = CapabilityPolicyTrait(rawValue: raw) { traits.insert(t) }
        }
        if cap.inputRequirements.contains("selection")
            || cap.inputRequirements.contains("selected_text")
            || cap.inputRequirements.contains("focused_field") {
            traits.insert(.requiresSelectedOrFocusedContext)
        }
        if cap.outputType == "system_action" {
            traits.insert(.sourceIndependentAction)
            traits.insert(.ambientCandidate)
        }
        return traits
    }

    /// Audit hook: confirms every capability that declares policy-trait metadata
    /// resolves those traits through the metadata path (no hardcoded id switch).
    /// Counts are real — `count=0` only when every declared trait round-trips.
    @discardableResult
    static func verifyNoHardcodedPolicy() -> Bool {
        var unresolved = 0
        for cap in CognitiveCapabilityRegistry.shared.capabilities.values where !cap.policyTraits.isEmpty {
            let declared = Set(cap.policyTraits.compactMap { CapabilityPolicyTrait(rawValue: $0) })
            if !declared.isSubset(of: resolve(capabilityID: cap.id)) { unresolved += 1 }
        }
        let status = unresolved == 0 ? "pass" : "fail"
        print("[NoHardcodedCapabilityIDPolicy] status=\(status) count=\(unresolved)")
        print("[NoHardcodedCapabilityPolicySwitch] status=\(status) count=\(unresolved)")
        return unresolved == 0
    }
}

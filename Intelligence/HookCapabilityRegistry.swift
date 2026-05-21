import Foundation

// MARK: - Output type

enum HookOutputType: String, Sendable, Equatable {
	case metadata
	case text
	case bullets
	case table
	case checklist
	case comparison
	case debugReport = "debug_report"
	case noOutput = "no_output"
}

// MARK: - Permission level

enum HookPermissionLevel: String, Sendable, Equatable {
	/// No special permissions required.
	case none
	/// Requires user-granted accessibility permission.
	case accessibility
	/// Requires screen recording permission.
	case screenRecording = "screen_recording"
	/// Requires explicit user action to proceed.
	case userConfirmation = "user_confirmation"
	/// Not available — must never be executed without an explicit future bypass mechanism.
	case unavailable
}

// MARK: - Definition

/// Declarative hook/capability definition.
///
/// Hooks are allowed to be hardcoded. They are bounded building blocks that a hook composer
/// can chain into an executable plan without introducing arbitrary code execution.
struct HookCapabilityDefinition: Sendable, Equatable {
	let id: String
	let description: String
	let category: HookCategory
	let requiredContextTypes: [ContextRequirementType]
	let permission: PermissionRequirement
	let permissionLevel: HookPermissionLevel
	let outputType: HookOutputType
	let isImplemented: Bool
	let mappedPrimitive: ExecutionPrimitive?
	let safetyNotes: String
	/// Preferred next hooks (planning hint only; no execution logic).
	let commonNextHookIds: [String]
	/// Preferred previous hooks (planning hint only; no execution logic).
	let commonPrevHookIds: [String]
	/// Hooks that frequently pair well with this one (planning hint only).
	let pairsWellWithHookIds: [String]

	/// Legacy init (all new hooks use full init below)
	init(
		id: String,
		description: String,
		requiredContextTypes: [ContextRequirementType],
		permission: PermissionRequirement,
		isImplemented: Bool,
		mappedPrimitive: ExecutionPrimitive?
	) {
		self.id = id
		self.description = description
		self.category = .reasoning
		self.requiredContextTypes = requiredContextTypes
		self.permission = permission
		self.permissionLevel = permission == .none ? .none : .screenRecording
		self.outputType = .text
		self.isImplemented = isImplemented
		self.mappedPrimitive = mappedPrimitive
		self.safetyNotes = ""
		self.commonNextHookIds = []
		self.commonPrevHookIds = []
		self.pairsWellWithHookIds = []
	}

	init(
		id: String,
		description: String,
		category: HookCategory,
		requiredContextTypes: [ContextRequirementType],
		permission: PermissionRequirement,
		permissionLevel: HookPermissionLevel,
		outputType: HookOutputType,
		isImplemented: Bool,
		mappedPrimitive: ExecutionPrimitive?,
		safetyNotes: String = "",
		commonNextHookIds: [String] = [],
		commonPrevHookIds: [String] = [],
		pairsWellWithHookIds: [String] = []
	) {
		self.id = id
		self.description = description
		self.category = category
		self.requiredContextTypes = requiredContextTypes
		self.permission = permission
		self.permissionLevel = permissionLevel
		self.outputType = outputType
		self.isImplemented = isImplemented
		self.mappedPrimitive = mappedPrimitive
		self.safetyNotes = safetyNotes
		self.commonNextHookIds = commonNextHookIds
		self.commonPrevHookIds = commonPrevHookIds
		self.pairsWellWithHookIds = pairsWellWithHookIds
	}
}

// MARK: - Category

enum HookCategory: String, Sendable, Equatable {
	case observation
	case extraction
	case reasoning
	case presentation
	/// Permissioned computer control — requires explicit user approval at runtime.
	case computerControl = "computer_control"
	/// Permanently unavailable — dangerous operations blocked at registry level.
	case dangerous
}

// MARK: - Registry

struct HookCapabilityRegistry: Sendable {
	static let shared = HookCapabilityRegistry()

	let all: [HookCapabilityDefinition]
	private let byId: [String: HookCapabilityDefinition]

	init() {
		let defs = Self.buildAll()
		self.all = defs
		self.byId = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
	}

	// MARK: - Public API

	func definition(for id: String) -> HookCapabilityDefinition? { byId[id] }

	/// Comma-separated list of all implemented, non-dangerous hook IDs for prompt injection.
	func allowedIdsList() -> String {
		all
			.filter { $0.isImplemented && $0.category != .dangerous }
			.map(\.id)
			.joined(separator: ",")
	}

	func resolveNeededCapabilities(_ ids: [String]) -> (resolved: [HookCapabilityDefinition], unknown: [String]) {
		var resolved: [HookCapabilityDefinition] = []
		var unknown: [String] = []
		for id in ids {
			if let def = byId[id] {
				resolved.append(def)
			} else {
				unknown.append(id)
			}
		}
		return (resolved, unknown)
	}

	static func primitives(from capabilities: [HookCapabilityDefinition]) -> [ExecutionPrimitive] {
		var primitives: [ExecutionPrimitive] = []
		for cap in capabilities {
			if let p = cap.mappedPrimitive { primitives.append(p) }
		}
		var seen: Set<ExecutionPrimitive> = []
		let unique = primitives.filter { seen.insert($0).inserted }
		if unique.isEmpty { return [.summarizeContext] }
		return Array(unique.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan))
	}

	static func hookIds(from primitives: [ExecutionPrimitive], registry: HookCapabilityRegistry = .shared) -> [String] {
		var ids: [String] = ["observe_current_context"]
		for primitive in primitives {
			if let match = registry.all.first(where: { $0.mappedPrimitive == primitive }) {
				ids.append(match.id)
			}
		}
		ids.append("present_result")
		var seen: Set<String> = []
		return ids.filter { seen.insert($0).inserted }
	}

	// MARK: - Definitions

	private static func buildAll() -> [HookCapabilityDefinition] {
		observation() + extraction() + reasoning() + presentation() + computerControl() + dangerous()
	}

	// MARK: Observation

	private static func observation() -> [HookCapabilityDefinition] { [
		HookCapabilityDefinition(
			id: "observe_current_context",
			description: "Use current app/window/workflow metadata for planning (no sensors).",
			category: .observation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .metadata,
			isImplemented: true,
			mappedPrimitive: nil,
			safetyNotes: "Read-only metadata only."
		),
		HookCapabilityDefinition(
			id: "gather_visible_context_once",
			description: "Perform one bounded screen peek (no loops) to enrich context.",
			category: .observation,
			requiredContextTypes: [.screenCapture, .fusedVisual],
			permission: .screenRecording,
			permissionLevel: .screenRecording,
			outputType: .metadata,
			isImplemented: true,
			mappedPrimitive: nil,
			safetyNotes: "Single capture only. No continuous monitoring."
		),
		HookCapabilityDefinition(
			id: "run_ocr_once",
			description: "Perform OCR once on a bounded captured visual context.",
			category: .observation,
			requiredContextTypes: [.fusedVisual],
			permission: .screenRecording,
			permissionLevel: .screenRecording,
			outputType: .text,
			isImplemented: true,
			mappedPrimitive: nil,
			safetyNotes: "Single OCR capture only."
		),
		HookCapabilityDefinition(
			id: "describe_visible_region",
			description: "Generate a brief description of the currently visible screen region.",
			category: .observation,
			requiredContextTypes: [.screenCapture],
			permission: .screenRecording,
			permissionLevel: .screenRecording,
			outputType: .text,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Bounded single-frame description only."
		),
		HookCapabilityDefinition(
			id: "read_selected_text",
			description: "Read currently selected text from accessibility APIs.",
			category: .observation,
			requiredContextTypes: [.selectedText],
			permission: .accessibility,
			permissionLevel: .accessibility,
			outputType: .text,
			isImplemented: true,
			mappedPrimitive: nil,
			safetyNotes: "Reads only current selection. No clipboard write."
		),
		HookCapabilityDefinition(
			id: "inspect_recent_titles",
			description: "Inspect recent window titles to detect context patterns.",
			category: .observation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .metadata,
			isImplemented: true,
			mappedPrimitive: nil,
			safetyNotes: "Metadata only — titles, no content."
		),
		HookCapabilityDefinition(
			id: "inspect_window_title",
			description: "Read current window title for task classification.",
			category: .observation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .metadata,
			isImplemented: true,
			mappedPrimitive: nil,
			safetyNotes: "Metadata only."
		),
		HookCapabilityDefinition(
			id: "ask_user_for_missing_context",
			description: "Ask the user for missing context when inputs are insufficient.",
			category: .observation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "UI interaction only — no side effects."
		),
	] }

	// MARK: Extraction

	private static func extraction() -> [HookCapabilityDefinition] { [
		HookCapabilityDefinition(
			id: "extract_entities",
			description: "Extract key named items/entities from available text or OCR.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: true,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Read-only text processing."
		),
		HookCapabilityDefinition(
			id: "extract_prices",
			description: "Extract prices and monetary values from visible text.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Text parsing only. No network."
		),
		HookCapabilityDefinition(
			id: "extract_product_attributes",
			description: "Extract product names, specs, prices, ratings from text or OCR.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: true,
			mappedPrimitive: .organizeInformation,
			safetyNotes: "Read-only text processing."
		),
		HookCapabilityDefinition(
			id: "extract_specs",
			description: "Extract technical specifications from visible content.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Text parsing only."
		),
		HookCapabilityDefinition(
			id: "extract_dates",
			description: "Extract dates, times, and deadlines from visible content.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Text parsing only."
		),
		HookCapabilityDefinition(
			id: "extract_people",
			description: "Extract people, authors, or contacts from visible text.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Text parsing only."
		),
		HookCapabilityDefinition(
			id: "extract_links",
			description: "Extract URLs and links from visible content.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "No network access — URL extraction from visible text only."
		),
		HookCapabilityDefinition(
			id: "extract_error_messages",
			description: "Extract error messages, exceptions, and failure text.",
			category: .extraction,
			requiredContextTypes: [.textSnippet, .errorContext],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: true,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Read-only text analysis."
		),
		HookCapabilityDefinition(
			id: "extract_code_symbols",
			description: "Extract function names, class names, and symbols from code context.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Read-only text analysis."
		),
		HookCapabilityDefinition(
			id: "extract_tasks",
			description: "Extract action items, tasks, and to-dos from visible content.",
			category: .extraction,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .checklist,
			isImplemented: true,
			mappedPrimitive: .extractActionItems,
			safetyNotes: "Read-only text analysis."
		),
	] }

	// MARK: Reasoning

	private static func reasoning() -> [HookCapabilityDefinition] { [
		HookCapabilityDefinition(
			id: "compare_items",
			description: "Compare two or more candidate contexts and return differences.",
			category: .reasoning,
			requiredContextTypes: [.multiSource],
			permission: .none,
			permissionLevel: .none,
			outputType: .comparison,
			isImplemented: true,
			mappedPrimitive: .compareContexts,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "rank_options",
			description: "Rank a set of visible options by stated criteria.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .organizeInformation,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "summarize_context",
			description: "Summarize the available context into a compact output.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .text,
			isImplemented: true,
			mappedPrimitive: .summarizeContext,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "synthesize_research_takeaways",
			description: "Synthesize takeaways, questions, or checklist from research-like context.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: true,
			mappedPrimitive: .synthesizeResearchSummary,
			safetyNotes: "In-memory synthesis only."
		),
		HookCapabilityDefinition(
			id: "structure_key_points",
			description: "Structure visible information into bullets, sections, or notes.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: true,
			mappedPrimitive: .structureNotes,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "generate_checklist",
			description: "Generate a bounded checklist of next steps from context.",
			category: .reasoning,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .checklist,
			isImplemented: true,
			mappedPrimitive: .generateChecklist,
			safetyNotes: "In-memory generation only."
		),
		HookCapabilityDefinition(
			id: "explain_visible_error",
			description: "Explain or diagnose a visible error, exception, or log snippet.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet, .errorContext],
			permission: .none,
			permissionLevel: .none,
			outputType: .debugReport,
			isImplemented: true,
			mappedPrimitive: .explainError,
			safetyNotes: "Read-only analysis."
		),
		HookCapabilityDefinition(
			id: "inspect_stacktrace",
			description: "Parse and summarize a stack trace or crash log.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet, .errorContext],
			permission: .none,
			permissionLevel: .none,
			outputType: .debugReport,
			isImplemented: false,
			mappedPrimitive: .explainError,
			safetyNotes: "Read-only analysis."
		),
		HookCapabilityDefinition(
			id: "identify_missing_information",
			description: "Identify what information is missing to complete the visible task.",
			category: .reasoning,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: .classifyWorkflow,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "map_arguments",
			description: "Map and contrast arguments or positions visible in content.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .comparison,
			isImplemented: false,
			mappedPrimitive: .compareContexts,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "create_decision_matrix",
			description: "Create a decision matrix from visible options and criteria.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .table,
			isImplemented: false,
			mappedPrimitive: .organizeInformation,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "classify_workflow",
			description: "Classify the current workflow at a high level.",
			category: .reasoning,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .metadata,
			isImplemented: true,
			mappedPrimitive: .classifyWorkflow,
			safetyNotes: "Metadata classification only."
		),
		HookCapabilityDefinition(
			id: "answer_from_context",
			description: "Answer a question from the available bounded context.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .text,
			isImplemented: true,
			mappedPrimitive: .answerFromContext,
			safetyNotes: "In-memory reasoning only."
		),
		HookCapabilityDefinition(
			id: "generate_study_notes",
			description: "Generate study notes or flashcard-ready content from visible material.",
			category: .reasoning,
			requiredContextTypes: [.textSnippet],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: true,
			mappedPrimitive: .generateStudyNotes,
			safetyNotes: "In-memory generation only."
		),
	] }

	// MARK: Presentation

	private static func presentation() -> [HookCapabilityDefinition] { [
		HookCapabilityDefinition(
			id: "present_result",
			description: "Present the structured result in the panel.",
			category: .presentation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .noOutput,
			isImplemented: true,
			mappedPrimitive: nil,
			safetyNotes: "UI display only."
		),
		HookCapabilityDefinition(
			id: "present_bullets",
			description: "Present a bullet-point list result in the panel.",
			category: .presentation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .bullets,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "UI display only."
		),
		HookCapabilityDefinition(
			id: "present_table",
			description: "Present a structured table result in the panel.",
			category: .presentation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .table,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "UI display only."
		),
		HookCapabilityDefinition(
			id: "present_comparison",
			description: "Present a side-by-side comparison result in the panel.",
			category: .presentation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .comparison,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "UI display only."
		),
		HookCapabilityDefinition(
			id: "present_checklist",
			description: "Present an interactive checklist result in the panel.",
			category: .presentation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .checklist,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "UI display only."
		),
		HookCapabilityDefinition(
			id: "present_debug_plan",
			description: "Present a structured debugging plan in the panel.",
			category: .presentation,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .none,
			outputType: .debugReport,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "UI display only."
		),
	] }

	// MARK: Computer control (permissioned)

	private static func computerControl() -> [HookCapabilityDefinition] { [
		HookCapabilityDefinition(
			id: "open_app_with_permission",
			description: "Open an application by name (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .automation,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Requires explicit user confirmation. No automatic execution."
		),
		HookCapabilityDefinition(
			id: "open_url_with_permission",
			description: "Open a URL in the default browser (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .automation,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Requires explicit user confirmation. URL must be visible in context."
		),
		HookCapabilityDefinition(
			id: "open_new_tab_with_permission",
			description: "Open a new browser tab (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .automation,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Requires explicit user confirmation."
		),
		HookCapabilityDefinition(
			id: "switch_tab_with_permission",
			description: "Switch to another open browser tab (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .accessibility,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Requires accessibility permission and user confirmation."
		),
		HookCapabilityDefinition(
			id: "click_with_permission",
			description: "Click a UI element (requires accessibility permission and user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .accessibility,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Requires accessibility permission and explicit user confirmation per click."
		),
		HookCapabilityDefinition(
			id: "type_with_permission",
			description: "Type text into the focused input (requires accessibility + user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .accessibility,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "High risk. Requires accessibility permission, explicit user review of text before typing."
		),
		HookCapabilityDefinition(
			id: "scroll_with_permission",
			description: "Scroll the current view (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .accessibility,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Requires user confirmation."
		),
		HookCapabilityDefinition(
			id: "play_pause_media_with_permission",
			description: "Toggle play/pause on the current media (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Low-risk media control. Still requires explicit user confirmation."
		),
		HookCapabilityDefinition(
			id: "search_web_with_permission",
			description: "Initiate a web search with a given query (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .automation,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Network access required. User must confirm query before execution."
		),
		HookCapabilityDefinition(
			id: "ask_siri_with_permission",
			description: "Trigger Siri with a prepared query (requires user confirmation).",
			category: .computerControl,
			requiredContextTypes: [.none],
			permission: .automation,
			permissionLevel: .userConfirmation,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "Sends query to Siri/Apple. Requires user confirmation."
		),
	] }

	// MARK: Dangerous (permanently unavailable)

	private static func dangerous() -> [HookCapabilityDefinition] { [
		HookCapabilityDefinition(
			id: "delete_files",
			description: "Delete files from the filesystem.",
			category: .dangerous,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .unavailable,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "PERMANENTLY UNAVAILABLE. File deletion is never allowed via hook composition."
		),
		HookCapabilityDefinition(
			id: "grant_permissions",
			description: "Grant system permissions.",
			category: .dangerous,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .unavailable,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "PERMANENTLY UNAVAILABLE."
		),
		HookCapabilityDefinition(
			id: "mass_file_operation",
			description: "Perform bulk file operations.",
			category: .dangerous,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .unavailable,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "PERMANENTLY UNAVAILABLE."
		),
		HookCapabilityDefinition(
			id: "send_message",
			description: "Send a message on behalf of the user.",
			category: .dangerous,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .unavailable,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "PERMANENTLY UNAVAILABLE. Message sending requires explicit Composition UI, not a hook."
		),
		HookCapabilityDefinition(
			id: "purchase_item",
			description: "Execute a purchase or financial transaction.",
			category: .dangerous,
			requiredContextTypes: [.none],
			permission: .none,
			permissionLevel: .unavailable,
			outputType: .noOutput,
			isImplemented: false,
			mappedPrimitive: nil,
			safetyNotes: "PERMANENTLY UNAVAILABLE."
		),
	] }
}

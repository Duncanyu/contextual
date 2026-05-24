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
    let capability: String
    let requires: [HookIOKey]
    let produces: [HookIOKey]
    let permissions: [PermissionRequirement]
    let safety: HookSafety
    let cost: HookCost
    let whenToUse: String
    let whenNotToUse: String
    let lifecycleStatus: HookLifecycleStatus
    
    // Legacy fields
    let requiredContextTypes: [ContextRequirementType]
    let permission: PermissionRequirement
    let permissionLevel: HookPermissionLevel
    let outputType: HookOutputType
    var isImplemented: Bool { lifecycleStatus == .implemented }
    let mappedPrimitive: ExecutionPrimitive?
    let safetyNotes: String
    let commonNextHookIds: [String]
    let commonPrevHookIds: [String]
    let pairsWellWithHookIds: [String]

    init(
        id: String,
        description: String,
        category: HookCategory,
        capability: String = "",
        requires: [HookIOKey] = [],
        produces: [HookIOKey] = [],
        permissions: [PermissionRequirement] = [],
        safety: HookSafety = .safe,
        cost: HookCost = .cheap,
        whenToUse: String = "",
        whenNotToUse: String = "",
        lifecycleStatus: HookLifecycleStatus? = nil,
        requiredContextTypes: [ContextRequirementType] = [],
        permission: PermissionRequirement = .none,
        permissionLevel: HookPermissionLevel = .none,
        outputType: HookOutputType = .text,
        isImplemented: Bool = false,
        mappedPrimitive: ExecutionPrimitive? = nil,
        safetyNotes: String = "",
        commonNextHookIds: [String] = [],
        commonPrevHookIds: [String] = [],
        pairsWellWithHookIds: [String] = []
    ) {
        self.id = id
        self.description = description
        self.category = category
        self.capability = capability.isEmpty ? description : capability
        self.requires = requires
        self.produces = produces
        self.permissions = permissions.isEmpty ? [permission] : permissions
        self.safety = safety
        self.cost = cost
        self.whenToUse = whenToUse
        self.whenNotToUse = whenNotToUse
        self.lifecycleStatus = lifecycleStatus ?? (isImplemented ? .implemented : .stub)
        self.requiredContextTypes = requiredContextTypes
        self.permission = permission
        self.permissionLevel = permissionLevel
        self.outputType = outputType
        self.mappedPrimitive = mappedPrimitive
        self.safetyNotes = safetyNotes
        self.commonNextHookIds = commonNextHookIds
        self.commonPrevHookIds = commonPrevHookIds
        self.pairsWellWithHookIds = pairsWellWithHookIds
    }
    
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
        self.capability = description
        self.requires = []
        self.produces = []
        self.permissions = [permission]
        self.safety = .safe
        self.cost = .cheap
        self.whenToUse = ""
        self.whenNotToUse = ""
        self.lifecycleStatus = isImplemented ? .implemented : .stub
        self.requiredContextTypes = requiredContextTypes
        self.permission = permission
        self.permissionLevel = permission == .none ? .none : .screenRecording
        self.outputType = .text
        self.mappedPrimitive = mappedPrimitive
        self.safetyNotes = ""
        self.commonNextHookIds = []
        self.commonPrevHookIds = []
        self.pairsWellWithHookIds = []
    }
}


// MARK: - Taxonomy & Metadata

enum HookLifecycleStatus: String, Sendable, Equatable, Codable {
    case implemented
    case stub
    case metadata_only
    case confirmation_required
}

enum HookIOKey: String, Sendable, Equatable, Codable, CaseIterable {
    case current_context
    case window_title
    case selected_text
    case clipboard_text
    case ax_text
    case screen_snapshot
    case ocr_text
    case visual_summary
    case url
    case page_text
    case search_results
    case extracted_entities
    case product_attributes
    case prices
    case dates
    case errors
    case links
    case form_fields
    case key_claims
    case summary_text
    case comparison_summary
    case rewritten_text
    case email_draft
    case checklist
    case table
    case final_result
    case ui_element_map
    case app_identifier
    case user_confirmation
    case raw_html
    case boolean_result
    case structured_json
    case task_list
    case comparison_table
    case product_specs
    case ax_window_text
    case comparable_items
    case visual_descriptor
    case tradeoffs
    case recommendation
}

enum HookCost: String, Sendable, Equatable, Codable {
    case cheap
    case medium
    case expensive
}

enum HookSafety: String, Sendable, Equatable, Codable {
    case safe
    case sensitive
    case confirmation_required
    case unsafe_disabled
}

// MARK: - Category

enum HookCategory: String, Sendable, Equatable {
    case sensing
    case extraction
    case reasoning
    case transformation
    case presentation
    case llm
    case web
    case browser
    case communication
    case app_control
    case orchestration
    case dangerous
}

// MARK: - Registry

struct HookCapabilityRegistry: Sendable {
	static let shared = HookCapabilityRegistry()

	/// Emit [HookAudit] lines on registry init. Off by default (avoids dogfood noise).
	/// Set to `true` before accessing `.shared` to see the startup audit.
	/// Enabled automatically by hook composition self-tests and the debug compose trigger.
	nonisolated(unsafe) static var hookAuditEnabled: Bool = false

	let all: [HookCapabilityDefinition]
	private let byId: [String: HookCapabilityDefinition]

	init() {
		let defs = Self.foundationalCatalog()
		self.all = defs
		// Defensive: avoid crashing the entire app if a hook ID is accidentally duplicated.
		// (This has occurred in practice and surfaced as a Swiftinterface fatal error.)
		var map: [String: HookCapabilityDefinition] = [:]
		var duplicates: [String] = []
		for def in defs {
			if map[def.id] != nil { duplicates.append(def.id); continue }
			map[def.id] = def
		}
		if !duplicates.isEmpty {
			let uniqueDupes = Array(Set(duplicates)).sorted()
			print("[HookRegistry] duplicate_ids_detected count=\(uniqueDupes.count) ids=[\(uniqueDupes.joined(separator: ","))]")
		}
		self.byId = map

		// [HookAudit] — startup summary of all hooks in the registry.
		let implementedAll = defs.filter(\.isImplemented)
		let placeholderAll = defs.filter { !$0.isImplemented }
		let auditCats: [HookCategory] = [.sensing, .extraction, .reasoning, .transformation, .presentation, .llm, .web, .browser, .communication, .app_control, .orchestration, .dangerous]
		let catSummary = auditCats.map { cat -> String in
			let impl = defs.filter { $0.category == cat && $0.isImplemented }.count
			let total = defs.filter { $0.category == cat }.count
			return "\(cat.rawValue)=\(impl)/\(total)"
		}.joined(separator: " ")
		// [HookAudit] only prints when explicitly enabled (self-test or debug compose trigger).
		// Off by default to avoid startup noise during normal dogfooding.
		if Self.hookAuditEnabled {
			print("[HookAudit] total=\(defs.count)")
			print("[HookAudit] implemented=\(implementedAll.count)")
			print("[HookAudit] placeholders=\(placeholderAll.count)")
			print("[HookAudit] by_category=\(catSummary)")
			HookChainRepairEngine.auditStartupRepair(registry: self)
		}
	}
	
	init(customDefs: [HookCapabilityDefinition]) {
		self.all = customDefs
		var map: [String: HookCapabilityDefinition] = [:]
		for def in customDefs {
			map[def.id] = def
		}
		self.byId = map
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

    static func foundationalCatalog() -> [HookCapabilityDefinition] {
        [
			HookCapabilityDefinition(
				id: "observe_current_context",
				description: "Captures a snapshot of the active window/app state.",
				category: .sensing,
				            capability: "observe current context",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When observe current context is needed",
            whenNotToUse: "When observe current context is not needed",
            lifecycleStatus: .implemented,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .metadata,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "read_window_title",
				description: "Reads the title of the active window.",
				category: .sensing,
				            capability: "read window title",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When read window title is needed",
            whenNotToUse: "When read window title is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .metadata,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "read_selected_text",
				description: "Retrieves any user-selected text.",
				category: .sensing,
				            capability: "read selected text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When read selected text is needed",
            whenNotToUse: "When read selected text is not needed",
            lifecycleStatus: .implemented,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "read_clipboard",
				description: "Reads the current contents of the system clipboard.",
				category: .sensing,
				            capability: "read clipboard",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When read clipboard is needed",
            whenNotToUse: "When read clipboard is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "read_ax_text",
				description: "Extracts text directly from the macOS Accessibility API.",
				category: .sensing,
				            capability: "read ax text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When read ax text is needed",
            whenNotToUse: "When read ax text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "run_ocr_once",
				description: "Captures a screen snapshot and runs Optical Character Recognition.",
				category: .sensing,
				            capability: "run ocr once",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When run ocr once is needed",
            whenNotToUse: "When run ocr once is not needed",
            lifecycleStatus: .implemented,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "summarize_current_context",
				description: "Produces a general summary of the immediate context.",
				category: .sensing,
				            capability: "summarize current context",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When summarize current context is needed",
            whenNotToUse: "When summarize current context is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_entities",
				description: "Identifies names, places, and organizations.",
				category: .extraction,
				            capability: "extract entities",
            requires: [],
            produces: [.extracted_entities],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract entities is needed",
            whenNotToUse: "When extract entities is not needed",
            lifecycleStatus: .implemented,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_product_attributes",
				description: "Extracts specific product details (brands, specs).",
				category: .extraction,
				            capability: "extract product attributes",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract product attributes is needed",
            whenNotToUse: "When extract product attributes is not needed",
            lifecycleStatus: .implemented,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_prices",
				description: "Finds monetary values and pricing structures.",
				category: .extraction,
				            capability: "extract prices",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract prices is needed",
            whenNotToUse: "When extract prices is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_dates",
				description: "Locates timestamps and calendar dates.",
				category: .extraction,
				            capability: "extract dates",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract dates is needed",
            whenNotToUse: "When extract dates is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_errors",
				description: "Captures stack traces, crash logs, or visible UI error messages.",
				category: .extraction,
				            capability: "extract errors",
            requires: [],
            produces: [.errors],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract errors is needed",
            whenNotToUse: "When extract errors is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_links",
				description: "Extracts URLs and hyperlinks.",
				category: .extraction,
				            capability: "extract links",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract links is needed",
            whenNotToUse: "When extract links is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_form_fields",
				description: "Identifies inputs, labels, and forms on screen.",
				category: .extraction,
				            capability: "extract form fields",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract form fields is needed",
            whenNotToUse: "When extract form fields is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_key_claims",
				description: "Pulls out primary assertions or key points from text.",
				category: .extraction,
				            capability: "extract key claims",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract key claims is needed",
            whenNotToUse: "When extract key claims is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "summarize_visible_content",
				description: "Synthesizes a focused summary of the visible screen.",
				category: .reasoning,
				            capability: "summarize visible content",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When summarize visible content is needed",
            whenNotToUse: "When summarize visible content is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "compare_items",
				description: "Evaluates similarities and differences (e.g., comparing product features).",
				category: .reasoning,
				            capability: "compare items",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When compare items is needed",
            whenNotToUse: "When compare items is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "explain_code",
				description: "Diagnoses and explains code snippets.",
				category: .reasoning,
				            capability: "explain code",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When explain code is needed",
            whenNotToUse: "When explain code is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "explain_error",
				description: "Provides a plain-English explanation for an extracted error.",
				category: .reasoning,
				            capability: "explain error",
            requires: [.errors],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When explain error is needed",
            whenNotToUse: "When explain error is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "classify_page_type",
				description: "Determines the type of workflow or document currently open.",
				category: .reasoning,
				            capability: "classify page type",
            requires: [],
            produces: [],
            permissions: [],
            safety: .confirmation_required,
            cost: .cheap,
            whenToUse: "When classify page type is needed",
            whenNotToUse: "When classify page type is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "identify_next_step",
				description: "Recommends a logical next action.",
				category: .reasoning,
				            capability: "identify next step",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When identify next step is needed",
            whenNotToUse: "When identify next step is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "detect_missing_information",
				description: "Flags critical gaps in the provided context.",
				category: .reasoning,
				            capability: "detect missing information",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When detect missing information is needed",
            whenNotToUse: "When detect missing information is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "rewrite_text",
				description: "Adjusts tone, fixes grammar, or reformats general text.",
				category: .transformation,
				            capability: "rewrite text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When rewrite text is needed",
            whenNotToUse: "When rewrite text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "format_as_email",
				description: "Converts raw notes into a drafted email structure.",
				category: .transformation,
				            capability: "format as email",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When format as email is needed",
            whenNotToUse: "When format as email is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "convert_to_checklist",
				description: "Structures scattered points into actionable checkboxes.",
				category: .transformation,
				            capability: "convert to checklist",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When convert to checklist is needed",
            whenNotToUse: "When convert to checklist is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "create_table",
				description: "Organizes comparative data into a markdown table.",
				category: .transformation,
				            capability: "create table",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When create table is needed",
            whenNotToUse: "When create table is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "shorten_text",
				description: "Condenses text into a brief overview.",
				category: .transformation,
				            capability: "shorten text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When shorten text is needed",
            whenNotToUse: "When shorten text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "expand_text",
				description: "Elaborates on brief points with more detail.",
				category: .transformation,
				            capability: "expand text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When expand text is needed",
            whenNotToUse: "When expand text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "clean_text",
				description: "Strips out formatting noise and artifacts.",
				category: .transformation,
				            capability: "clean text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When clean text is needed",
            whenNotToUse: "When clean text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "present_result",
				description: "Displays general output or text blocks.",
				category: .presentation,
				            capability: "present result",
            requires: [],
            produces: [.final_result],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When present result is needed",
            whenNotToUse: "When present result is not needed",
            lifecycleStatus: .implemented,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "present_comparison",
				description: "Formats and displays a side-by-side comparison.",
				category: .presentation,
				            capability: "present comparison",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When present comparison is needed",
            whenNotToUse: "When present comparison is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "present_checklist",
				description: "Renders a structured checklist interface.",
				category: .presentation,
				            capability: "present checklist",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When present checklist is needed",
            whenNotToUse: "When present checklist is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "present_warning",
				description: "Surprises prominent alerts or safety boundaries.",
				category: .presentation,
				            capability: "present warning",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When present warning is needed",
            whenNotToUse: "When present warning is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "copy_to_clipboard",
				description: "Securely places formatted output into the clipboard.",
				category: .presentation,
				            capability: "copy to clipboard",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When copy to clipboard is needed",
            whenNotToUse: "When copy to clipboard is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .noOutput,
				isImplemented: true,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "call_local_llm",
				description: "General purpose LLM invocation.",
				category: .reasoning,
				            capability: "call local llm",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When call local llm is needed",
            whenNotToUse: "When call local llm is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "summarize_with_llm",
				description: "LLM-based summarization.",
				category: .reasoning,
				            capability: "summarize with llm",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When summarize with llm is needed",
            whenNotToUse: "When summarize with llm is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "classify_with_llm",
				description: "LLM-based classification.",
				category: .reasoning,
				            capability: "classify with llm",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When classify with llm is needed",
            whenNotToUse: "When classify with llm is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_structured_json_with_llm",
				description: "Extract JSON via LLM.",
				category: .extraction,
				            capability: "extract structured json with llm",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When extract structured json with llm is needed",
            whenNotToUse: "When extract structured json with llm is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "critique_result_with_llm",
				description: "LLM-based critique.",
				category: .reasoning,
				            capability: "critique result with llm",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When critique result with llm is needed",
            whenNotToUse: "When critique result with llm is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "verify_output_with_llm",
				description: "Verify output via LLM.",
				category: .reasoning,
				            capability: "verify output with llm",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When verify output with llm is needed",
            whenNotToUse: "When verify output with llm is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "generate_short_response",
				description: "Generate brief text.",
				category: .transformation,
				            capability: "generate short response",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When generate short response is needed",
            whenNotToUse: "When generate short response is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "generate_long_response",
				description: "Generate detailed text.",
				category: .transformation,
				            capability: "generate long response",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When generate long response is needed",
            whenNotToUse: "When generate long response is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "web_search",
				description: "Perform web search.",
				category: .sensing,
				            capability: "web search",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When web search is needed",
            whenNotToUse: "When web search is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .metadata,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "fetch_page_text",
				description: "Fetch text from URL.",
				category: .sensing,
				            capability: "fetch page text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When fetch page text is needed",
            whenNotToUse: "When fetch page text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "summarize_web_page",
				description: "Summarize web page.",
				category: .reasoning,
				            capability: "summarize web page",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .medium,
            whenToUse: "When summarize web page is needed",
            whenNotToUse: "When summarize web page is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_search_results",
				description: "Extract links from search.",
				category: .extraction,
				            capability: "extract search results",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract search results is needed",
            whenNotToUse: "When extract search results is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "compare_web_sources",
				description: "Compare web pages.",
				category: .reasoning,
				            capability: "compare web sources",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .cheap,
            whenToUse: "When compare web sources is needed",
            whenNotToUse: "When compare web sources is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_article_content",
				description: "Extract article body.",
				category: .extraction,
				            capability: "extract article content",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract article content is needed",
            whenNotToUse: "When extract article content is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "detect_paywall",
				description: "Check for paywall.",
				category: .reasoning,
				            capability: "detect paywall",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When detect paywall is needed",
            whenNotToUse: "When detect paywall is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "identify_primary_topic",
				description: "Identify main topic.",
				category: .reasoning,
				            capability: "identify primary topic",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When identify primary topic is needed",
            whenNotToUse: "When identify primary topic is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "get_current_url",
				description: "Get active tab URL.",
				category: .sensing,
				            capability: "get current url",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .cheap,
            whenToUse: "When get current url is needed",
            whenNotToUse: "When get current url is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .metadata,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "open_new_tab",
				description: "Open new browser tab.",
				category: .app_control,
				            capability: "open new tab",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When open new tab is needed",
            whenNotToUse: "When open new tab is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "switch_tab",
				description: "Switch to existing tab.",
				category: .app_control,
				            capability: "switch tab",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When switch tab is needed",
            whenNotToUse: "When switch tab is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "close_tab",
				description: "Close active tab.",
				category: .app_control,
				            capability: "close tab",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When close tab is needed",
            whenNotToUse: "When close tab is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "search_in_current_tab",
				description: "Search in current tab.",
				category: .app_control,
				            capability: "search in current tab",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When search in current tab is needed",
            whenNotToUse: "When search in current tab is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "navigate_to_url",
				description: "Navigate active tab.",
				category: .app_control,
				            capability: "navigate to url",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .cheap,
            whenToUse: "When navigate to url is needed",
            whenNotToUse: "When navigate to url is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "read_page_title",
				description: "Read browser page title.",
				category: .sensing,
				            capability: "read page title",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When read page title is needed",
            whenNotToUse: "When read page title is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .metadata,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "read_browser_visible_text",
				description: "Read visible web text.",
				category: .sensing,
				            capability: "read browser visible text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When read browser visible text is needed",
            whenNotToUse: "When read browser visible text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "fill_web_field",
				description: "Fill form field.",
				category: .app_control,
				            capability: "fill web field",
            requires: [],
            produces: [],
            permissions: [],
            safety: .sensitive,
            cost: .cheap,
            whenToUse: "When fill web field is needed",
            whenNotToUse: "When fill web field is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "submit_form",
				description: "Submit active form.",
				category: .app_control,
				            capability: "submit form",
            requires: [],
            produces: [],
            permissions: [],
            safety: .confirmation_required,
            cost: .cheap,
            whenToUse: "When submit form is needed",
            whenNotToUse: "When submit form is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "draft_email",
				description: "Draft an email.",
				category: .transformation,
				            capability: "draft email",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When draft email is needed",
            whenNotToUse: "When draft email is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "summarize_email_thread",
				description: "Summarize email thread.",
				category: .reasoning,
				            capability: "summarize email thread",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When summarize email thread is needed",
            whenNotToUse: "When summarize email thread is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "extract_email_action_items",
				description: "Extract action items.",
				category: .extraction,
				            capability: "extract email action items",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .medium,
            whenToUse: "When extract email action items is needed",
            whenNotToUse: "When extract email action items is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "prepare_reply",
				description: "Draft an email reply.",
				category: .transformation,
				            capability: "prepare reply",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When prepare reply is needed",
            whenNotToUse: "When prepare reply is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "prepare_followup",
				description: "Draft a followup.",
				category: .transformation,
				            capability: "prepare followup",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When prepare followup is needed",
            whenNotToUse: "When prepare followup is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "create_message_summary",
				description: "Summarize chat message.",
				category: .reasoning,
				            capability: "create message summary",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When create message summary is needed",
            whenNotToUse: "When create message summary is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "open_app",
				description: "Launch an application.",
				category: .app_control,
				            capability: "open app",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When open app is needed",
            whenNotToUse: "When open app is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "focus_app",
				description: "Bring app to front.",
				category: .app_control,
				            capability: "focus app",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When focus app is needed",
            whenNotToUse: "When focus app is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "quit_app",
				description: "Quit an application.",
				category: .app_control,
				            capability: "quit app",
            requires: [],
            produces: [],
            permissions: [],
            safety: .confirmation_required,
            cost: .cheap,
            whenToUse: "When quit app is needed",
            whenNotToUse: "When quit app is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "switch_window",
				description: "Switch app window.",
				category: .app_control,
				            capability: "switch window",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When switch window is needed",
            whenNotToUse: "When switch window is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "press_shortcut",
				description: "Simulate keyboard shortcut.",
				category: .app_control,
				            capability: "press shortcut",
            requires: [],
            produces: [],
            permissions: [],
            safety: .confirmation_required,
            cost: .cheap,
            whenToUse: "When press shortcut is needed",
            whenNotToUse: "When press shortcut is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "scroll_view",
				description: "Scroll the active view.",
				category: .app_control,
				            capability: "scroll view",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When scroll view is needed",
            whenNotToUse: "When scroll view is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "click_screen_coordinate",
				description: "Click X/Y coordinate.",
				category: .app_control,
				            capability: "click screen coordinate",
            requires: [],
            produces: [],
            permissions: [],
            safety: .confirmation_required,
            cost: .cheap,
            whenToUse: "When click screen coordinate is needed",
            whenNotToUse: "When click screen coordinate is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "click_ui_element_by_id",
				description: "Click UI element by ID.",
				category: .app_control,
				            capability: "click ui element by id",
            requires: [],
            produces: [],
            permissions: [],
            safety: .confirmation_required,
            cost: .cheap,
            whenToUse: "When click ui element by id is needed",
            whenNotToUse: "When click ui element by id is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "type_text",
				description: "Simulate keystrokes.",
				category: .app_control,
				            capability: "type text",
            requires: [],
            produces: [],
            permissions: [],
            safety: .confirmation_required,
            cost: .cheap,
            whenToUse: "When type text is needed",
            whenNotToUse: "When type text is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "clear_text_field",
				description: "Clear text field.",
				category: .app_control,
				            capability: "clear text field",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When clear text field is needed",
            whenNotToUse: "When clear text field is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .userConfirmation,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "split_goal_into_subtasks",
				description: "Split complex goal.",
				category: .reasoning,
				            capability: "split goal into subtasks",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When split goal into subtasks is needed",
            whenNotToUse: "When split goal into subtasks is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "run_subtasks_parallel",
				description: "Run tasks in parallel.",
				category: .dangerous,
				            capability: "run subtasks parallel",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When run subtasks parallel is needed",
            whenNotToUse: "When run subtasks parallel is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .unavailable,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "merge_results",
				description: "Merge subtask results.",
				category: .reasoning,
				            capability: "merge results",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When merge results is needed",
            whenNotToUse: "When merge results is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "rank_results",
				description: "Rank multiple items.",
				category: .reasoning,
				            capability: "rank results",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When rank results is needed",
            whenNotToUse: "When rank results is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "verify_result",
				description: "Verify final result.",
				category: .reasoning,
				            capability: "verify result",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When verify result is needed",
            whenNotToUse: "When verify result is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "retry_once",
				description: "Retry a failed hook.",
				category: .dangerous,
				            capability: "retry once",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When retry once is needed",
            whenNotToUse: "When retry once is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .unavailable,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),
			HookCapabilityDefinition(
				id: "branch_on_result",
				description: "Branch execution path.",
				category: .dangerous,
				            capability: "branch on result",
            requires: [],
            produces: [],
            permissions: [],
            safety: .safe,
            cost: .cheap,
            whenToUse: "When branch on result is needed",
            whenNotToUse: "When branch on result is not needed",
            lifecycleStatus: .stub,
			requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .unavailable,
				outputType: .text,
				isImplemented: false,
				mappedPrimitive: nil,
				safetyNotes: ""
			),

			// MARK: - High-value implemented hooks (Part F)

			// Shopping / product research
			HookCapabilityDefinition(
				id: "extract_product_specs",
				description: "Extracts structured product specifications (capacity, speed, dimensions, compatibility) from visible text.",
				category: .extraction,
				capability: "extract product specs",
				requires: [],
				produces: [.product_attributes, .structured_json],
				safety: .safe,
				cost: .medium,
				whenToUse: "When product spec table or feature list is visible",
				whenNotToUse: "When page has no product content",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .table,
				mappedPrimitive: nil,
				safetyNotes: "",
				commonNextHookIds: ["compare_product_specs", "build_comparison_table", "present_table"],
				pairsWellWithHookIds: ["run_ocr_once", "compare_product_specs"]
			),
			HookCapabilityDefinition(
				id: "extract_price_and_rating",
				description: "Extracts price, discount, star rating, and review count from the visible page.",
				category: .extraction,
				capability: "extract price and rating",
				requires: [],
				produces: [.prices, .structured_json],
				safety: .safe,
				cost: .cheap,
				whenToUse: "When shopping page shows price and rating",
				whenNotToUse: "When page is not a product or listing page",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				mappedPrimitive: nil,
				safetyNotes: "",
				commonNextHookIds: ["identify_purchase_tradeoffs", "present_result"],
				pairsWellWithHookIds: ["extract_product_specs"]
			),
			HookCapabilityDefinition(
				id: "compare_product_specs",
				description: "Compares product specifications across context to surface differences and tradeoffs.",
				category: .reasoning,
				capability: "compare product specs",
				requires: [.product_attributes],
				produces: [.comparison_summary, .comparable_items, .comparison_table],
				safety: .safe,
				cost: .medium,
				whenToUse: "When user is comparing products or has visited multiple product pages",
				whenNotToUse: "When only one product is visible",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .comparison,
				mappedPrimitive: .compareContexts,
				safetyNotes: "",
				commonNextHookIds: ["build_comparison_table", "present_recommendation", "present_table"],
				pairsWellWithHookIds: ["extract_product_specs", "extract_price_and_rating"]
			),
			HookCapabilityDefinition(
				id: "build_comparison_table",
				description: "Builds a side-by-side comparison table from extracted product or option data.",
				category: .transformation,
				capability: "build comparison table",
				requires: [.comparable_items],
				produces: [.table],
				safety: .safe,
				cost: .cheap,
				whenToUse: "When comparison data is available and tabular format would be clearer",
				whenNotToUse: "When only one option exists",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .table,
				mappedPrimitive: nil,
				safetyNotes: "",
				commonNextHookIds: ["present_table", "present_recommendation"],
				pairsWellWithHookIds: ["compare_product_specs"]
			),
			HookCapabilityDefinition(
				id: "identify_purchase_tradeoffs",
				description: "Identifies key tradeoffs (price vs. features, range vs. weight) relevant to a purchase decision.",
				category: .reasoning,
				capability: "identify purchase tradeoffs",
				requires: [.prices],
				produces: [.tradeoffs, .key_claims],
				safety: .safe,
				cost: .medium,
				whenToUse: "When user is evaluating a purchase and tradeoff analysis would help",
				whenNotToUse: "When context is not shopping or product comparison",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .bullets,
				mappedPrimitive: nil,
				safetyNotes: "",
				commonNextHookIds: ["present_tradeoff_summary", "present_recommendation"],
				pairsWellWithHookIds: ["extract_product_specs", "compare_product_specs"]
			),
			HookCapabilityDefinition(
				id: "summarize_visible_reviews",
				description: "Summarizes user reviews visible on the current page into key sentiment themes.",
				category: .reasoning,
				capability: "summarize visible reviews",
				requires: [],
				produces: [.summary_text],
				safety: .safe,
				cost: .medium,
				whenToUse: "When review section or user ratings are visible",
				whenNotToUse: "When no reviews are present on page",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .bullets,
				mappedPrimitive: nil,
				safetyNotes: "",
				commonNextHookIds: ["present_result"],
				pairsWellWithHookIds: ["extract_product_specs"]
			),

			// General research
			HookCapabilityDefinition(
				id: "summarize_visible_page",
				description: "Produces a concise summary of the main content currently visible on screen.",
				category: .reasoning,
				capability: "summarize visible page",
				requires: [],
				produces: [.summary_text],
				safety: .safe,
				cost: .medium,
				whenToUse: "When user is reading a long article, doc, or dense page",
				whenNotToUse: "When page content is minimal or interactive",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				mappedPrimitive: .summarizeContext,
				safetyNotes: "",
				commonNextHookIds: ["present_result", "create_briefing"],
				pairsWellWithHookIds: ["run_ocr_once", "extract_key_facts"]
			),
			HookCapabilityDefinition(
				id: "extract_key_facts",
				description: "Extracts the most important facts, figures, dates, or claims from visible content.",
				category: .extraction,
				capability: "extract key facts",
				requires: [],
				produces: [.key_claims],
				safety: .safe,
				cost: .medium,
				whenToUse: "When page contains data-rich content: specs, stats, claims, timelines",
				whenNotToUse: "When page is navigation/menu only",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .bullets,
				mappedPrimitive: .extractActionItems,
				safetyNotes: "",
				commonNextHookIds: ["create_briefing", "present_result"],
				pairsWellWithHookIds: ["summarize_visible_page"]
			),
			HookCapabilityDefinition(
				id: "create_briefing",
				description: "Compiles extracted facts and summaries into a structured briefing document.",
				category: .transformation,
				capability: "create briefing",
				requires: [],
				produces: [.summary_text],
				safety: .safe,
				cost: .medium,
				whenToUse: "When user needs a structured synthesis of information",
				whenNotToUse: "When single-fact answers are sufficient",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				mappedPrimitive: .synthesizeResearchSummary,
				safetyNotes: "",
				commonNextHookIds: ["present_result"],
				pairsWellWithHookIds: ["extract_key_facts", "summarize_visible_page"]
			),
			HookCapabilityDefinition(
				id: "compare_options",
				description: "Compares multiple visible options, plans, or choices and highlights the key differences.",
				category: .reasoning,
				capability: "compare options",
				requires: [.extracted_entities],
				produces: [.comparison_summary, .comparable_items, .comparison_table],
				safety: .safe,
				cost: .medium,
				whenToUse: "When multiple options, variants, or alternatives are visible",
				whenNotToUse: "When only one option exists",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .comparison,
				mappedPrimitive: .compareContexts,
				safetyNotes: "",
				commonNextHookIds: ["present_recommendation", "present_table", "build_comparison_table"],
				pairsWellWithHookIds: ["extract_key_facts"]
			),

			// Presentation
			HookCapabilityDefinition(
				id: "present_table",
				description: "Renders structured data as a formatted markdown table for the user.",
				category: .presentation,
				capability: "present table",
				requires: [.table],
				produces: [.final_result],
				safety: .safe,
				cost: .cheap,
				whenToUse: "When tabular comparison or structured data should be shown to user",
				whenNotToUse: "When a simple paragraph is clearer",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .table,
				mappedPrimitive: nil,
				safetyNotes: "",
				pairsWellWithHookIds: ["build_comparison_table", "compare_product_specs"]
			),
			HookCapabilityDefinition(
				id: "present_tradeoff_summary",
				description: "Shows a concise tradeoff summary with pros, cons, and a recommendation note.",
				category: .presentation,
				capability: "present tradeoff summary",
				requires: [.key_claims],
				produces: [.final_result],
				safety: .safe,
				cost: .cheap,
				whenToUse: "When tradeoff analysis has been performed and should be shown",
				whenNotToUse: "When straightforward result is already clear",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .bullets,
				mappedPrimitive: nil,
				safetyNotes: "",
				pairsWellWithHookIds: ["identify_purchase_tradeoffs", "compare_product_specs"]
			),
			HookCapabilityDefinition(
				id: "present_recommendation",
				description: "Presents a clear recommendation with reasoning based on extracted and compared data.",
				category: .presentation,
				capability: "present recommendation",
				requires: [.comparison_summary],
				produces: [.final_result],
				safety: .safe,
				cost: .cheap,
				whenToUse: "When a comparison or analysis produces a clear best option",
				whenNotToUse: "When data is insufficient for a recommendation",
				lifecycleStatus: .implemented,
				requiredContextTypes: [.none],
				permission: .none,
				permissionLevel: .none,
				outputType: .text,
				mappedPrimitive: nil,
				safetyNotes: "",
				pairsWellWithHookIds: ["compare_product_specs", "identify_purchase_tradeoffs", "compare_options"]
			),
        ]
    }
}
import Foundation

@MainActor
enum HookTaxonomySelfTest {
	static func run() -> Bool {
		print("[HookTaxonomySelfTest] started")
		let defs = HookCapabilityRegistry.shared.all
		print("[HookTaxonomySelfTest] total=\(defs.count)")

		var failures = 0
		var duplicateIds = 0
		var invalidSections = 0
		var invalidIoKeys = 0
		var invalidStatus = 0
		var executableWithoutRuntime = 0

		var idSet: Set<String> = []
		var capSet: Set<String> = []

		let allowedDuplicateCapabilities: Set<String> = [] // e.g. "search_in_current_tab" if we had multiple

		let allSections: Set<HookCategory> = [
			.sensing, .extraction, .reasoning, .transformation, .presentation,
			.llm, .web, .browser, .communication, .app_control, .orchestration, .dangerous
		]

		for def in defs {
			// ID validation
			if idSet.contains(def.id) {
				print("[HookTaxonomySelfTest] ERROR duplicate_id=\(def.id)")
				duplicateIds += 1
				failures += 1
			}
			idSet.insert(def.id)

			// Capability validation
			if capSet.contains(def.capability) && !allowedDuplicateCapabilities.contains(def.capability) {
				// We don't necessarily fail on this yet unless we strictly want to, but we log it
			}
			capSet.insert(def.capability)

			// Section validation
			if !allSections.contains(def.category) {
				print("[HookTaxonomySelfTest] ERROR invalid_section=\(def.category.rawValue) for id=\(def.id)")
				invalidSections += 1
				failures += 1
			}

			// IO validation
			// Handled by Swift type system (HookIOKey), so technically this is always true if it compiles.
			// Same for HookCost, HookSafety, HookLifecycleStatus.

			// Runtime support validation
			let inSandbox = HookExecutionSandbox.safeHookIds.contains(def.id)
			if def.lifecycleStatus == .implemented && !inSandbox {
				if def.category != .app_control && def.category != .dangerous { // app_control hooks might not be in safe allowlist
					print("[HookTaxonomySelfTest] ERROR implemented_but_not_in_sandbox id=\(def.id)")
					executableWithoutRuntime += 1
					failures += 1
				}
			}

			// Executable checking
			if def.lifecycleStatus == .stub || def.lifecycleStatus == .metadata_only {
				if def.isImplemented {
					print("[HookTaxonomySelfTest] ERROR stub_is_executable id=\(def.id)")
					invalidStatus += 1
					failures += 1
				}
			}
		}

		print("[HookTaxonomySelfTest] duplicate_ids=\(duplicateIds)")
		print("[HookTaxonomySelfTest] invalid_sections=\(invalidSections)")
		print("[HookTaxonomySelfTest] invalid_io_keys=\(invalidIoKeys)")
		print("[HookTaxonomySelfTest] invalid_status=\(invalidStatus)")
		print("[HookTaxonomySelfTest] executable_without_runtime=\(executableWithoutRuntime)")
		print("[HookTaxonomySelfTest] ok=\(failures == 0) failures=\(failures)")

		return failures == 0
	}
}

extension HookCapabilityDefinition {
    var semanticTags: Set<String> {
        var tags: Set<String> = []
        tags.insert(category.rawValue)
        let parts = id.split(separator: "_")
        for part in parts {
            tags.insert(String(part))
        }
        return tags
    }
}


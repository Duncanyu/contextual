import re
import sys

with open('Intelligence/HookCapabilityRegistry.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add new Enums
new_enums = """
// MARK: - Taxonomy & Metadata

enum HookLifecycleStatus: String, Sendable, Equatable, Codable {
    case implemented
    case stub
    case metadata_only
    case confirmation_required
}

enum HookIOKey: String, Sendable, Equatable, Codable {
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
"""

if "enum HookLifecycleStatus" not in content:
    content = content.replace("// MARK: - Category", new_enums + "\n// MARK: - Category")

# 2. Update HookCategory
old_category = """enum HookCategory: String, Sendable, Equatable {
	case observation
	case extraction
	case reasoning
	case transformation
	case presentation
	/// Permissioned computer control — requires explicit user approval at runtime.
	case computerControl = "computer_control"
	/// Permanently unavailable — dangerous operations blocked at registry level.
	case dangerous
}"""
new_category = """enum HookCategory: String, Sendable, Equatable {
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
}"""
content = content.replace(old_category, new_category)

# 3. Update HookCapabilityDefinition struct
old_struct = """struct HookCapabilityDefinition: Sendable, Equatable {
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
	let pairsWellWithHookIds: [String]"""
new_struct = """struct HookCapabilityDefinition: Sendable, Equatable {
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
    
    // Legacy fields mapped/retained for routing compatibility
    let requiredContextTypes: [ContextRequirementType]
    let permission: PermissionRequirement
    let permissionLevel: HookPermissionLevel
    let outputType: HookOutputType
    var isImplemented: Bool { lifecycleStatus == .implemented }
    let mappedPrimitive: ExecutionPrimitive?
    let safetyNotes: String
    let commonNextHookIds: [String]
    let commonPrevHookIds: [String]
    let pairsWellWithHookIds: [String]"""
content = content.replace(old_struct, new_struct)

# 4. Update init
old_init1 = """	init(
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
	) {"""

new_init1 = """	init(
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
		lifecycleStatus: HookLifecycleStatus = .stub,
		requiredContextTypes: [ContextRequirementType] = [],
		permission: PermissionRequirement = .none,
		permissionLevel: HookPermissionLevel = .none,
		outputType: HookOutputType = .text,
		mappedPrimitive: ExecutionPrimitive? = nil,
		safetyNotes: String = "",
		commonNextHookIds: [String] = [],
		commonPrevHookIds: [String] = [],
		pairsWellWithHookIds: [String] = []
	) {"""

content = content.replace(old_init1, new_init1)

old_init1_body = """		self.id = id
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
		self.pairsWellWithHookIds = pairsWellWithHookIds"""

new_init1_body = """		self.id = id
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
		self.lifecycleStatus = lifecycleStatus
		self.requiredContextTypes = requiredContextTypes
		self.permission = permission
		self.permissionLevel = permissionLevel
		self.outputType = outputType
		self.mappedPrimitive = mappedPrimitive
		self.safetyNotes = safetyNotes
		self.commonNextHookIds = commonNextHookIds
		self.commonPrevHookIds = commonPrevHookIds
		self.pairsWellWithHookIds = pairsWellWithHookIds"""

content = content.replace(old_init1_body, new_init1_body)

# Remove old init legacy entirely or update it? We can just leave it since the new init handles it, but let's update it to map properly
old_init2 = """	init(
		id: String,
		description: String,
		requiredContextTypes: [ContextRequirementType],
		permission: PermissionRequirement,
		isImplemented: Bool,
		mappedPrimitive: ExecutionPrimitive?
	) {"""

new_init2 = """	init(
		id: String,
		description: String,
		requiredContextTypes: [ContextRequirementType],
		permission: PermissionRequirement,
		isImplemented: Bool,
		mappedPrimitive: ExecutionPrimitive?
	) {"""

# The body of legacy init needs updating
old_init2_body = """		self.id = id
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
		self.pairsWellWithHookIds = []"""

new_init2_body = """		self.id = id
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
		self.pairsWellWithHookIds = []"""

content = content.replace(old_init2_body, new_init2_body)

with open('Intelligence/HookCapabilityRegistry.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated HookCapabilityRegistry enums and definition.")

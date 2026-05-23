import re

with open('Intelligence/HookCapabilityRegistry.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Inject enums
enums = """
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

content = content.replace("// MARK: - Category", enums + "\n// MARK: - Category")

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

# 3. Update struct
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
}"""

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
}"""
content = content.replace(old_struct, new_struct)

# 4. Now, iterate over the `HookCapabilityDefinition(` calls and apply fixes to their fields!
# Since `HookCapabilityRegistry` is a Swift file, we can write a function to map categories to new ones,
# and intelligently assign fields.

def map_category(cat):
    cat = cat.replace('.observation', '.sensing')
    cat = cat.replace('.computerControl', '.app_control')
    return cat

def determine_safety(id, original_cat):
    if "web" in id or "url" in id:
        return ".sensitive"
    if "llm" in id:
        return ".sensitive"
    if "click" in id or "type" in id or "submit" in id or "quit" in id or "press" in id or "fill" in id:
        return ".confirmation_required"
    if original_cat == ".computerControl":
        return ".confirmation_required"
    return ".safe"

def determine_cost(id):
    if "llm" in id or "summarize" in id or "extract" in id or "critique" in id:
        return ".medium"
    if "search" in id or "fetch" in id:
        return ".medium"
    return ".cheap"

import re

# Match `HookCapabilityDefinition(` to `),` using regex
pattern = r'(HookCapabilityDefinition\([^)]+\)),?'

def replacer(match):
    block = match.group(1)
    # Extract ID
    id_match = re.search(r'id:\s*"([^"]+)"', block)
    if not id_match:
        return block + ","
    hook_id = id_match.group(1)
    
    # Extract Category
    cat_match = re.search(r'category:\s*([^,]+),', block)
    old_cat = ".reasoning"
    if cat_match:
        old_cat = cat_match.group(1).strip()
    
    new_cat = map_category(old_cat)
    safety = determine_safety(hook_id, old_cat)
    cost = determine_cost(hook_id)
    
    # We will inject `capability: "...", requires: [...], produces: [...], permissions: [...], safety: ..., cost: ..., whenToUse: "...", whenNotToUse: "...", lifecycleStatus: ...`
    # Let's just append it after category: new_cat, or after description if category missing
    # Actually, we can just replace category: old_cat with category: new_cat
    if cat_match:
        block = block.replace(cat_match.group(0), f'category: {new_cat},')
    
    # Now let's inject taxonomy fields before `requiredContextTypes:`
    # If requiredContextTypes is present:
    injection = f"""
            capability: "{hook_id.replace('_', ' ')}",
            requires: [],
            produces: [],
            permissions: [],
            safety: {safety},
            cost: {cost},
            whenToUse: "When {hook_id.replace('_', ' ')} is needed",
            whenNotToUse: "When {hook_id.replace('_', ' ')} is not needed",
            lifecycleStatus: .stub,
            """
    
    if "requiredContextTypes:" in block:
        block = block.replace("requiredContextTypes:", injection.strip("\n") + "\n            requiredContextTypes:")
        
    # Set implemented correctly if `isImplemented: true` is present
    if "isImplemented: true" in block:
        block = block.replace("lifecycleStatus: .stub,", "lifecycleStatus: .implemented,")
    
    # For legacy init (doesn't have `category:` parameter in the code!)
    # Actually, legacy init HAS `isImplemented: Bool` but we updated it to support taxonomy!
    if not cat_match:
        # It's a legacy init invocation
        # Legacy init is:
        # HookCapabilityDefinition(
        #     id: "...",
        #     description: "...",
        #     requiredContextTypes: [...],
        #     permission: ...,
        #     isImplemented: ...,
        #     mappedPrimitive: ...
        # )
        # We can't easily inject the full taxonomy into the legacy init unless we change the invocation to the new init.
        # Let's change the invocation to the new init!
        # Find description
        desc_match = re.search(r'description:\s*"([^"]+)",', block)
        if desc_match:
            block = block.replace(desc_match.group(0), desc_match.group(0) + f'\n            category: .reasoning,\n' + injection.strip("\n") + "\n")
        
        if "isImplemented: true" in block:
            block = block.replace("lifecycleStatus: .stub,", "lifecycleStatus: .implemented,")

    return block + ","

# We need to manually parse because regex with nested parentheses `()` might fail if the description has them.
# Fortunately, Swift format usually separates HookCapabilityDefinition arguments cleanly.
# Let's use a simpler heuristic.

out = []
in_def = False
def_block = []

for line in content.split('\n'):
    if 'HookCapabilityDefinition(' in line:
        in_def = True
        def_block = [line]
    elif in_def:
        def_block.append(line)
        if line.strip().startswith(')') or line.strip() == '),':
            in_def = False
            b_str = '\n'.join(def_block)
            b_str = replacer(re.match(r'(.*)', b_str, flags=re.DOTALL))
            out.append(b_str)
            def_block = []
    else:
        out.append(line)

# Since replacer is complex, let's just do an iterative string replace
content = content

# Better approach for python:
def process_registry(text):
    result = []
    in_def = False
    current_def = []
    
    for line in text.split('\n'):
        if 'HookCapabilityDefinition(' in line and not line.strip().startswith('//'):
            if in_def:
                # Should not happen
                pass
            in_def = True
            current_def = [line]
        elif in_def:
            current_def.append(line)
            if line.strip() == ')' or line.strip() == '),':
                in_def = False
                block = '\n'.join(current_def)
                
                # Check for legacy init (no `category:` line)
                is_legacy = 'category:' not in block
                
                hook_id = "unknown"
                id_match = re.search(r'id:\s*"([^"]+)"', block)
                if id_match: hook_id = id_match.group(1)
                
                cat = ".reasoning"
                if not is_legacy:
                    cat_match = re.search(r'category:\s*([^,]+),', block)
                    if cat_match:
                        old_cat = cat_match.group(1).strip()
                        cat = map_category(old_cat)
                        block = block.replace(cat_match.group(0), f'category: {cat},')
                else:
                    # Upgrade legacy to new init by inserting category
                    block = re.sub(r'(description:\s*".*?",)', r'\1\n\t\t\tcategory: .reasoning,', block)
                
                safety = determine_safety(hook_id, cat)
                cost = determine_cost(hook_id)
                status = ".implemented" if "isImplemented: true" in block else ".stub"
                
                injection = f"""
            capability: "{hook_id.replace('_', ' ')}",
            requires: [],
            produces: [],
            permissions: [],
            safety: {safety},
            cost: {cost},
            whenToUse: "When {hook_id.replace('_', ' ')} is needed",
            whenNotToUse: "When {hook_id.replace('_', ' ')} is not needed",
            lifecycleStatus: {status},"""
                
                block = block.replace('requiredContextTypes:', injection.strip('\n') + '\n\t\t\trequiredContextTypes:')
                
                result.append(block)
            else:
                pass
        else:
            result.append(line)
            
    return '\n'.join(result)

content = process_registry(content)

with open('Intelligence/HookCapabilityRegistry.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated HookCapabilityRegistry defs.")

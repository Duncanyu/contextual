import re

with open('Intelligence/HookCapabilityRegistry.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# We have ~83 hooks defined like HookCapabilityDefinition(id: "...", description: "...", ...)
# I should use regex to match them, but it's nested and multi-line.
# It's easier to just do simple substitutions for the known fields or use a python parser.
# Actually, since I know the structure, let's fix the init signature first to support `isImplemented` to make it compile, then we can write the taxonomy self test and use it to debug the catalog.

# Let's fix the init to accept isImplemented
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
	) {"""

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
		self.lifecycleStatus = lifecycleStatus ?? (isImplemented ? .implemented : .stub)
		self.requiredContextTypes = requiredContextTypes
		self.permission = permission
		self.permissionLevel = permissionLevel
		self.outputType = outputType
		self.mappedPrimitive = mappedPrimitive
		self.safetyNotes = safetyNotes
		self.commonNextHookIds = commonNextHookIds
		self.commonPrevHookIds = commonPrevHookIds
		self.pairsWellWithHookIds = pairsWellWithHookIds"""

# We just re-replace the init
# Wait, I already replaced it. Let's just restore from git and do it cleanly.


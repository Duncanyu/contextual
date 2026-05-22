import os

# 1. Patch HookCapabilityRegistry.swift
registry_path = "Intelligence/HookCapabilityRegistry.swift"
with open(registry_path, "r") as f:
    reg_content = f.read()

with open("hooks.swift", "r") as f:
    hooks_content = f.read()

# Insert before the last hook copy_to_clipboard or just before the array closing.
target = """\t\t\tHookCapabilityDefinition(
\t\t\t\tid: "copy_to_clipboard","""

new_reg_content = reg_content.replace(target, hooks_content + "\n" + target)

with open(registry_path, "w") as f:
    f.write(new_reg_content)

# 2. Patch HookExecutionSandbox.swift
sandbox_path = "Intelligence/HookExecutionSandbox.swift"
with open(sandbox_path, "r") as f:
    sb_content = f.read()

with open("safe_ids.swift", "r") as f:
    safe_ids_content = f.read()

target_ids = """        // Legacy / fallback support
        "gather_visible_context_once","""

new_sb_content = sb_content.replace(target_ids, safe_ids_content + "\n" + target_ids)

with open("sandbox_cases.swift", "r") as f:
    cases_content = f.read()

target_cases = """        // Legacy / fallback support
        case "gather_visible_context_once":"""

new_sb_content = new_sb_content.replace(target_cases, cases_content + "\n" + target_cases)

with open("sandbox_stubs.swift", "r") as f:
    stubs_content = f.read()

# Insert before the final closing brace of the actor
# Find the last closing brace
last_brace_idx = new_sb_content.rfind('}')
if last_brace_idx != -1:
    new_sb_content = new_sb_content[:last_brace_idx] + stubs_content + "\n}\n"

with open(sandbox_path, "w") as f:
    f.write(new_sb_content)

print("Patching complete.")

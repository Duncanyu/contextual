import os

with open('Intelligence/HookExecutionSandbox.swift', 'r') as f:
    sandbox = f.read()

# 1. safe_ids
with open('safe_ids.swift', 'r') as f:
    new_ids = f.read()

target_ids = """        // Legacy / fallback support
        "gather_visible_context_once","""
if target_ids in sandbox:
    sandbox = sandbox.replace(target_ids, new_ids + "\n" + target_ids)

# 2. cases
with open('sandbox_cases.swift', 'r') as f:
    new_cases = f.read()

target_cases = """        // Legacy / fallback support
        case "gather_visible_context_once":"""
if target_cases in sandbox:
    sandbox = sandbox.replace(target_cases, new_cases + "\n" + target_cases)

# 3. stubs
with open('sandbox_stubs.swift', 'r') as f:
    new_stubs = f.read()

# insert before the last closing brace
idx = sandbox.rfind('}')
if idx != -1:
    sandbox = sandbox[:idx] + new_stubs + "\n}\n"

with open('Intelligence/HookExecutionSandbox.swift', 'w') as f:
    f.write(sandbox)
print("Patched HookExecutionSandbox.swift with 49 new hooks only")

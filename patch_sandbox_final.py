import re

with open('Intelligence/HookExecutionSandbox.swift', 'r') as f:
    sandbox = f.read()

with open('safe_ids.swift', 'r') as f:
    new_ids = f.read()

# Insert before "present_result" in safeHookIds
sandbox = sandbox.replace('        "present_result",', new_ids + '\n        "present_result",')

with open('sandbox_cases.swift', 'r') as f:
    new_cases = f.read()

# Insert before "present_result" in runHook switch
sandbox = sandbox.replace('        case "present_result":            return runPresentResult(ctx: ctx)', new_cases + '\n        case "present_result":            return runPresentResult(ctx: ctx)')

with open('sandbox_stubs.swift', 'r') as f:
    new_stubs = f.read()

# Insert before the last closing brace
idx = sandbox.rfind('}')
if idx != -1:
    sandbox = sandbox[:idx] + new_stubs + "\n}\n"

with open('Intelligence/HookExecutionSandbox.swift', 'w') as f:
    f.write(sandbox)
print("Patched 49 new hooks.")

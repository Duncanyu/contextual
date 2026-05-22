import re

with open('Intelligence/HookCapabilityRegistry.swift', 'r') as f:
    content = f.read()

# Replace buildAll() up to the end of the file with foundationalCatalog
start_marker = '\tprivate static func buildAll() -> [HookCapabilityDefinition] {'
start_idx = content.find(start_marker)

if start_idx != -1:
    with open('scratch/combined_catalog.swift', 'r') as cf:
        combined = cf.read()
    
    new_content = content[:start_idx] + combined + "\n}\n"
    with open('Intelligence/HookCapabilityRegistry.swift', 'w') as f:
        f.write(new_content)
    print("Patched HookCapabilityRegistry.swift")
else:
    print("Could not find start_marker")

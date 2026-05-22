import re

with open('Intelligence/HookCapabilityRegistry.swift', 'r') as f:
    content = f.read()

# 1. Update init
content = content.replace('let defs = Self.buildAll()', 'let defs = Self.foundationalCatalog()')

# 2. Find start of buildAll and end of dangerous()
start_marker = '\tprivate static func buildAll() -> [HookCapabilityDefinition] {'
end_marker = '\tprivate static func dangerous() -> [HookCapabilityDefinition] {'

if start_marker in content and end_marker in content:
    start_idx = content.find(start_marker)
    # find the closing brace of dangerous()
    end_idx = content.find('	private static func legacyCatalog()', start_idx)
    if end_idx == -1:
        # fallback
        end_idx = content.find('// MARK: - Safe Registry Interface', start_idx)
        if end_idx == -1:
             end_idx = content.find('	func legacyCatalog()', start_idx)

    if end_idx != -1:
        with open('scratch/combined_catalog.swift', 'r') as cf:
            combined = cf.read()
        
        new_content = content[:start_idx] + combined + "\n\n" + content[end_idx:]
        with open('Intelligence/HookCapabilityRegistry.swift', 'w') as f:
            f.write(new_content)
        print("Patched HookCapabilityRegistry.swift")
    else:
        print("Could not find end of dangerous()")
else:
    print("Could not find start markers")


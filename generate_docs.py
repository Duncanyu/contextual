import re

with open('Intelligence/HookCapabilityRegistry.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# We will regex out the properties
out = []
out.append("# Implemented Hooks Catalog")
out.append("")
out.append("This document tracks the current state of the hook catalog. Do NOT allow this document to drift from the `HookCapabilityRegistry`.")
out.append("")

cats = {}

in_def = False
current_def = []
for line in content.split('\n'):
    if 'HookCapabilityDefinition(' in line:
        in_def = True
        current_def = [line]
    elif in_def:
        current_def.append(line)
        if line.strip() == ')' or line.strip() == '),':
            in_def = False
            block = '\n'.join(current_def)
            
            hook_id = ""
            desc = ""
            cat = ""
            status = ".stub"
            safety = ".safe"
            cost = ".cheap"
            
            id_match = re.search(r'id:\s*"([^"]+)"', block)
            if id_match: hook_id = id_match.group(1)
            
            desc_match = re.search(r'description:\s*"([^"]+)"', block)
            if desc_match: desc = desc_match.group(1)
            
            cat_match = re.search(r'category:\s*\.([^,]+)', block)
            if cat_match: cat = cat_match.group(1)
            
            status_match = re.search(r'lifecycleStatus:\s*\.([^,]+)', block)
            if status_match: status = status_match.group(1)
            
            safety_match = re.search(r'safety:\s*\.([^,]+)', block)
            if safety_match: safety = safety_match.group(1)
            
            cost_match = re.search(r'cost:\s*\.([^,]+)', block)
            if cost_match: cost = cost_match.group(1)
            
            if cat not in cats:
                cats[cat] = []
            
            cats[cat].append({
                'id': hook_id,
                'desc': desc,
                'status': status,
                'safety': safety,
                'cost': cost
            })

for cat, items in cats.items():
    out.append(f"## {cat.capitalize()} ({len(items)} hooks)")
    for item in items:
        out.append(f"- `{item['id']}`: {item['desc']}")
        out.append(f"  - **Status**: `{item['status']}` | **Safety**: `{item['safety']}` | **Cost**: `{item['cost']}`")
    out.append("")

with open('docs/implemented-hooks.md', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))

print("Docs generated.")

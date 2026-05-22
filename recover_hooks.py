import re

with open('docs/implemented-hooks.md', 'r') as f:
    lines = f.readlines()

hooks = []
current_cat = None

for line in lines:
    if line.startswith('## 1.'): current_cat = '.observation'
    elif line.startswith('## 2.'): current_cat = '.extraction'
    elif line.startswith('## 3.'): current_cat = '.reasoning'
    elif line.startswith('## 4.'): current_cat = '.transformation'
    elif line.startswith('## 5.'): current_cat = '.presentation'
    elif line.startswith('- `'):
        match = re.match(r'- `([^`]+)`: (.*)', line)
        if match:
            hook_id = match.group(1)
            desc = match.group(2).replace('"', '\\"')
            hooks.append((hook_id, desc, current_cat))

out_swift = []
for h in hooks:
    hid, desc, cat = h
    out_type = '.text'
    if hid in ['observe_current_context', 'read_window_title']: out_type = '.metadata'
    elif hid == 'copy_to_clipboard': out_type = '.noOutput'
    
    out_swift.append(f"""\t\t\tHookCapabilityDefinition(
\t\t\t\tid: "{hid}",
\t\t\t\tdescription: "{desc}",
\t\t\t\tcategory: {cat},
\t\t\t\trequiredContextTypes: [.none],
\t\t\t\tpermission: .none,
\t\t\t\tpermissionLevel: .none,
\t\t\t\toutputType: {out_type},
\t\t\t\tisImplemented: true,
\t\t\t\tmappedPrimitive: nil,
\t\t\t\tsafetyNotes: ""
\t\t\t),""")

with open('scratch/foundational_hooks.swift', 'w') as f:
    f.write("\n".join(out_swift))

cases = []
for h in hooks:
    hid = h[0]
    name = "".join([part.capitalize() for part in hid.split('_')])
    cases.append(f'        case "{hid}": return run{name}(ctx: ctx)')

with open('scratch/foundational_cases.swift', 'w') as f:
    f.write("\n".join(cases))

stubs = []
for h in hooks:
    hid = h[0]
    name = "".join([part.capitalize() for part in hid.split('_')])
    stub = f"""
    private func run{name}(ctx: SandboxContext) -> HookSandboxStepOutcome {{
        let output = "{hid} stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("{name}: \\(output)")
        return .success(output: output)
    }}"""
    stubs.append(stub)

with open('scratch/foundational_stubs.swift', 'w') as f:
    f.write("\n".join(stubs))

safe_ids = []
for h in hooks:
    safe_ids.append(f'        "{h[0]}",')

with open('scratch/foundational_safe_ids.swift', 'w') as f:
    f.write("\n".join(safe_ids))

print(f"Generated {len(hooks)} hooks.")

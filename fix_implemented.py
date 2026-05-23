import re

with open('Intelligence/HookCapabilityRegistry.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# We need to change lifecycleStatus: .implemented to .stub for all hooks except those in safeHookIds.
# Let's just find the failing ones from the log and replace them.

failing_ids = [
    "read_window_title", "read_clipboard", "read_ax_text", "summarize_current_context",
    "extract_prices", "extract_dates", "extract_errors", "extract_links",
    "extract_form_fields", "extract_key_claims", "summarize_visible_content",
    "compare_items", "explain_code", "explain_error", "classify_page_type",
    "identify_next_step", "detect_missing_information", "rewrite_text",
    "format_as_email", "convert_to_checklist", "create_table", "shorten_text",
    "expand_text", "clean_text", "present_comparison", "present_checklist",
    "present_warning", "copy_to_clipboard"
]

def process(text):
    result = []
    in_def = False
    current_def = []
    
    for line in text.split('\n'):
        if 'HookCapabilityDefinition(' in line:
            in_def = True
            current_def = [line]
        elif in_def:
            current_def.append(line)
            if line.strip() == ')' or line.strip() == '),':
                in_def = False
                block = '\n'.join(current_def)
                for fid in failing_ids:
                    if f'id: "{fid}"' in block:
                        block = block.replace('lifecycleStatus: .implemented,', 'lifecycleStatus: .stub,')
                        break
                result.append(block)
        else:
            result.append(line)
    return '\n'.join(result)

content = process(content)

with open('Intelligence/HookCapabilityRegistry.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print("Fixed legacy statuses.")

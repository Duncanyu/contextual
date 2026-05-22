import json
import os

hooks = [
    # AI / LLM HOOKS
    ("call_local_llm", "reasoning", "prompt", "llm_output", "normal", "safe", "General purpose LLM invocation.", "When specific heuristic hooks work."),
    ("summarize_with_llm", "reasoning", "text", "summary", "normal", "safe", "LLM-based summarization.", "When text is short."),
    ("classify_with_llm", "reasoning", "text", "classification", "normal", "safe", "LLM-based classification.", "When regex works."),
    ("extract_structured_json_with_llm", "extraction", "text", "json", "normal", "safe", "Extract JSON via LLM.", "When data is simple."),
    ("critique_result_with_llm", "reasoning", "text", "critique", "normal", "safe", "LLM-based critique.", "For straightforward results."),
    ("verify_output_with_llm", "reasoning", "text", "verification", "normal", "safe", "Verify output via LLM.", "When deterministic checks exist."),
    ("generate_short_response", "transformation", "prompt", "short_response", "cheap", "safe", "Generate brief text.", "When needing long details."),
    ("generate_long_response", "transformation", "prompt", "long_response", "expensive", "safe", "Generate detailed text.", "When brief text suffices."),

    # WEB / INTERNET HOOKS
    ("web_search", "observation", "query", "search_results", "normal", "safe", "Perform web search.", "When local context suffices."),
    ("fetch_page_text", "observation", "url", "page_text", "normal", "safe", "Fetch text from URL.", "When URL is untrusted."),
    ("summarize_web_page", "reasoning", "page_text", "page_summary", "normal", "safe", "Summarize web page.", "When full text is needed."),
    ("extract_search_results", "extraction", "search_results", "search_links", "cheap", "safe", "Extract links from search.", "When taking first result directly."),
    ("compare_web_sources", "reasoning", "multiple_page_texts", "comparison", "expensive", "safe", "Compare web pages.", "When one source is enough."),
    ("extract_article_content", "extraction", "page_text", "article_content", "normal", "safe", "Extract article body.", "When page is not an article."),
    ("detect_paywall", "reasoning", "page_text", "paywall_status", "cheap", "safe", "Check for paywall.", "When page is known free."),
    ("identify_primary_topic", "reasoning", "page_text", "topic", "cheap", "safe", "Identify main topic.", "When topic is obvious."),

    # BROWSER HOOKS
    ("get_current_url", "observation", "none", "url", "cheap", "safe", "Get active tab URL.", "When browser is not active."),
    ("open_new_tab", "computerControl", "url", "tab_status", "cheap", "requires_confirmation", "Open new browser tab.", "When avoiding disruptive UI changes."),
    ("switch_tab", "computerControl", "tab_id", "tab_status", "cheap", "requires_confirmation", "Switch to existing tab.", "When tab is already active."),
    ("close_tab", "computerControl", "tab_id", "tab_status", "cheap", "requires_confirmation", "Close active tab.", "When needing tab history."),
    ("search_in_current_tab", "computerControl", "query", "search_status", "cheap", "requires_confirmation", "Search in current tab.", "When search should be in background."),
    ("navigate_to_url", "computerControl", "url", "nav_status", "cheap", "requires_confirmation", "Navigate active tab.", "When page is already loaded."),
    ("read_page_title", "observation", "none", "title", "cheap", "safe", "Read browser page title.", "When window title suffices."),
    ("read_browser_visible_text", "observation", "none", "text", "cheap", "safe", "Read visible web text.", "When AX text suffices."),
    ("fill_web_field", "computerControl", "field_data", "fill_status", "cheap", "requires_confirmation", "Fill form field.", "When form is sensitive.", ".userConfirmation"),
    ("submit_form", "computerControl", "none", "submit_status", "cheap", "requires_confirmation", "Submit active form.", "When submission causes side effects.", ".userConfirmation"),

    # EMAIL / COMMUNICATION HOOKS
    ("draft_email", "transformation", "notes", "email_draft", "normal", "safe", "Draft an email.", "When short chat message suffices."),
    ("summarize_email_thread", "reasoning", "email_thread", "thread_summary", "normal", "safe", "Summarize email thread.", "When thread is 1-2 messages."),
    ("extract_email_action_items", "extraction", "email_text", "action_items", "cheap", "safe", "Extract action items.", "When email has no requests."),
    ("prepare_reply", "transformation", "email_thread", "reply_draft", "normal", "safe", "Draft an email reply.", "When replying is not needed."),
    ("prepare_followup", "transformation", "email_thread", "followup_draft", "normal", "safe", "Draft a followup.", "When thread is active."),
    ("create_message_summary", "reasoning", "message_text", "message_summary", "cheap", "safe", "Summarize chat message.", "When message is short."),

    # APP CONTROL HOOKS
    ("open_app", "computerControl", "app_name", "app_status", "cheap", "requires_confirmation", "Launch an application.", "When app is already open."),
    ("focus_app", "computerControl", "app_name", "app_status", "cheap", "requires_confirmation", "Bring app to front.", "When app is already focused."),
    ("quit_app", "computerControl", "app_name", "app_status", "cheap", "requires_confirmation", "Quit an application.", "When app should remain running."),
    ("switch_window", "computerControl", "window_id", "window_status", "cheap", "requires_confirmation", "Switch app window.", "When single window is active."),
    ("press_shortcut", "computerControl", "shortcut", "shortcut_status", "cheap", "requires_confirmation", "Simulate keyboard shortcut.", "When UI element can be clicked instead."),
    ("scroll_view", "computerControl", "direction", "scroll_status", "cheap", "requires_confirmation", "Scroll the active view.", "When entire content is visible."),
    ("click_screen_coordinate", "computerControl", "coordinates", "click_status", "cheap", "requires_confirmation", "Click X/Y coordinate.", "When element ID is available."),
    ("click_ui_element_by_id", "computerControl", "element_id", "click_status", "cheap", "requires_confirmation", "Click UI element by ID.", "When no UI map exists."),
    ("type_text", "computerControl", "text", "type_status", "cheap", "requires_confirmation", "Simulate keystrokes.", "When pasting is better."),
    ("clear_text_field", "computerControl", "element_id", "clear_status", "cheap", "requires_confirmation", "Clear text field.", "When field is already empty."),

    # RUNTIME ORCHESTRATION HOOKS
    ("split_goal_into_subtasks", "reasoning", "goal", "subtasks", "normal", "safe", "Split complex goal.", "When goal is simple."),
    ("run_subtasks_parallel", "dangerous", "subtasks", "results", "expensive", "requires_confirmation", "Run tasks in parallel.", "When sequential execution is required.", ".unavailable"),
    ("merge_results", "reasoning", "multiple_results", "merged_result", "cheap", "safe", "Merge subtask results.", "When results are singular."),
    ("rank_results", "reasoning", "results", "ranked_results", "cheap", "safe", "Rank multiple items.", "When items are inherently ordered."),
    ("verify_result", "reasoning", "result", "verification_status", "cheap", "safe", "Verify final result.", "When verification is trivial."),
    ("retry_once", "dangerous", "failed_hook", "retry_status", "normal", "requires_confirmation", "Retry a failed hook.", "When failure is deterministic.", ".unavailable"),
    ("branch_on_result", "dangerous", "condition", "branch_path", "cheap", "requires_confirmation", "Branch execution path.", "When execution is linear.", ".unavailable"),
]

output = []
for h in hooks:
    perm_level = ".none"
    if len(h) > 8:
        perm_level = h[8]
    elif h[1] == "computerControl" or h[1] == "dangerous":
        perm_level = ".userConfirmation" if h[1] == "computerControl" else ".unavailable"
        
    out_type = ".text"
    if h[3] == "no_output":
        out_type = ".noOutput"
    elif h[1] == "observation":
        out_type = ".metadata" if h[3] in ["url", "title", "search_results"] else ".text"

    out = f"""\t\t\tHookCapabilityDefinition(
\t\t\t\tid: "{h[0]}",
\t\t\t\tdescription: "{h[6]}",
\t\t\t\tcategory: .{h[1]},
\t\t\t\trequiredContextTypes: [.none],
\t\t\t\tpermission: .none,
\t\t\t\tpermissionLevel: {perm_level},
\t\t\t\toutputType: {out_type},
\t\t\t\tisImplemented: false,
\t\t\t\tmappedPrimitive: nil,
\t\t\t\tsafetyNotes: ""
\t\t\t),"""
    output.append(out)

with open('scratch/new_hooks.swift', 'w') as f:
    f.write("\n".join(output))

with open('scratch/foundational_hooks.swift', 'r') as f:
    foundational = f.read()
with open('scratch/new_hooks.swift', 'r') as f:
    new_hooks = f.read()

combined = "    static func foundationalCatalog() -> [HookCapabilityDefinition] {\n        [\n" + foundational + "\n" + new_hooks + "\n        ]\n    }"

with open('scratch/combined_catalog.swift', 'w') as f:
    f.write(combined)

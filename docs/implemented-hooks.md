# Implemented Hooks

This document maintains the active list of all foundational, atomic hooks implemented and available in the execution sandbox. 

Whenever a new hook is introduced to the `HookCapabilityRegistry`, it should be appended to this document.

## 1. Sensing / Context (7 hooks)
Used to observe the environment and gather information.
- `observe_current_context`: Captures a snapshot of the active window/app state.
- `read_window_title`: Reads the title of the active window.
- `read_selected_text`: Retrieves any user-selected text.
- `read_clipboard`: Reads the current contents of the system clipboard.
- `read_ax_text`: Extracts text directly from the macOS Accessibility API.
- `run_ocr_once`: Captures a screen snapshot and runs Optical Character Recognition.
- `summarize_current_context`: Produces a general summary of the immediate context.

## 2. Extraction (8 hooks)
Used to pull out structured information from the gathered context.
- `extract_entities`: Identifies names, places, and organizations.
- `extract_product_attributes`: Extracts specific product details (brands, specs).
- `extract_prices`: Finds monetary values and pricing structures.
- `extract_dates`: Locates timestamps and calendar dates.
- `extract_errors`: Captures stack traces, crash logs, or visible UI error messages.
- `extract_links`: Extracts URLs and hyperlinks.
- `extract_form_fields`: Identifies inputs, labels, and forms on screen.
- `extract_key_claims`: Pulls out primary assertions or key points from text.

## 3. Understanding / Reasoning (7 hooks)
Used to interpret or reason over the extracted information.
- `summarize_visible_content`: Synthesizes a focused summary of the visible screen.
- `compare_items`: Evaluates similarities and differences (e.g., comparing product features).
- `explain_code`: Diagnoses and explains code snippets.
- `explain_error`: Provides a plain-English explanation for an extracted error.
- `classify_page_type`: Determines the type of workflow or document currently open.
- `identify_next_step`: Recommends a logical next action.
- `detect_missing_information`: Flags critical gaps in the provided context.

## 4. Transformation (7 hooks)
Used to rewrite, structure, or transform content.
- `rewrite_text`: Adjusts tone, fixes grammar, or reformats general text.
- `format_as_email`: Converts raw notes into a drafted email structure.
- `convert_to_checklist`: Structures scattered points into actionable checkboxes.
- `create_table`: Organizes comparative data into a markdown table.
- `shorten_text`: Condenses text into a brief overview.
- `expand_text`: Elaborates on brief points with more detail.
- `clean_text`: Strips out formatting noise and artifacts.

## 5. Presentation (5 hooks)
Used to securely and cleanly present the final results to the user.
- `present_result`: Displays general output or text blocks.
- `present_comparison`: Formats and displays a side-by-side comparison.
- `present_checklist`: Renders a structured checklist interface.
- `present_warning`: Surprises prominent alerts or safety boundaries.
- `copy_to_clipboard`: Securely places formatted output into the clipboard.

## 6. Intelligence / LLM (8 hooks)
Used for direct AI model interactions and synthesis.
- `call_local_llm`: Direct execution against the local model.
- `summarize_with_llm`: Instructs the LLM to summarize text.
- `classify_with_llm`: Instructs the LLM to classify content.
- `extract_structured_json_with_llm`: Forces JSON extraction from unstructured text.
- `critique_result_with_llm`: Evaluates and scores an outcome using the LLM.
- `verify_output_with_llm`: Self-verification step for generation consistency.
- `generate_short_response`: Produces a concise answer or command.
- `generate_long_response`: Produces detailed, structured text.

## 7. Web Browsing / Internet (18 hooks)
Used for web searches, reading, and browser automation.
- `web_search`: Perform a general web search.
- `fetch_page_text`: Fetches raw text from a given URL without a browser.
- `summarize_web_page`: Navigates to a URL and summarizes it.
- `extract_search_results`: Pulls specific links/snippets from search engines.
- `compare_web_sources`: Fetches and compares multiple URLs.
- `extract_article_content`: Strips out noise to return the main body.
- `detect_paywall`: Detects if a page requires payment/login.
- `identify_primary_topic`: Infers the core topic of a website.
- `get_current_url`: Reads the active browser URL.
- `open_new_tab`: Opens a new blank tab.
- `switch_tab`: Switches between existing tabs.
- `close_tab`: Closes the current or specified tab.
- `search_in_current_tab`: Uses the browser's search bar.
- `navigate_to_url`: Forces the browser to load a URL.
- `read_page_title`: Reads the document title of the active tab.
- `read_browser_visible_text`: Reads only what is visibly rendered.
- `fill_web_field`: Inputs text into a web form element.
- `submit_form`: Triggers form submission.

## 8. Communication (6 hooks)
Used for drafting and interacting with messaging/email.
- `draft_email`: Formats a message suitable for sending.
- `summarize_email_thread`: Condenses a chain of messages.
- `extract_email_action_items`: Pulls tasks out of an email.
- `prepare_reply`: Generates a contextual response to the active message.
- `prepare_followup`: Generates a checking-in message.
- `create_message_summary`: Summarizes chat messages or brief texts.

## 9. App Control & UI (10 hooks)
Used for generic window, app, and UI automation.
- `open_app`: Launches or activates a specific application.
- `focus_app`: Brings a running app to the foreground.
- `quit_app`: Terminates an application.
- `switch_window`: Cycles or selects a specific window.
- `press_shortcut`: Simulates a keyboard shortcut.
- `scroll_view`: Automates scrolling down or up.
- `click_screen_coordinate`: Clicks a raw (x,y) location.
- `click_ui_element_by_id`: Clicks an element using the Accessibility API.
- `type_text`: Simulates keystrokes.
- `clear_text_field`: Clears the focused input field.

## 10. Orchestration (7 hooks)
Used to manage hook chains and logic control flow.
- `split_goal_into_subtasks`: Generates a sub-plan from a larger goal.
- `run_subtasks_parallel`: Forks execution for independent tasks.
- `merge_results`: Combines outputs from multiple hooks.
- `rank_results`: Sorts outputs based on relevance or confidence.
- `verify_result`: Validates if a condition or constraint is met.
- `retry_once`: Wraps a volatile hook with a single automatic retry.
- `branch_on_result`: Evaluates an output and directs flow to one of two paths.

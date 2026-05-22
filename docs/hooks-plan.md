# Contextual — Hook System & Future Agentic Runtime Design

## Current Direction

Contextual is moving toward a dynamic local-first execution architecture:

    Context
    → Inferencing
    → Planning
    → Hook Discovery / Composition
    → Hook Runtime Execution
    → (Future Recursive / Agentic Layer)

The goal is to avoid:
- hardcoded action recipes
- static templates
- giant prompt-only systems
- brittle single-stage inference

Instead:
- small local models infer intent
- planner decides what should happen
- hook system dynamically composes actions
- runtime executes bounded capabilities safely

---

# Current Status

## Working

### Two-Stage Inference
- Router: qwen2.5:0.5b
- Planner: qwen2.5:1.5b
- Warm router latency: ~150–500ms
- Warm planner latency: ~1.3–2s

### Proposal Pipeline

Current flow works:

    Context
    → Router
    → Planner
    → Hook Composition
    → GeneratedActionContract
    → Proposal Activation
    → UI Proposal

### Hook Runtime Sandbox

Sandbox runtime exists and can:
- execute hooks sequentially
- pass outputs between hooks
- run sample/live contexts
- display runtime results
- fail honestly

---

# Hook Philosophy

Hooks are intended to behave similarly to:
- Scratch blocks
- workflow primitives
- composable capabilities

The planner should never directly generate giant executable scripts.

Instead:
- planner selects capabilities/goals
- hook discovery retrieves hooks
- runtime executes them safely

---

# Hook Design Rules

## Hooks Must Be Atomic

Avoid:
- overlapping hooks
- near-duplicates
- vague capability boundaries

Bad examples:
- extract_products
- extract_product_info
- parse_product_details

Good:
- extract_product_attributes

One hook should own one capability.

---

# Hook Sections

Hooks should be grouped into sections to support multi-pass discovery.

---

## 1. Context / Sensing Hooks

Purpose:
observe environment and gather information.

Examples:
- observe_current_context
- read_window_title
- read_selected_text
- read_clipboard
- read_ax_text
- run_ocr_once
- get_visual_descriptor
- summarize_current_context

---

## 2. Extraction Hooks

Purpose:
extract structured information.

Examples:
- extract_entities
- extract_product_attributes
- extract_prices
- extract_dates
- extract_tasks
- extract_errors
- extract_links
- extract_form_fields
- extract_key_claims

---

## 3. Understanding / Reasoning Hooks

Purpose:
interpret or reason over extracted information.

Examples:
- summarize_visible_content
- compare_items
- explain_code
- explain_error
- classify_page_type
- identify_next_step
- rank_options
- detect_missing_information

---

## 4. Transformation Hooks

Purpose:
rewrite or transform content.

Examples:
- rewrite_text
- format_as_email
- convert_to_checklist
- create_table
- shorten_text
- expand_text
- translate_text
- clean_text

---

## 5. Presentation Hooks

Purpose:
present information back to the user.

Examples:
- present_result
- present_comparison
- present_checklist
- present_warning
- copy_to_clipboard
- create_draft_response

---

## 6. Computer Control Hooks

IMPORTANT:
These are future-sensitive and must remain gated.

Examples:
- open_app
- focus_app
- open_url
- press_shortcut
- click_ui_element
- type_text
- toggle_dnd
- play_media

These should NOT be fully enabled initially.

---

## 7. Logic / Flow Hooks

Purpose:
control runtime execution flow.

Examples:
- if_condition
- retry_once
- wait_until_stable
- stop_on_failure
- ask_user_confirmation
- branch_on_result

These become more important in recursive/agentic execution.

---

## 8. Memory / Library Hooks

Purpose:
support reusable generated actions and persistence.

Examples:
- save_generated_action
- retrieve_similar_action
- mark_action_success
- mark_action_failure
- decay_unused_action

---

# Multi-Pass Hook Discovery

The system should NOT simply retrieve:
“top 5 similar hooks.”

Instead:
discovery should happen in multiple passes.

---

## Pass 1 — Determine Needed Sections

Example:
“Compare products”

Needed sections:
- sensing
- extraction
- reasoning
- presentation

---

## Pass 2 — Retrieve Candidate Hooks

Example:

    run_ocr_once
    extract_product_attributes
    compare_items
    present_result

---

## Pass 3 — Validate Input/Output Chain

Example:

    screen_snapshot
    → ocr_text
    → product_attributes
    → comparison_summary
    → displayed_result

Hooks must produce outputs that later hooks can consume.

---

## Pass 4 — Remove Unnecessary Hooks

Example:
Do NOT include:
- extract_tasks
- classify_page_type
- translate_text

if they are irrelevant to the goal.

---

# Hook Metadata Design

Each hook should include metadata:

    id
    section
    capability
    requires
    produces
    permissions
    safety
    cost
    when_to_use
    when_not_to_use

Example:

    id: run_ocr_once
    section: sensing
    capability: context.ocr
    requires: screen_snapshot
    produces: ocr_text
    cost: expensive
    permissions: screen_recording
    safety: safe

---

# Runtime Philosophy

Runtime should:
- execute sequentially
- pass typed outputs between hooks
- fail honestly
- stop on first failure
- avoid fake success
- remain bounded and reviewable

Current runtime is intentionally quarantined/sandboxed.

---

# Future Agentic / Recursive Runtime

IMPORTANT:
This is NOT the current implementation target.

Current target:
basic sequential hook execution only.

However, future architecture should support recursive execution.

---

# Future Agentic Flow

Future architecture may look like:

    Goal
    → Observe UI
    → Build Screen Map
    → Decide next action
    → Execute one action
    → Reobserve
    → Decide next action
    → Repeat until success/failure

This is fundamentally different from:
“generate giant click script upfront.”

---

# UI / ScreenMap Concept

Small local models cannot efficiently reason over raw screenshots continuously.

Instead:
the system should build a compact textual UI map.

Example:

    app=Music
    window="Apple Music"

    elements:
    1. button "Play"
    2. sidebar item "Library"
    3. playlist "Favorites Mix"

Then the model outputs:

    action: click_element
    target_id: 1

Deterministic runtime performs the click.

This avoids:
- random coordinate clicking
- giant image prompts
- expensive continuous vision usage

---

# Accessibility-First Philosophy

Future computer control order:

1. Accessibility tree
2. Window metadata
3. OCR
4. Visual descriptor
5. Vision model fallback

Visual descriptor should remain:
- expensive
- bounded
- last resort

---

# Future Computer Control Hooks

Possible future hooks:

- observe_ui_tree
- build_screen_map
- find_ui_element
- click_ui_element
- type_into_element
- press_shortcut
- wait_for_ui_change
- verify_goal_progress
- ask_user_confirmation

These should initially remain:
- disabled
- sandboxed
- gated
- reviewable

---

# Safety Philosophy

The system must remain:
- local-first
- bounded
- reviewable
- deterministic where possible
- non-chaotic

Unsafe behaviors to avoid:
- infinite recursive loops
- uncontrolled clicking
- silent automation
- hidden execution
- runaway planning

---

# Current Immediate Goal

Current focus is NOT recursion.

Current focus:

1. Build a clean high-quality hook library
2. Implement safe foundational hooks
3. Improve multi-pass discovery
4. Improve hook selection quality
5. Improve runtime chaining
6. Expand capability coverage carefully

Only later:
- recursive execution
- agentic workflows
- computer control
- self-correction loops
- autonomous task execution

---

# Immediate Practical Hook Priorities

Recommended first hooks:
- observe_current_context
- run_ocr_once
- extract_entities
- extract_product_attributes
- summarize_visible_content
- compare_items
- explain_error
- explain_code
- present_result
- create_checklist
- create_table
- rewrite_text

These cover:
- shopping
- coding
- studying
- writing
- debugging
- research

without requiring dangerous automation.

---

# Important Design Principle

Generated actions should feel:
- adaptive
- context-aware
- composable
- reactive

NOT:
- hardcoded
- template-driven
- repetitive
- static

The hook system exists to make the assistant:
dynamic without becoming uncontrolled.

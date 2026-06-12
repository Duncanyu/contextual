# Action Ontology Audit — Phase 53 (June 2026)

Audit of the action universe before the "Liquid Workflow Actions" sprint.

## 1. What actions exist now

**Registered AND executable (`local_action` + executor case):**

- Cognitive: `explicit_visible_capture_summary`, `extract_action_items`,
  `create_checklist`, `rewrite_text`, `improve_text`, `explain_context`,
  `draft_reply`
- Setup/acquisition (Phase 52): `capture_visible_page`,
  `capture_full_document`, `enable_browser_bridge`, `select_text_hint`
- Utilities: `copy_current_url`, `copy_all_related_links`,
  `collect_references`, `remember_workspace`, `open_current_task_panel`
- Friction/workspace: `arrange_side_by_side`, `switch_to_paired_app`,
  `split_research_setup`, `restore_workspace`, `restore_research_tabs`,
  `pin_reference_tabs`, `open_related_app_set`, `open_paired_app`,
  `switch_to_last_task_window`
- Media/focus: `play_focus_media`, `pause_media`, `resume_focus_media`,
  `enable_reduce_interruptions` (`start_focus_timer` returns unavailable)

**Registered but UNREACHABLE (preview_only → executor default = unavailable):**
`summarize_context`, `compare_options`, `decision_matrix`, `generate_quiz`,
`create_outline`, `create_review_plan`, `diagnose_error`,
`synthesize_sources`, `improve_project`, `debug_performance`,
`create_game_design_checklist`, `explain_how_to_make_faster`,
`summarize_reference`, `create_next_steps`, `create_study_outline`,
`generate_test_checklist`, `compare_rental_options`, `draft_listing_ad`,
`create_listing_checklist`, `extract_pricing_guidance`,
`identify_missing_listing_details`, `create_questions_to_ask_landlord`,
`compare_listing_platforms`, `summarize_thread`, `synthesize_advice`,
`suggest_focus_playlist`, `precompute_answer`

This is the central finding: **a latent rental/research/code ontology already
exists in the registry but was never wired to executors or the panel planner.**
The product feels like 3 actions because the panel planner
(`DeterministicPanelActionPlanner`) only ever emits: the
summarize/extract/checklist trio, 4 metadata utilities, arrange (under
friction), music, and the selected-text writing trio.

## 2. Which are generic

`explicit_visible_capture_summary`, `extract_action_items`,
`create_checklist`, `rewrite_text`, `improve_text`, `explain_context`,
`draft_reply` — these 7 are the entire visible cognitive surface, and the
first three are added to the panel for *every* document/browser context where
content is available. That is the "summarize / rewrite / checklist" monotony.

## 3. Which are actually executable

See list 1. Roughly 27 executable ids, of which only ~12 ever reach the panel.

## 4. Which appear too often

- `explicit_visible_capture_summary` / `extract_action_items` /
  `create_checklist` — emitted as a trio whenever safeActions allows.
- `copy_current_url`, `collect_references`, `remember_workspace` — emitted on
  nearly every browser context.
- Music candidate injected in every non-playing, non-typing context.

## 5. Which workflows have NO useful actions

- **Forms/applications (OSAP)** — zero form-aware actions. Live dogfood pages
  ("Select Your Program", "Financial Information"…) got summarize or capture.
- **Code/logs/debugging** — `diagnose_error` exists but is unreachable;
  nothing generates agent prompts, regression tests, or maps logs.
- **Multi-tab research** — `compare_options`/`synthesize_sources` unreachable;
  nothing compares tabs, collects sources as a brief, or tracks next steps.
- **Rental/lease analysis** — listing ids exist but unreachable; nothing flags
  clauses, extracts obligations/dates, or builds tenant checklists.
- **Memory/recurring workflows** — only `remember_workspace` (app layout);
  no task notes, no recall, no next-step memory.

## 6. Duplicated/redundant

- `extract_and_organize` → same executor as `collect_references`
- `pin_reference_tabs` → same executor as `restore_research_tabs`
- `launch_recent_workspace` → same executor as `restore_workspace`
- `summarize_context` vs `summarize_visible_content` vs
  `explicit_visible_capture_summary` (one survives)
- `improve_text` vs `rewrite_text` (near-identical executor)

## 7. Blocked only because context is weak

The generic trio on metadata-only pages (Phase 52 correctly downgrades to
capture/setup). `synthesize_sources` on metadata. Writing actions without
selection. These are correctly gated — the problem is there was nothing
*else* to offer, so weak context felt like "Siri saying I can't".

## 8. Which need source-native acquisition later (browser bridge sprint)

- True full-page claims: `find_conflicting_info`, `extract_key_claims` at
  full-page scope, cross-tab content comparison (`compare_open_tabs` beyond
  titles), `summarize_each_open_tab` (content per tab)
- Google Docs full document without manual capture (`connect_google_docs`)
- Form field *values* at scale (consistency checking beyond visible AX)
- DOM-level form field enumeration (`detect_required_fields` full coverage)

These surface in Phase 53 only as Tier 2 (capture) or Tier 3 (setup) paths,
never as decorative buttons.

## Phase 53 response

- A typed ontology (`Intelligence/LiquidWorkflowActions.swift`) with
  10 categories and 40+ specific actions, each declaring evidence, scope,
  execution tier, surface policy, cooldown, and fallback.
- Workflow detectors (forms, rental/lease, code/logs, research, writing).
- `LiquidActionRouter` ranks specific > executable > setup > generic, caps
  generic actions, applies cooldowns.
- Tier-1 executors implemented as deterministic local formatters over honestly
  acquired content (UCR scope rules unchanged); metadata-based actions clearly
  label their input ("based on page title/tabs"), never claiming content.
- The unreachable preview_only registry entries stay unreachable from the
  panel; the new ontology supersedes them (several are realized as real
  executors under new ids, e.g. flag_risky_clauses, diagnose_latest_error).

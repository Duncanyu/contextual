# Phase 62 — Composable Action Runtime Audit

Date: 2026-06-12. Source of truth: `docs/log.rtf` (fifth dogfood, 10:15) + code.

Verdict up front: **the gates work; the generator is the wall.** Phase 61 stopped
background tabs from hijacking workflow/activity, and on Reddit/YouTube/Minecraft
pages the surface now correctly falls through to `focus_current_task`. That's not a
win — it's the system honestly admitting it has *no useful idea* for these contexts.
We have eight rental-shaped mega-actions and one zero-shaped lane for everything else.

`[ComposableActionAudit] status=fail issues=10`.

## 1. Giant hardcoded domain actions (the mega-actions)

Inspecting `WorkflowActionOntology` (`Intelligence/LiquidWorkflowActions.swift`) and
the `LiquidInsightFormatters.format` switch:

- `flag_risky_clauses`, `extract_obligations`, `extract_dates_deadlines_payments`,
  `detect_missing_terms`, `generate_questions_for_landlord`,
  `summarize_house_rules`, `rewrite_clause_plain_english`,
  `compare_document_to_listing`, `find_conflicting_info` — **rental/lease specific**;
  each is a single switch case with bespoke parsing.
- `compare_open_tabs`, `create_decision_table`, `make_research_brief`,
  `identify_next_research_step`, `extract_key_claims` — **cross-tab specific**;
  each glues bespoke matching + a hardcoded markdown template.
- `detect_required_fields`, `check_form_consistency`, `flag_deadlines_or_warnings`,
  `explain_current_form_field`, `draft_answer_for_form_field`,
  `list_missing_form_info`, `make_application_checklist` — **forms specific**.
- `diagnose_latest_error`, `summarize_log_failure`, `generate_next_agent_prompt`,
  `create_regression_test_prompt`, `identify_repeated_log_pattern`,
  `map_log_to_subsystem` — **code/log specific**.

51 specific actions, every one a giant if-branch. The system has no Minecraft, no
Reddit, no shopping vocabulary at all — only seven workflow lanes.

## 2. Reusable primitives (what's already there but hidden)

Inside `LiquidInsightFormatters`: `matching(_:any:)`, `sentences()`, `lines()`,
`moneyAmounts()`, `dateMentions()`, `regexMatches()`, `bullets()`. These are *exactly*
the primitives we need (`extract_dates`, `extract_prices`, `extract_key_points`), but
they're private helpers buried under domain actions, with no public interface, no
schema, no composition.

## 3. Metadata notes / fake previews

`liquidMetadataNote` produces templates from title+tabs ("Move-in checklist… [based on
title]") with no real content claim. These are correctly labeled but still surface as
the *only* result for many contexts.

## 4. Actions that need content but don't trigger acquisition

`extract_key_claims`, `compare_open_tabs`, `make_research_brief`,
`identify_next_research_step` declare `requiredContext: ["tabs"]` only — they will
"execute" against metadata and return template-shaped output. The system relies on a
later `userReadableResultGate` to reject the empty result, by which point we've already
committed to that action. No proactive acquisition step in the action plan itself.

## 5. Why non-listing contexts have no useful actions

Workflow gating: `LiquidActionRouter.workflowMatch` requires the action's
`category` (documents_leases / browser_research / forms / code_logs / writing) to
match a detected workflow. Reddit/YouTube/Minecraft maps to no workflow → all
specific actions suppressed (`workflow_not_detected`). The fallback is
`focus_current_task` (workspaceFriction) — the only action left standing.

## 6. Reddit/Minecraft/search collapsing to focus_current_task

Confirmed in your log:
```
[ContextualActionSet] content_type=generic_webpage workflow=generic actions=focus_current_task
[ContextualActionSet] content_type=media_page workflow=generic actions=focus_current_task
```
No domain workflow → no specific action → only focus survives.

## 7. compare listings appears but no useful chain

`compare_open_tabs` is one switch case. On metadata it returns a
"capture-needed"-shaped string; on visible content it runs `matching()` over `[$, …]`
words. There is no acquisition step bound to the action. The user can never reach a
real comparison from a metadata-only state in a single tap — and the action provides
no "and then…" path.

## 8. Residual hardcoded domain/workflow mappings

- `BrowserContextStrategy.assess` (Phase35ContextLayer:130) classifies type=listing
  whenever **any** tab — current or background — contains `rent/rental/listing/
  housing/landlord/sublet/roommate`. Your dogfood log shows this firing on a Reddit
  Minecraft tab because of background Kijiji/Rentals.ca tabs. Phase 61 stopped this
  from contaminating workflow; **it never reached the BrowserContextStrategy code**.
- `LiquidActionRouter.preflightLine` and `LiquidActionExecution.generateFollowUps`
  contain explicit `if action.id == "compare_open_tabs"`/`"flag_risky_clauses"`
  branches.
- `LiquidActionRouter.honestDisplayTitle`: explicit `rentalSearch` keyword branches
  with hardcoded titles ("Capture rental listings to compare them").
- `WorkflowDetectors.rentalTerms`/`formTerms`/`codeTerms`/`comparisonTerms` are
  still term-bucket lists that *gate* whole action families.

## 9. BrowserContextStrategy type=listing from background tabs

Confirmed: the current dogfood log has 142 hits of `type=listing` while the focused
page was Reddit/YouTube. Fixed in this phase by ignoring background tabs unless the
focused page itself carries listing signals.

## 10. The planner cannot compose primitives

`LiquidActionRouter.route()` returns capability ids. `presentCognitiveResultSurface`
maps id → bespoke switch case. There is no plan structure between "id" and "text" —
the executor is the formatter. A primitive `extract_recommendations` doesn't exist as a
callable thing; it's part of the body of `extract_key_claims`.

## Findings register

| # | Issue | Severity | File | Recommendation |
|---|---|---|---|---|
| 1 | 51 mega-actions, each a domain if-branch | high | LiquidWorkflowActions.swift, LiquidActionExecution.swift | Extract primitives; mega-actions become composed plans |
| 2 | No primitive registry: extractors buried in formatters | high | LiquidActionExecution.swift | Public `PrimitiveToolRegistry` over typed schemas |
| 3 | No ComposedActionPlan model | high | (missing) | Plans of primitives with missing_inputs / followups |
| 4 | Cognitive actions don't drive acquisition | high | LiquidActionExecution.swift | First step of every plan acquires what it needs |
| 5 | Non-listing contexts collapse to focus_current_task | high | LiquidActionRouter.swift | Content-type templates emit composed plans for forum/article/study/shopping/media/code |
| 6 | compare_open_tabs not a real chain | high | LiquidActionExecution.swift | capture_related_tabs → extract_table_like_records → normalize → compare → draft_questions |
| 7 | BrowserContextStrategy type=listing from background tabs | high | Phase35ContextLayer.swift | Current-focus-first; background recorded separately |
| 8 | honestDisplayTitle / preflight branch on action id | medium | LiquidActionRouter.swift | Branch on plan kind, not id |
| 9 | Term lists gate whole action families | medium | LiquidActionRouter.swift | Already moved to content-type contracts (Phase 59) — but plans must obey too |
| 10 | No execution engine for composed plans | high | (missing) | Lightweight sequential executor that passes outputs |

`[ComposableActionAudit] status=fail issues=10`

## What Phase 62 builds

`Intelligence/PrimitiveActionRuntime.swift`: a typed `PrimitiveTool` registry
(acquisition / extraction / transformation / workspace primitives, ~30 tools with
input/output schemas), `ComposedActionPlan` model with steps/missing_inputs/followups,
a `ComposedPlanExecutor` that runs steps sequentially and passes outputs, and a
content-aware `ComposedActionPlanner` that emits plans per content type *without*
hardcoded domain action IDs. Old mega-actions remain registered for backwards
compatibility but the planner stops choosing them as primary intelligence.
`BrowserContextStrategy.assess` becomes current-focus-first.

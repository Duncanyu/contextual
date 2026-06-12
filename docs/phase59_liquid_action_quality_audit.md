# Phase 59 — Liquid Action Quality Audit

Date: 2026-06-11. Source of truth: `docs/log.rtf` (second dogfood, 2026-06-11 20:35) + code inspection.

Verdict up front: **the user is right.** The action layer is term-bucket routing with a flat
fake relevance score, one conflated "rental" bucket covering everything from a Facebook
housing group to a signed lease, a generic clipboard utility mislabeled as "specific" so it
floats everywhere, and a feedback store that records dismissals nothing ever reads.

`[ActionQualityAudit] status=fail issues=10` (pre-59 state; the selftest re-verifies each).

---

## 1. Where workflows are classified

Three places, none agreeing:
- `WorkflowDetectors.detect()` (`LiquidActionRouter.swift`) — term-bucket counting over
  title+tabs+url. Any browser with ≥3 tabs **or** ambient workflow `researching` becomes
  `browser_research` — i.e. studying, shopping, and Reddit all collapse into "research,"
  which is why the same generic research actions appear everywhere.
- `WorkflowDetectors.deterministicRentalWorkflow()` — computes a `rental_search` vs
  `rental_lease` **label for the log line**, then returns `kind: .rentalLease` either way
  (line ~135). The distinction the product needs is computed and then thrown away.
- `LiquidActionCompartmentGate.selectedTabWorkflow()` — `rentalFocusSupported(focus)`:
  any of {rent, rental, housing, roommate, apartment, sublet, …} in the focused
  title/URL → `workflow=rental_lease` at confidence ≥0.55. Log evidence:
  `[SelectedTabWorkflow] workflow=rental_lease confidence=0.95 signals=rent,rental,sublet,roommate,housing,apartment`
  — for a **Facebook group**.

## 2. Where action families are chosen

`route()`: `workflowMatch(category)` — `.documentsLeases` actions are unlocked by
`detectedKinds.contains(.rentalLease)`. Since a housing group *is* `.rentalLease` (above),
`flag_risky_clauses` / `extract_obligations` / `detect_missing_terms` pass the workflow
gate, pass the compartment gate (`selectedKind == requiredKind`), and surface as
capture-needed cards. Log: `[TemporalSourceUse] id=flag_risky_clauses source=current_focus allowed=yes`.
**There is no notion of what the focused thing *is* — only which term bucket it tripped.**

## 3. Where selected-tab type is determined — nowhere

`selectedTabWorkflow` returns a *workflow*, not a content type. A lease document, a
listing dashboard, a housing-group feed, and a message thread are indistinguishable.

## 4. Where content type is determined — nowhere

No content-type model exists. `isLeaseDocumentContext` is the closest thing: five terms
(lease/occupancy/agreement/tenant/landlord) OR `app.contains("preview")` OR
`app.contains("textedit")` — i.e. *any* rental-flagged context in Preview becomes a
"lease document."

## 5. Where candidate actions are scored

`route()` scoring: `score = preflight.relevance (always 0.30)` + workflow confidence ×0.4
+ tier bump + `isSpecificAction` ±. Then hand-tuned context bonuses:
`leaseDocumentPriority` fixed list +0.95, `rentalSearchContext` +0.45 to four hardcoded
ids. Score is workflow-bucket membership, not usefulness.

## 6. Where hardcoded term lists exist

- `deterministicRentalTerms` / `rentalTerms` / `rentalFocusSupported` — broad nouns
  (housing, roommate, apartment, room) directly unlock the lease bucket.
- `codeTerms` contains **dogfood-specific strings**: `"log.rtf"`, `"codex"`,
  `"implementation_plan"`, `"selftest"`, `"capability"`, `"agent"`, `"prompt"`.
- `unrelatedFocusTerms` contains **dogfood platform names**: `"linkedin"`, `"epieos"`.
- `selectedTabWorkflow` gives `docs.google.com` a +0.20 confidence boost by name.
- `leaseDocumentPriority` is a fixed five-action list with a flat +0.95.

## 7. Where rental/search/listing/document contexts are conflated

One enum case (`.rentalLease`) covers: rental *search*, listing *pages*, housing *groups*,
lease *documents*, and landlord *messages*. `deterministicRentalWorkflow` even computes
the split and discards it. Document actions key off the conflated case.

## 8. Where generic actions win over useful actions

`collect_sources_from_tabs` is `executionKind: .workspaceAlias` (tier 1, +0.2),
**defaults to `isSpecificAction: true`** (+0.15, no generic cap, no generic demotion),
and `isCrossTabAction()` hard-exempts it from the compartment gate. `floatingCandidate`
requires only specific+read-only+panelPrimary+tier1 → it floats on facebook.com with
`reason=high_confidence_read_only`. Log: `[TickReasoning] … selected=collect_sources_from_tabs reason=liquid_router_winner`
on both the generic Facebook page and the housing group. "Safe to run" is treated as
"worth floating."

## 9. Why relevance is flat 0.30

`computePreflight()` line ~969: `relevance: 0.3` — a literal constant for every action in
every context. The preflight "relevance" is decorative.

## 10. Why collect_sources_from_tabs floats + feedback is ignored

Combination of #8 plus: `LiquidRoutingInput.recentlyRejected/recentlyAccepted` exist and
are honored in `route()`, but the live caller (`ContextEventProducer.swift:1395`) passes
**only signals** — both sets are always empty. Meanwhile `DurableMemory.recordActionFeedback`
faithfully records every auto-dismiss
(`[DurableMemory] action_feedback capability=collect_sources_from_tabs event=auto_dismissed …` —
twice in this log) and **no selection path ever reads it back**. The same card was
auto-dismissed and re-floated minutes later.

---

## Findings register

| # | Issue | Severity | File | Recommendation |
|---|-------|----------|------|----------------|
| 1 | Broad rental terms → `.rentalLease` → document actions (housing group gets `flag_risky_clauses`) | high | LiquidActionRouter.swift | Content-type layer; document actions require `lease_or_contract_document` |
| 2 | `rental_search` vs `rental_lease` computed then discarded | high | LiquidActionRouter.swift | Split `DetectedWorkflowKind.rentalSearch` from `.rentalLease` |
| 3 | No content-type model at all | high | (missing) | `ContentTypeClassifier` over signals, separate from workflow |
| 4 | `relevance: 0.3` literal for all actions | high | LiquidActionRouter.swift | Real `UsefulActionScore` (focus/content/evidence/value/specificity/cost) |
| 5 | `collect_sources_from_tabs` mislabeled specific, exempted from gates, floats everywhere | high | LiquidWorkflowActions.swift, LiquidActionRouter.swift | Contract: panel-only without strong collection intent; floating usefulness threshold |
| 6 | Feedback recorded but never read by selection | high | ContextEventProducer.swift | Wire DurableMemory feedback into routing input + floating gate |
| 7 | Dogfood-specific terms in `codeTerms`, platforms in `unrelatedFocusTerms` | medium | LiquidActionRouter.swift | Remove; replace with generic patterns |
| 8 | ≥3 tabs ⇒ `browser_research` ⇒ same actions on studying/shopping/reddit | medium | LiquidActionRouter.swift | Content-type gating + diversity; research actions need source-like evidence |
| 9 | Compare actions need no actual candidates (one housing group "qualifies") | medium | LiquidActionRouter.swift | Contract: `multiple_listing_candidates` or honest capture-needed |
| 10 | Fixed `leaseDocumentPriority` +0.95 / `rentalSearchContext` +0.45 hand boosts | medium | LiquidActionRouter.swift | Boosts only via content-type fit in the scorer |

Log markers emitted by the Phase 59 selftest audit runner:

```
[ActionQualityAudit] status=<pass|fail> issues=10
[ActionQualityFinding] issue=<...> severity=<low|medium|high> file=<...> recommendation=<...>
```

## What Phase 59 changes

`Intelligence/LiquidActionQuality.swift`: `FocusedContentType` + `ContentTypeClassifier`
(what is focused, not which terms tripped), `ActionContract` per action (required/forbidden
content types, evidence requirements, surface ceiling), `UsefulActionScorer` (real
differentiated relevance with generic penalty and floating thresholds), floating quality
gate, and feedback learning wired from DurableMemory into routing. Term lists may inform
*classification only* — no term unlocks an action directly.

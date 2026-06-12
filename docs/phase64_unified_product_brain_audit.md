# Phase 64 — Unified Product Brain: Breakage Audit & Repair Plan

Date: 2026-06-12. Sources: code inspection + latest dogfood log.

`[Phase64BreakageAudit] status=fail issues=9` (pre-repair).

## Local repo verification

- Root: `/Users/duncanyu/Documents/GitHub/contextual`, branch `main`, **not a worktree** (two linked worktrees exist elsewhere; untouched).
- Cleanup: **33 untracked Codex/AG artifacts deleted** (28 `patch_*.py`/`fix_*.py`, 2 `.rb` pbxproj scripts, 3 `temp_*.swift`) after verifying zero references in pbxproj/source. Backed up to `/tmp/p64_artifact_backup`. 19 *tracked* legacy root scripts (hooks/sandbox era) kept — flagged for a separate, deliberate cleanup since deleting tracked files is a bigger decision.
- **No `.gitignore` existed at all** — created one (build/, DerivedData/, .DS_Store, xcuserdata, patch scripts, agent sandboxes).

`[Phase64RepoAudit] root=/Users/duncanyu/Documents/GitHub/contextual worktree=no dirty_files=35 root_artifacts=33_deleted_19_kept_tracked`

## What Phase 63 changed (and what it broke)

Phase 63 added good *models* — `UnifiedSuggestion`, `UnifiedSurfaceArbiter`, `CurrentFocusSummary`, `DebugMode`, `UnifiedSuggestionRow`, panel sections — and then wired them in a way that disconnected nearly every real producer from the UI.

### Finding 1 (critical): result-card pipeline stubbed dead
`AppState.requestResultSurface` was reduced to "wrap card in one UnifiedSuggestion";
it **no longer sets `activeFloatingResultSurface`/`activePanelResultSurface`**, and
`debugResultSurfaceState` returns `nil // Stub for compiler` while
`reportResultSurfaceRender` is a "Telemetry stub". But
`ContextExecutionResult.requestAndVerify` still polls `debugResultSurfaceState(...).proofVisible`
for 2 s → always nil → **every cognitive action execution returns `.failedSilent`** and
no result card ever renders. The Phase 58.6 card UI (views still exist and still read
the active surfaces) is unreachable.

### Finding 2 (critical): the panel reads a decision nobody writes
`AssistantPanelView` now renders **only** `unifiedSurfaceDecision.panelSections`.
The only writers are: the gutted result-card wrapper and `showUnifiedFloatingSuggestion`
— each of which **replaces the entire decision with a single candidate**. The
PanelBridge still computes `panelActions` (liquid + cheap + music + friction + setup)
and stores them in `appState.availableActions`… which the new panel never reads.
The dogfood log contains **zero `[UnifiedSurfaceArbiter]` decisions** across the whole
session. Panel empty ⇔ working as (mis)wired.

### Finding 3 (high): last-writer-wins surface stomping
`updateUnifiedSurface(availableActions:…)` arbitrates *only the caller's candidates*
and overwrites `unifiedSurfaceDecision` wholesale. Any source that publishes erases
every other source. This is the architectural inverse of "one candidate pool."

### Finding 4 (high): ambient floating deleted, not replaced
`maybeShowAmbientJarvisFloatingSuggestion` body: *"Disabled in Phase 63 to allow
UnifiedSurfaceArbiter to decide"* — but nothing routes those candidates to the
arbiter. The float lane was amputated.

### Finding 5 (high): old systems still decide upstream
`LiquidSurfaceBridge`, `CheapAlwaysOnPortfolio`, `MusicSuggestion`, `ActionPortfolio`,
`FinalSelection`, `LiquidPortfolioMerge` all still run their own selection and only
*sometimes* hand a single winner to `showUnifiedFloatingSuggestion`. `FinalSelection
winner=none` then means nothing reaches the unified surface at all — even when the
panel planner produced six useful candidates.

### Finding 6 (medium): fake verification state
The rewritten `ResultSurfaceCardState.proofVisible` is hardcoded (`return true` for
result/captureNeeded) — render proof is no longer proof. Combined with Finding 1 it's
doubly broken: the fake value sits behind a stub that never returns it.

### Finding 7 (medium): ContextAwarenessUI says no_context / IntentSynthesis stale_context
24 occurrences in the latest log. These read context through paths that predate
`CurrentFocusSummary`; with the unified surface empty, downstream stages see "no
context" even though browser metadata was available in the same tick.

### Finding 8 (medium): technical suggestions gone
Technical/code/log actions flowed through the same panel publish path → same Finding 2
black hole. Nothing technical reaches `unifiedSurfaceDecision`.

### Finding 9 (low): Phase63SelfTest tests models, not wiring
It validates UnifiedSuggestion construction/adapters in isolation — it never asserts
that real producer output reaches `unifiedSurfaceDecision`. That's how this shipped
green while the product went blank.

`[Phase64BreakageFinding] issue=result_card_pipeline_stubbed file=App/AppState.swift severity=high fix=restore_presentation_and_verification`
`[Phase64BreakageFinding] issue=panel_reads_unwritten_decision file=App/AppDelegate.swift severity=high fix=unified_product_brain_at_publish_point`
`[Phase64BreakageFinding] issue=last_writer_wins_stomping file=App/AppState.swift severity=high fix=single_writer_merge_semantics`
`[Phase64BreakageFinding] issue=ambient_float_amputated file=App/AppDelegate.swift severity=high fix=route_through_brain`
`[Phase64BreakageFinding] issue=legacy_systems_still_select file=Intelligence/ContextEventProducer.swift severity=high fix=demote_to_candidate_producers`
`[Phase64BreakageFinding] issue=fake_proof_visible file=Intelligence/ContextExecutionResult.swift severity=medium fix=real_visibility_tracking`
`[Phase64BreakageFinding] issue=technical_suggestions_black_holed file=App/AppDelegate.swift severity=medium fix=panel_publish_through_brain`
`[Phase64BreakageFinding] issue=shallow_phase63_selftest file=App/Phase63SelfTest.swift severity=low fix=phase64_wiring_tests`

## What was preserved (valid Phase 63 work)

`UnifiedSuggestion` model + adapters, `UnifiedPanelSection` taxonomy,
`CurrentFocusSummary` shape, `DebugMode`, the section-based panel UI, and
`UnifiedSuggestionRow`. Phase 64 keeps all of these and makes them *authoritative*
instead of decorative.

## Repair design

1. **Restore result cards**: real `requestResultSurface` (sets active surfaces per
   `floatingAllowed`/`panelAllowed`), real `reportResultSurfaceRender` visibility
   tracking, real `debugResultSurfaceState` — `requestAndVerify` works again.
2. **`UnifiedProductBrain`** (new): one entry point at the panel publish moment
   (`publishDynamicOnlyReasonedActions`) — every source (panel bridge actions
   incl. liquid/cheap/music/friction/setup/technical, composed plans from
   `ComposedActionPlanner` for the current content type, ambient/TES floats) is
   normalized into one `UnifiedCandidatePool`, deduped, cooldown-filtered, and
   arbitrated once. Single writer of `unifiedSurfaceDecision`.
3. **Merge semantics**: `showUnifiedFloatingSuggestion` merges a floating candidate
   into the existing decision; it can no longer erase the panel.
4. **Floating policy**: chosen by the brain; panel stays populated when floating is
   silent; cooldowns penalize candidates, not whole families.
5. **Technical/capture restoration**: composed plans (code/log, forum, lease, listing,
   capture-first) injected as candidates at the publish point.
6. **Debug gating**: registry/ontology dumps behind `DebugMode`; product traces stay.

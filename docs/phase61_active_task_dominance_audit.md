# Phase 61 — Active-Task Dominance Audit

Date: 2026-06-12. Source of truth: `docs/log.rtf` (fourth dogfood, 09:13) + code inspection.

## Local repo verification

- `pwd` / `git rev-parse --show-toplevel`: **/Users/duncanyu/Documents/GitHub/contextual** ✓
- `git worktree list`: primary checkout (main) here; two *linked* worktrees exist
  (`contextual.worktrees/agents-architectural-pivot-direct-runtime`,
  `.claude/worktrees/gracious-jones-e6145d`) — **neither is being edited**.
- All Phase 58.6–61 files are modified/untracked directly in the primary checkout
  (`Intelligence/ProposalWorthiness.swift`, `LiquidActionQuality.swift`, … present on disk here).
- Phase 60 *is* in the live app path: the dogfood log contains Phase 60 markers
  (`[ProposalWorthinessGate]`, `[ComparableCandidateDetector]`, `[BrowserActivityClassifier]`),
  so the user ran the modified build. The failure is real behavior, not a stale binary.

`[LocalRepoVerification] root=/Users/duncanyu/Documents/GitHub/contextual worktree=no status=pass`

## The exact chain (acceptance requirement)

Minecraft YouTube focused + Gmail/Kijiji-messages/Facebook-housing/Rentals.ca-leads in background:

```
[TabClusterWorkflow] workflow=rental_search confidence=0.86 authority=workspace_only   ← (1) background tabs detected,
[DeterministicWorkflowClassifier] workflow=rental_search …                                  authority computed as workspace_only…
[SemanticGroundingBypass] reason=deterministic_workflow_high_confidence               ← (2) …and then IGNORED: returns anyway, bypasses semantics
[ComparableCluster] type=rental size=2 coherence=1.00 comparable=yes                  ← (3) two BACKGROUND tabs form a cluster
[BrowserActivityClassifier] activity=comparison_decision …                            ← (4) background cluster sets the ACTIVITY
[ProposalWorthinessGate] id=compare_open_tabs surface=floating allowed=yes (once)     ← (5) focused "How To…Quarry" counted as a
                                                                                            candidate → currentFocusIsCandidate=true
[ContextualActionSet] content_type=media_page workflow=rental_search actions=compare… ← (6) rental/research actions in the panel
[PanelFallback] stored … contract_id=missing                                          ← (7) deterministic panel bridge stores them
```

## Answers to the ten questions

1. **Why can TabClusterWorkflow set rental_search from background tabs?**
   `deterministicRentalWorkflow` computes `focusSupported` (false for the quarry title),
   logs `authority=workspace_only` — **and then returns the workflow anyway.** The
   authority label is decorative, exactly like Phase 59's discarded `rental_search`
   label before it. The fallback `rentalTerms` branch in `detect()` has the same hole:
   it counts hits over the whole haystack including background tabs.

2. **Why does panel_background authority still drive selection?** Nothing consumes it.
   `route()` receives `detectedKinds` containing `.rentalSearch` with no notion of
   where the detection came from.

3. **Why does deterministic bypass semantic grounding?** A flat confidence check
   (`>= 0.80`) prints `[SemanticGroundingBypass]` with no source check — background
   tab matches can hit 0.86 trivially (3 matched tabs).

4. **Why can background-only candidates set activity=comparison_decision?**
   `ComparableCandidateDetector` has **no relation model**: a cluster is a cluster.
   `BrowserActivityClassifier` trusts `cluster.comparable` without asking whether the
   *focused tab* belongs to it.

5. **Why doesn't the Minecraft focus override the rental tabs?** Two bugs compound:
   (a) no authority model (above); (b) `currentFocusIsCandidate` is true if the focused
   title is *any* candidate category — "How To Build The Ultimate Quarry" is an
   "article" candidate, so the *rental* cluster inherited current-focus credit. That is
   how compare **actually floated once** in this log (`allowed=yes reason=worthy_comparison_decision`).

6. **Why do workflow=browser_research and rental_search coexist?** Research detection
   accepts `cluster.comparable` regardless of cluster authority, so the background
   rental cluster simultaneously powers research detection on a media page.

7. **Why does PanelFallback store contract_id=missing?** `DeterministicCapabilityPanelAction`
   only carries a contract for *layout* actions; everything else legitimately stores
   `nil` and the log prints "missing". Misleading log, but the real issue is that the
   bridge trusts whatever the planner emitted with no quality check of its own.

8. **Why don't panel actions face floating-grade discipline?** They actually flow
   through `route()` contracts (Phase 59+) — but the contracts were *satisfied* by the
   background cluster. Garbage authority in, valid contract out. The bridge then adds
   them with `SuggestionSurfacePolicy` (an older surface check), never re-validating
   quality.

9. **Is Phase 60 in the live path?** Yes — its log markers appear throughout the
   dogfood log. Phase 60 worked as built: floating was (mostly) suppressed. It was
   built one layer too late: the *inputs* (workflow, activity, comparability) were
   already poisoned by background tabs.

10. **What still uses the old deterministic panel path?** `DeterministicPanelActionPlanner`
    (Phase35ContextLayer) → `PanelBridge` (AppDelegate) is the live panel path; it
    *includes* the liquid router output, so fixing authority upstream fixes the panel —
    plus this phase adds explicit gates at the bridge so the discipline is enforced and
    visible there too.

## Findings register

| # | Issue | Severity | File | Recommendation |
|---|---|---|---|---|
| 1 | `authority=workspace_only` computed then ignored — background tabs define workflow | high | LiquidActionRouter.swift | Background-sourced deterministic workflow returns nil for current task |
| 2 | `rentalTerms` fallback counts background tabs | high | LiquidActionRouter.swift | Gate on `rentalFocusSupported(currentFocus)` |
| 3 | SemanticGroundingBypass has no source check | high | LiquidActionRouter.swift | `[SemanticGroundingBypassCheck]`: only current-focus detections may bypass |
| 4 | No cluster relation/authority model | high | ProposalWorthiness.swift | `ComparableClusterAuthority`: current/related/background/stale |
| 5 | `currentFocusIsCandidate` ignores *which* cluster | high | ProposalWorthiness.swift | Membership in the winning cluster (category or shared topic) |
| 6 | Background cluster sets activity=comparison_decision | high | ProposalWorthiness.swift | Activity requires current/related cluster authority |
| 7 | comparable/multipleSources evidence granted from background clusters | high | LiquidActionQuality.swift | Evidence requires current/related authority |
| 8 | Panel bridge re-validates nothing | medium | App/AppDelegate.swift | `[PanelFallbackCheck]`/`[PanelWorthinessGate]` membership gates |
| 9 | Background-cluster labels read as current-task ("Capture rental listings" on Minecraft) | medium | LiquidActionRouter.swift | `[ActionTargetTruth]`; isolation removes them from current task entirely |
| 10 | No runtime proof of build identity | low | App/AppDelegate.swift | `[Phase61RuntimeMarker]` at startup |

```
[ActiveTaskDominanceAudit] status=fail issues=10
[ActiveTaskDominanceFinding] issue=<...> severity=<...> file=<...> recommendation=<...>
```

## What Phase 61 changes

The current focused page defines the current task. Background clusters are demoted to
background memory: they cannot define workflow, cannot set activity, cannot grant
comparable/multi-source evidence, cannot float, and cannot enter the current-task panel.
Deterministic workflow detection from background tabs no longer bypasses semantic
grounding. The panel bridge enforces and logs the same discipline. A runtime marker
proves the build identity at startup.

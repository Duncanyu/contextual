# Phase 60 — Proposal Worthiness Audit

Date: 2026-06-11. Source of truth: `docs/log.rtf` (third dogfood, 21:20) + code inspection.

Verdict up front: **the user is right — Phase 59 added a gate, not a generator.** The
system is still score-shaped, not product-shaped. Every layer asks "can this action
run?" and "does it clear a number?" No layer asks "is this worth interrupting a person
who is texting on WhatsApp?" The exact chain that floated `compare_open_tabs` over six
unrelated tabs is reconstructable line by line, and every link is a design flaw, not a
threshold mistuning.

`[ProposalQualityAudit] status=fail issues=10` (pre-60 state; the selftest re-verifies).

---

## The exact chain (acceptance requirement)

```
[EvidenceQuality] tabs=6                                  ← WhatsApp + Gmail + CIBC + Outlook + Facebook + ChatGPT
[ResearchWorkflowDetected] confidence=0.80 signals=tabs:6 ← (1) 3+ tabs in a browser IS "research"
[ContentTypeClassifier] selected=generic_webpage          ← (2) WhatsApp title has no chat/inbox keyword → fallback
[ActionContractCheck] id=compare_open_tabs passed=yes     ← (3) multipleSources := tabs≥3 ∧ sourceLike(generic_webpage)
[UsefulActionScore] … value=0.35 … final=0.66             ← (4) weighted sum: cost=1.0 + focus_fit=0.80 bury value=0.35
[UsefulnessThreshold] threshold=0.62 passed=yes           ← (5) one blended number, no floors
[ActionPreflight] expected_value=high                     ← (6) compare branch overwrites the honest 0.35 with "high"
[FloatingExpectationCheck] expected_result=comparison honest=yes ← (7) tier-1 metadataNote = "can run" = "honest"
[LiveLiquidOverride] old_winner=capture_visible_page new_winner=compare_open_tabs ← (8) existence beats quality
[TickReasoning] selected=compare_open_tabs                ← (9) nobody asked "worth it?"
[SuggestionSurfaceContract] accept_behavior=execute_direct ← (10) one tap executes a fake comparison
```

## Answers to the ten questions

1. **Why does a normal browser session become browser_research?**
   `WorkflowDetectors.detect()`: `isBrowser && (tabTitles.count >= 3 || workflow == "researching")`
   → unconditional `browser_research` at confidence 0.5 + tabs×0.05. Six tabs of any
   kind = confidence 0.80. There is no topic-coherence requirement at all.

2. **Why does tabs:6 imply research?** Same line. Tab *count* is the only signal.
   Gmail+CIBC+Outlook+Facebook+ChatGPT+WhatsApp is indistinguishable from six rental
   listings.

3. **Why do unrelated tabs satisfy compare_open_tabs?** Phase 59's
   `EvidenceSnapshot.multipleSources` is `tabTitles.count >= 3 && sourceLike(contentType)`
   — and `genericWebpage` is in the sourceLike set. "Multiple sources" was implemented
   as "multiple tabs while on a vaguely webby page." My own Phase 59 shortcut; it
   recreated the tab-count heuristic one layer down.

4. **Why does value=0.35 still produce final=0.66?** The scorer is a pure weighted sum:
   `0.18·focus + 0.22·content + 0.20·evidence + 0.16·value + 0.12·specificity + 0.12·cost`.
   `value` carries 16% of the weight, so cost=1.0 (it's cheap to run!) and
   focus_fit=0.80 (inherited from the bogus research confidence) drown it. **There are
   no per-factor floors** — a catastrophically low value can be averaged away.

5. **Why no generic/overpromise penalty for compare_open_tabs?** `genericUtilityIds`
   lists collect/save/brief utilities but not compare; compare is `isSpecificAction`
   so it dodges every generic demotion. And nothing models overpromise: a metadata-only
   "Compare open tabs" *promises a comparison it cannot produce*.

6. **Why does metadata-only unrelated-tab comparison count as "honest"?**
   `ActionLabelTruthCheck` only checks tier-2 actions for capture phrasing. compare is
   tier 1 (metadataNote executes from metadata), so it's auto-honest. "Can execute" was
   conflated with "label matches outcome."

7. **Why expected_result=comparison?** Same check: tier 1 + label contains "compare" →
   `expected=comparison`. The preflight compare branch then sets `expectedValue="high"`
   whenever the contract ceiling wasn't capture — overwriting the scorer's honest 0.35.

8. **Why can Liquid override cheap/default just because it exists?**
   `ContextEventProducer`: `liquidWorkflowAvailable` = "≥2 specific liquid panel
   actions exist" → unconditional `[LiveLiquidOverride]`. Existence, not quality, wins.

9. **Why does the floating arbiter care about executability over worthiness?**
   `floatingCandidate` checks: specific? read-only? tier 1? threshold? — all
   *eligibility*. Interruption cost, activity sensitivity (banking! messaging!),
   current-vs-background evidence, and result quality are not modeled anywhere.

10. **Why was the user interrupted instead of silence?** Because no layer is allowed
    to choose silence. The pipeline's terminal states are "float the winner" or "no
    candidate happened to survive." Silence as a *deliberate, logged success state*
    does not exist.

## Findings register

| # | Issue | Severity | File | Recommendation |
|---|---|---|---|---|
| 1 | tabs≥3 ⇒ browser_research, no coherence check | high | LiquidActionRouter.swift | Research requires a coherent topic cluster |
| 2 | multipleSources = tab count + sourceLike content | high | LiquidActionQuality.swift | ComparableCandidateDetector with topic coherence |
| 3 | compare contract satisfiable by unrelated tabs | high | LiquidActionQuality.swift | Require comparable candidates; suppress if unrelated |
| 4 | Weighted sum has no floors; value=0.35 floats | high | LiquidActionQuality.swift | Hard floors: value≥0.60, result≥0.65, focus≥0.60, evidence≥0.60 |
| 5 | preflight overwrites honest value with "high" | high | LiquidActionRouter.swift | Expected result derives from evidence, never bucket |
| 6 | No activity model (communication/finance/normal browsing) | high | (missing) | BrowserActivityClassifier; sensitive contexts force silence |
| 7 | Metadata compare deemed honest, expected_result=comparison | medium | LiquidActionQuality.swift | MetadataOverpromiseCheck; capture_first framing |
| 8 | LiveLiquidOverride on existence, not worthiness | high | ContextEventProducer.swift | LiquidOverrideCheck: worthy + better than default |
| 9 | No silence-first policy; floating is the default | high | LiquidActionRouter.swift, ContextEventProducer.swift | SilenceDecision as logged success state |
| 10 | accept_behavior=execute_direct for ambiguous compare | medium | App/AppState.swift | ask_first / capture_first downgrades |

```
[ProposalQualityAudit] status=fail issues=10
[ProposalQualityFinding] issue=<...> severity=<...> file=<...> recommendation=<...>
```

## What Phase 60 changes

`Intelligence/ProposalWorthiness.swift`: `BrowserActivityClassifier` (what is the user
*doing*), `ComparableCandidateDetector` (are there really ≥2 things worth comparing),
and `ProposalWorthinessGate` (is this worth an interruption) with hard per-factor
floors. Research detection requires topic coherence. Compare contracts require
comparable candidates. Liquid override requires worthiness. Floating becomes rare;
silence becomes a first-class, logged outcome.

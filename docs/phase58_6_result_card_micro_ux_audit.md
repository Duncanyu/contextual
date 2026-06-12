# Phase 58.6 — Result Card Micro-UX Audit

Date: 2026-06-11. Source of truth: `docs/log.rtf` (dogfood run of 2026-06-11) + code inspection.

Verdict up front: **the result card is backend output shoved into UI.** The pipeline
(formatters → presenter → surface state → SwiftUI) carries full execution artifacts —
markdown documents, raw action IDs, debug enums, char counts — all the way to a
300×220 floating window with no presentation layer in between. Two of the most
visible "features" of Phase 58.5 (follow-up buttons on result cards) literally do not
render on success cards, and half the follow-up IDs are dead on click.

`[ResultCardUXAudit] status=fail issues=9` (state before 58.6; the selftest re-emits
this with per-finding pass/fail after the fixes).

---

## 1. Where result text is generated

`LiquidInsightFormatters.format(action:text:scope:)` and
`LiquidInsightFormatters.metadataNote(action:signals:)` in
`Intelligence/LiquidActionExecution.swift`. Output is a **full markdown document**
(`# Header`, multi-paragraph bullets with `> quote` lines, italics footer). Memory
notes (`liquidMemoryNote`) build similar documents. These are panel-shaped artifacts;
nothing else exists.

## 2. Where result text is shortened — nowhere

`presentCognitiveResultSurface` (`Intelligence/ContextExecutionResult.swift:725`)
passes the full text into `ResearchResultCardState.text`. The floating card
(`UI/FloatingSuggestionView.swift:251`) renders it inside a 150-pt `ScrollView`.
Log evidence: `[ResultSurfaceRender] capability=extract_obligations type=result
visible=yes frame=(10,0,300,220) output_chars=2014` — a 2,014-char essay in a
300×220 card. There is no summary/detail split of any kind.

## 3. Where follow-up buttons are generated

`CapabilityExecutor.generateFollowUps` (`LiquidActionExecution.swift:61`) — hardcoded
ID lists per action/scope. Two structural bugs:

- **Self-follow-ups**: the documentsLeases failure list contains
  `extract_obligations`, so `extract_obligations` offers itself
  (log line 3223: `actions=capture_full_agreement,select_a_clause,extract_obligations,…`,
  and the success path line 3334 offers `extract_obligations` after `extract_obligations`).
- **Dead IDs**: 8 of the follow-up IDs exist nowhere — not in the ontology, not in
  `CognitiveCapabilityRegistry`: `capture_listing_pages`, `compare_by_features`,
  `open_agreement_beside`, `capture_full_agreement`, `select_a_clause`,
  `ask_for_missing_info`, `save_decision_table`, `compare_agreement_to_listing`.
  Clicking one hits `handleResultCardAction` → `not_in_registry` → **nothing happens**.
  Half the follow-up buttons are decorative.

## 4. Where follow-up buttons are labeled

`presentCognitiveResultSurface` line ~870:
`WorkflowActionOntology.byId[$0]?.title ?? $0`. For the 8 dead IDs the fallback is the
**raw snake_case ID**, straight into the UI. Log evidence:
`[ResultCardFollowUpButton] id=compare_open_tabs title="capture_listing_pages"`.

## 5. Where follow-up buttons are ranked/capped — nowhere

No ranking, no dedup, no cap. Follow-ups are appended after up to 4 static failure
actions (`defaultFailureActions`: Capture visible page, Capture full document, Test
content acquisition, Dismiss), so a capture-needed card stacks up to **8 full-width
buttons**. Log evidence: `frame=(10,-133,300,486)` — a 486-pt-tall floating card,
taller than its own anchor window.

Worse: for **success** cards the buttons silently vanish.
`ResultSurfaceCardState.actions` (`App/AppState.swift:2891`) returns `[]` for the
`.result` case, and the `resultCard()` view renders only Copy/Open Panel. The
`[ResultCardFollowUpButton]` log prints from the *pre-conversion* card, so **the log
claims buttons the user never sees.** Dogfood's "sometimes there are no useful
follow-ups" is this: success cards drop them all.

## 6. Where source labels are shown

Three competing systems, none consistently human:
- `humanSourceLabel(scope)` (good copy: "visible part of agreement") — used only in
  the markdown footer text.
- `scopedSourceBadge` in the card footer: "AX · visible content", "Meta" — jargon.
- `issueCard`'s metadata block prints raw internals directly:
  `Reason: too little text`, `Source: AX`, **`Visible chars: 43`**,
  `Next step: capture visible`. Char counts and reason enums in user UI.

## 7. Where debug/internal terms could leak

- `issueCard` metadata block (above) — leaks by design, every failure card.
- `lowQualityMessage` (`ContextExecutionResult.swift:1886`) embeds
  `Source: \(source)\nVisible chars: \(chars)` into card body text.
- `sanitizeUserVisibleOutput` strips `chars=`/`source=` lines from generated text,
  but the UI then re-adds the same data as chrome — the sanitizer and the UI
  disagree about the contract.
- Raw follow-up IDs (finding 4) are themselves debug leaks.

## 8. How floating cards differ from panel cards — they don't

`UI/AssistantPanelView.swift:312` renders the *same* `ResultSurfaceCardContent` with
the same hardcoded `frame(width: 300)` and the same 150-pt scroll. "Open Panel" shows
the identical 300-pt card in a different window. There is no detail surface, so
compressing the floating card without building a real panel detail path would orphan
the content.

## 9. Product-polished vs backend-shaped

Polished (keep): scope-truth titles (`specificCaptureTitle`, `humanResultTitle`),
the output-quality gates (Phase 56–58), `sanitizeUserVisibleOutput`'s intent,
metadata notes that say they're metadata-based.

Backend-shaped (fix): everything the user actually sees on a card below the title —
body length, button labels, button count, dead buttons, source chrome, debug
metadata rows, identical floating/panel rendering, and titles that occasionally
promise more than the scope can deliver (`compare_open_tabs` floating title at
metadata-only scope reads as a comparison; the click delivers a limitation note).

---

## Findings register

| # | Issue | Severity | File | Recommendation |
|---|-------|----------|------|----------------|
| 1 | 2,000-char markdown rendered in 300×220 floating card | high | UI/FloatingSuggestionView.swift | Compress to ≤3 bullets + next-step line; full text panel-only |
| 2 | Raw snake_case follow-up labels in UI | high | Intelligence/ContextExecutionResult.swift | Central label map + sanitizer; never `?? rawID` |
| 3 | 8 follow-up IDs dead on click (not in registry) | high | Intelligence/LiquidActionExecution.swift | Resolve through alias map to real capabilities; drop unresolvable |
| 4 | Self-follow-ups (extract_obligations → extract_obligations) | high | Intelligence/LiquidActionExecution.swift | Ranker removes self + dupes |
| 5 | No follow-up cap; 8-button piles, 486-pt card | high | App/AppState.swift, UI | Budget: floating 3, panel 5; rank before cut |
| 6 | Success cards silently drop all follow-ups; logs claim otherwise | high | App/AppState.swift (ResultSurfaceCardState) | Carry actions through `.result`; log only what renders |
| 7 | `Visible chars: 43`, `Source: AX`, reason enums in user UI | high | UI/FloatingSuggestionView.swift | Human source line only; debug to logs |
| 8 | Floating and panel cards identical; no detail path | medium | UI/AssistantPanelView.swift | Host-aware layout: compact floating, detailed panel |
| 9 | Missing-context cards lack "how to fix" instruction + next best action | medium | Intelligence/LiquidActionExecution.swift | Structured missing-context builder: what/why/how/next |

Corresponding log lines (emitted by the Phase 58.6 selftest audit runner):

```
[ResultCardUXAudit] status=<pass|fail> issues=9
[ResultCardUXFinding] issue=<...> severity=<low|medium|high> file=<...> recommendation=<...>
```

## What 58.6 changes

A single presentation layer (`Intelligence/ResultCardPresentation.swift`) between
execution results and SwiftUI: presentation policy (per-surface budgets), summary
compressor, follow-up label sanitizer + resolver + ranker, missing-context card
builder, human source-scope presenter, and a final UI copy gate. The UI renders only
what passes the gate, host-aware (floating = glanceable summary, panel = detail).

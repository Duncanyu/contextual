# Agentic Experimental v1 — Freeze Checklist

**Product boundary decision.** Agentic computer control is no longer the
center of Contextual. It is now a bounded experimental subsystem. The core
product is Jarvis-style ambient intelligence: observe, classify, suggest,
summarize, and deterministically automate — not arbitrary GUI clicking.

This document is the v1 freeze checklist. After this freeze, do not extend
agentic control. Pivot the project to Phase B (Workflow Intelligence / Ambient
Jarvis).

---

## PASS — Frozen and shipping

These capabilities are reliable, bounded, and required for v1. Treat as frozen.

| Capability             | Surface                                                                 |
|------------------------|-------------------------------------------------------------------------|
| Observe Screen         | `AgenticObserver.observe()` — quality scoring, post-control awareness   |
| OCR                    | `OCRGroundingExtractor` + perception coordinator                        |
| AX                     | `AccessibilityGroundingExtractor`, `DirectAgentGrounder` (quality gate) |
| Target-window capture  | `ScreenCaptureSource.findActiveWindowAndScreen` + `TargetWindowAnchor`  |
| Scroll                 | `executeScrollSmall` — bounded CGEvent scroll wheel                     |
| Type text              | `executeTypeText` — bounded Unicode keyboard events                     |
| Press key              | `executePressKey` — whitelist of return/esc/tab/arrows/cmd-chords       |
| Safe stop              | `AgenticStopCondition` covers success / failure / unsafe / grounding    |
| Failure reporting      | `[AnswerGate] blocked reason=…`, `[AgenticMode] unsupported_goal …`     |
| Performance bounded    | VLM 1.5 s, AX walk 0.15 s, per-step budgets enforced                    |

---

## EXPERIMENTAL / OPT-IN — Off by default, gated

| Capability                       | Gate                                                                |
|----------------------------------|---------------------------------------------------------------------|
| Visual click grounding           | `CONTEXTUAL_ENABLE_EXPERIMENTAL_CLICK=1` **and** smoke-test pass    |
| Arbitrary website navigation     | Same gate as click                                                  |
| Multi-step computer operation    | Same gate as click                                                  |

Mode is announced on every run:

```
[AgenticMode] mode=experimental_control
[AgenticMode] reason=visual_grounding_unreliable
[AgenticMode] click_enabled=no  reason=experimental_disabled
[AgenticMode] click_enabled=no  reason=grounder_smoke_failed
[AgenticMode] click_enabled=yes reason=explicit_opt_in_smoke_passed
```

Smoke test is the single source of truth:

```
CONTEXTUAL_RUN_VISUAL_GROUNDING_SELFTEST=1
```

Records pass/fail to `AgenticExperimentalMode.recordSmokeTestResult(…)`.

---

## FAIL / OUT OF SCOPE for v1

These are explicitly **not** v1 commitments. Do not add code for them.

- Reliable arbitrary GUI clicking
- OpenAI Operator–style autonomous control
- Full autonomous browsing
- Multi-application orchestration
- New VLM grounding architectures
- New planners or memory layers for control

---

## Honest failure contract

If a goal implies clicking and click is disabled (or the only click attempt
failed), the runtime **must not** report `stop_success` or
`controlled_success`. It must return the explicit failure copy:

> I can read and summarize this screen, scroll, type, and use keyboard
> shortcuts, but visual clicking is currently disabled because grounding is
> experimental.

This is enforced in `runDirectAgentLoop`:

- `clickDisabledButRequired` → `stopReason = .grounding_unavailable`,
  status `.grounded_observation_only`, answer = `unsupportedClickAnswer`.
- `allInteractionsFailed` → `stopReason = .grounding_unavailable`,
  status `.no_progress`.

---

## Performance contract

| Operation                  | Budget   | Enforced by                          |
|----------------------------|----------|--------------------------------------|
| Visual grounding request   | 1.5 s    | `VisualGrounder.timeoutMs`           |
| AX tree walk               | 0.15 s   | `DirectAgentGrounder.timeLimit`      |
| Per-loop step              | bounded  | `plan.maxSteps`, `maxRuntimeSeconds` |
| Total loop                 | bounded  | `runtimeSeconds` budget remaining    |

No moondream/minicpm timeout path during normal use because click is off by
default — the loop never enters visual grounding at all.

---

## What ships with v1

- `observe_screen` / `scroll` / `type_text` / `press_key` / `wait`
- `answer` / `stop_success` / `stop_missing_context`
- Honest failure when click is required but disabled
- `[AgenticMode]` banner on every run
- Smoke test for the experimental click path

That is enough for Agentic Experimental v1.

---

## After freeze: Phase B (Workflow Intelligence / Ambient Jarvis)

Next phase, **not implemented in this freeze**:

- Detecting current user activity from passive signals
- Classifying workflows (browsing, writing, debugging, comparing, etc.)
- Suggesting helpful actions in-context
- Deterministic lightweight automations
- Proactive but non-annoying assistance

Agentic Experimental remains available as a subsystem when Phase B benefits
from it, but it is no longer the project's center of gravity.

---

## Freeze sign-off

- [x] `[AgenticMode]` banner present and logs the active gate
- [x] `click_element` removed from default direct-agent menu
- [x] `CONTEXTUAL_ENABLE_EXPERIMENTAL_CLICK` + smoke-test gate wired
- [x] Honest failure answer surfaces when click is required but disabled
- [x] No repeated failed-click loop when click is disabled
- [x] All non-click control actions preserved
- [x] Build green

When all boxes are checked, Agentic Experimental v1 is **FROZEN**.

# Contextual — Next Repair Phase: Automatic Visible-Content Acquisition

Status: architecture review by Opus 4.8, grounded in source (not `results.md`'s summary).
Scope: make "click an action → app auto-acquires the needed visible content → resumes → shows a useful result" actually happen in live dogfood.

> Blunt framing up front: `results.md` overclaims. It lists `UniversalContentReader` as
> "live wired: Yes / Working: Yes." It is not wired into the live execution path at all — only
> into self-tests and `UCRDogfoodMode`. The app has **three** separate "capture" code paths and the
> one the live click actually runs captures **nothing**. That is the bug, not "OCR budget is too low."

---

## Section 1 — Diagnosis (the real root cause)

The repeated claim "we know we need `visible_ocr` but stay metadata-only" is a *symptom*. The root cause is that **content acquisition was never actually connected to the live execution path**, and the one place real OCR works is reachable only from tests. There are three capture implementations and they are not the same code:

1. **Real, working OCR** — `UniversalContentReader.routeOCR` (`Intelligence/UniversalContentReader.swift:918`) does the real thing: `ScreenCaptureSource.captureSingleFrame()` → `OCRProcessor.shared.recognizeText()` → text with confidence. It works. **Callers: only `Phase46SelfTest`, `Phase51RescueSelfTest`, `UCRDogfoodMode`.** Nothing on the live click path calls `UniversalContentReader.read()`.

2. **Dead stub OCR** — `SurgicalOCR.extract` (`Intelligence/SurgicalOCR.swift:38`) computes a crop rect from AX frames and then `return []` with `regions=0 reason=crop_only_no_capture_in_phase20d_scope`. It never captures a pixel. **And this is the one the ambient path uses:** `OnDemandContextAcquisition.requestOCR` (`Intelligence/Phase31DebugInfra.swift:195`) calls `SurgicalOCR.extract(...)`. So ambient OCR returns 0 chars **even when the budget allows it** — the budget gate is a red herring on top of a no-op.

3. **No-op acquisition primitive** — the live composed-plan path runs `PrimitiveActionRuntime.runAcquisition` (`Intelligence/PrimitiveActionRuntime.swift:1264`). For every `capture_*` primitive with no `inputText` already present, it returns `status: "needs_context"`, summary `"needs capture"`. It does **not** call `ScreenCaptureSource`, `OCRProcessor`, or `UniversalContentReader`. It only passes through text that some upstream stage already put in `inputText`.

On top of those three, two more defects guarantee starvation:

- **The ambient cache throws away text.** `ContextAcquisitionCoordinator.CachedVisibleResult` (`Phase35ContextLayer.swift:2266`) stores `axChars: Int` and `ocrChars: Int` — **counts, not text**. Even on the rare path where acquisition produced characters, the text is discarded; only the count survives to nudge an evidence level. So there is no text in any cache for an action to read later, by construction.
- **`allowedLevel` collapses everything non-explicit to metadata/structured.** `ContextAcquisitionCoordinator.allowedLevel(for:)` (`Phase35ContextLayer.swift:2377`): ambient (`explicitUserInitiated == false`) can never reach `.visibleRegion`; even a `.visibleRegion` desire downgrades unless `explicitUserInitiated && allowExpensive`. And `acquire()` only runs OCR when `request.allowExpensive` is also true (`:2333`).

Now answer the specific questions:

- **Why do actions route but fail?** Routing (`UnifiedActionDispatcher.dispatch`) resolves capability/alias/executor correctly and dispatches. But the execution path reads content from a pre-built envelope (`ContextExecutionEngine` consumes `axFragments`, `snapshot.selectedText`, `pageCtx` — `ContextExecutionEngine.swift:153-185`) or from the composed-plan `inputText`. Nothing along that path triggers acquisition. With an empty envelope/inputText, the cognitive step has zero characters and reports `needs_context`.
- **Why does visible content acquisition fail?** Because the live path that needs it (composed-plan acquisition primitive, capability executor) has no acquisition implementation wired to it. The only working acquisition (`UCR.routeOCR`) is in a sibling module that the live path doesn't call.
- **Why does OCR not run when needed?** Two independent reasons stacked: (a) the ambient path routes OCR into the `SurgicalOCR` stub that returns `[]`; (b) the budget gate blocks `.visibleRegion` for non-explicit requests anyway. Fixing only the budget would still yield 0 chars because of the stub.
- **Why do followups not rescue the action?** `UnifiedActionDispatcher.executeFollowupCapability` (`UnifiedActionDispatcher.swift:241`) treats a followup as a fresh capability run with an `allow_clipboard_capture` flag and a loose `source_action_id` string in a `[String: Any]` dict. There is no suspended parent, no continuation token, no captured-context bundle, no resume target. The "parent" is re-executed from scratch with the same empty envelope, so it fails the same way. It is a re-try, not a resume.
- **Which part of the architecture is conceptually wrong?** The ownership model. Acquisition is split across `ContextAcquisitionCoordinator` (ambient, count-only, stub OCR), `UniversalContentReader` (real OCR, test-only), `PrimitiveActionRuntime.runAcquisition` (no-op), and `BrowserContextExtractor` (metadata + frames, no body text). No single component *owns* "get me usable text for this action, by the cheapest sufficient means, and keep it." `UniversalContentReader` is a pure read-gate that asserts on text it never fetches for the live path. That gate-only stance is the conceptual error.

---

## Section 2 — Target architecture

The corrected loop, with the component that owns each step:

```
Observe                  ContextEventProducer / temporal stream
 → interpret focus       CurrentFocusSummary + BrowserContextStrategy.assess (current-focus-first)
 → decide needed context UnifiedProductBrain / LiquidActionRouter declare each action's contextRequirement
 → acquire cheapest      UniversalContentReader.readOrAcquire(...) (NEW: orchestrates, does not just gate)
 → generate candidates   LiquidActionRouter + CheapAlwaysOnPortfolio, pooled by UnifiedProductBrain
 → render honest actions UnifiedProductBrain.decide (only show actions whose requirement is satisfiable)
 → execute action        UnifiedActionDispatcher → CapabilityExecutor / ComposedPlanExecutor
 → if missing context    CapabilityExecutor yields .needsContext(kind) → ActionExecutionSession suspends
 → acquire automatically UniversalContentReader.readOrAcquire(userInitiated:true, parentActionID:...)
 → resume action         ActionExecutionSession.resume(token, bundle) re-enters the SAME step with text
 → show result           ContextExecutionResult → ResultCardPresentation → AppState.requestResultSurface
 → offer followups        followups inherit the captured ContextBundle by token (not a re-run)
```

Key components and responsibilities (target state):

- **UniversalContentReader (UCR)** — the single owner/orchestrator of content acquisition. New entry point `readOrAcquire(_ request:) async -> ContentReadResult`. Owns route ordering (selected → browser AX → OCR segmented → full doc → metadata), caching, source/quality/confidence, and the decision of whether the action can continue. Replaces the gate-only stance. Absorbs the real OCR it already has plus segmentation.
- **ContextAcquisitionCoordinator (in `Phase35ContextLayer.swift`)** — demoted to *ambient policy + cheap metadata/AX prefetch only*. It stops being a second acquisition engine. It no longer calls `SurgicalOCR`. It exposes the *policy* (`allowedLevel`) and a typed cache that UCR can read/write, but UCR is the one that runs OCR.
- **Phase35ContextLayer / allowedLevel** — becomes an `AcquisitionPolicy` consulted by UCR, not an independent fetcher. New input: `trigger ∈ {ambient_tick, user_click, followup_resume}`. `user_click` and `followup_resume` are sufficient consent for cheap+medium local capture (selected text, browser AX, segmented OCR of the focused window). Ambient stays metadata/AX unless a high-confidence trigger requests a prefetch.
- **SurgicalOCR** — promoted from stub to the real **region segmentation** layer. It does the cropping, region classification (chrome / tab strip / side tabs / content / sidebar), OCR-box grouping, and confidence scoring. It calls a box-returning OCR (extended `OCRProcessor`). It outputs a `ContentExtractionResult`. UCR calls SurgicalOCR for the `ocr_visible_content` route.
- **BrowserContextExtractor** — keep as the AX metadata + frame + (NEW) AX body-text source. Add `visibleBodyText` extraction from `AXWebArea` static-text descendants so the `browser_ax` route can beat OCR when AX is rich. Feeds AX frames to SurgicalOCR as region hints.
- **OCRProcessor** — extended to optionally return per-line boxes `[(text, CGRect, confidence)]` (it currently discards `obs.boundingBox`). Segmentation needs boxes.
- **ScreenCaptureSource** — keep. Already supports `captureSingleFrame(targetAnchor:)` and window-rect resolution; used to crop to the focused window before OCR.
- **UnifiedProductBrain** — keep as the single writer of `appState.unifiedSurfaceDecision`. New responsibility: only renders an action as executable if its declared `contextRequirement` is *satisfiable* (capability present + acquisition route exists), so we stop rendering metadata-only actions that can't acquire what they need.
- **UnifiedActionDispatcher** — keep as the click router, but the followup branch (`executeFollowupCapability`) is replaced by `ActionExecutionSession` suspend/resume. Followups dispatch with a continuation token, not a re-run flag.
- **CapabilityExecutor / ComposedPlanExecutor** — gain the ability to *yield* `.needsContext(kind)` and be *resumed* with a `ContextBundle`. The composed-plan acquisition primitive (`runAcquisition`) stops returning a dead `needs_context` and instead calls `UCR.readOrAcquire`.
- **ContextExecutionResult / ResultCardPresentation** — unchanged contract, but cards carry the `ContextBundle` token so followups inherit it. Missing-context cards built by `MissingContextCardBuilder` only appear when acquisition genuinely failed (permission/quality), never as the default.
- **temporal stream / current-focus dominance / background-tab demotion** — keep the Phase 61/62 rules (background tabs are workspace memory, cannot define current task). Acquisition must capture **only the focused window**, and OCR segmentation must reject background-tab text as page content (`contamination_warnings`).

---

## Section 3 — UniversalContentReader redesign

Today UCR is `read(request:) -> UniversalContentResult` plus `gate(...)` / `resolveActionScope(...)` — synchronous, fetch-then-assert, and only called from tests. The redesign makes it the async orchestrator the live path calls.

New request/result (extends existing `UniversalContentRequest` / `UniversalContentResult` / `ContentSource` / `ContentQuality` — do not invent a parallel type system):

```swift
struct ContentReadRequest {
    let capabilityID: String          // e.g. "extract_key_claims"
    let neededKind: NeededContextKind  // .visiblePageText, .selectedText, .fullDocument, .codeOrLog, .metadataOnly
    let activeApp: AppFocus            // bundleId, name, pid, window title, window bounds
    let browser: BrowserContext?       // from BrowserContextExtractor (url, tabs, selectedTitle, AX frames)
    let allowedCost: CostCeiling       // .cheap | .medium | .expensiveExplicit (medium == segmented OCR of focused window)
    let trigger: AcquisitionTrigger    // .ambientTick | .userClick | .followupResume
    let privacy: PrivacyMode           // existing enum (.standard/.strict)
    let deadline: TimeInterval         // budget, e.g. 3.0s for click, 1.0s for ambient
    let parentActionID: String?        // set when resuming a suspended action
}

struct ContentReadResult {
    let text: String
    let source: ContentSource          // existing enum, extended: ocrVisibleContent, browserAX, googleDocsCapture, pdfText, metadataFallback
    let quality: ContentQuality        // existing
    let confidence: Double
    let regions: ContentRegions?       // content_rect, tab_strip_rects, source_rects (from SurgicalOCR)
    let warnings: [ContentWarning]     // .chromeOnly, .backgroundTabContamination, .lowConfidence, .stale
    let canContinue: Bool              // true => action proceeds; false => show setup/missing-context
    let blockedReason: BlockedReason?  // .permissionDenied, .chromeOnly, .belowQualityFloor, .focusChanged, .none
    let scopeClaim: ContentScope       // honesty: AX/OCR can NEVER claim full_page/full_document (ContentScopeModel)
}

enum UniversalContentReader {
    static func readOrAcquire(_ request: ContentReadRequest) async -> ContentReadResult
}
```

`readOrAcquire` algorithm (cheapest sufficient, short-circuit on first usable):

1. **Check current context first.** If the focused window already has fresh, in-scope text in the typed cache (keyed by window+url+scroll+contentHash), return it. (`source = cached`.)
2. **Selected text** (`routeSelectedTextAX` + context-model snapshot — already exist). If meaningful (≥ N chars and matches goal), return.
3. **Browser AX visible text** (NEW `BrowserContextExtractor.visibleBodyText`). If rich enough, return `source = browserAX`. Beats OCR when present.
4. **Segmented OCR of the focused window** via `SurgicalOCR` (NEW real impl) — only if `allowedCost >= .medium` *and* policy says the trigger permits it. Returns `page_content_text` only (chrome/tabs stripped). If `content_rect` confidence too low or only chrome found → `warnings += .chromeOnly`, `canContinue = false`.
5. **Full document** (`google_docs_capture`, `pdf_text`, `routeFileBacked` — exist) only when `neededKind == .fullDocument` and cost allows.
6. **Metadata fallback** — only to *describe* a missing-context state, never to feed a cognitive action (enforced by `ContentScopeModel`).
7. **Cache the winning result with its text** (not just counts) and return.

How this differs from today: today UCR *reads a cache it does not populate for the live path and asserts*. The redesign *fetches* along a cost-ordered ladder, *persists the actual text*, *segments OCR*, and returns a `canContinue`/`blockedReason` so the executor knows whether to proceed or surface honest setup. The `gate()`/`resolveActionScope()` logic survives as the internal "is this enough for the goal" check inside `readOrAcquire`, not as the public API.

---

## Section 4 — Automatic acquisition policy

Encoded in `AcquisitionPolicy` (the rehomed `allowedLevel`):

- **Ambient OCR:** essentially never on a plain tick. Ambient stays `.cheap` (metadata + AX prefetch). The only ambient OCR allowed is a *single* speculative segmented OCR when (a) the focused window changed, (b) a high-confidence content-dependent action is about to be proposed, and (c) we have not OCR'd this window+url+scroll signature within the TTL. This is opt-in per-tick, rate-limited, never every tick.
- **Click-triggered OCR:** allowed. **Clicking a user-visible action is sufficient consent to run cheap+medium local capture for that action.** This is the central rule. `trigger == .userClick` raises the ceiling to `.medium` (segmented OCR of the focused window only).
- **Avoiding OCR on every tick:** OCR is pull-based off clicks/resume, plus the one rate-limited speculative ambient case. There is no per-tick OCR loop. Cost gate: `allowedCost` defaults `.cheap` for ambient, `.medium` for click, `.expensiveExplicit` only for an explicit "capture full document" user action.
- **Caching key:** `windowID | bundleID | url | scrollSignature | contentHash(first+last visible line)`. Scroll signature comes from AX `AXScrollPosition`/`AXValue` when available, else a coarse hash of the top OCR line. TTL ~20–30s (matches existing `cacheTTL = 30`).
- **Staleness:** invalidate on focus change, window resize, url change, or scroll-signature change. A cached entry whose window is no longer frontmost is `warnings += .stale` and not returned for a fresh click.
- **Background-tab contamination:** acquisition only ever captures the **focused window** crop (current-focus dominance). OCR segmentation explicitly drops the tab strip / side-tab regions from `page_content_text`. Background tab *titles* may only appear in `tab_titles_text`, never in `page_content_text`. If page-content region is empty but tab text is present → `chrome_only` rejection.
- **Free/cheap path:** metadata + selected text + browser AX text. No screen capture.
- **Requires explicit user action:** full-document capture (Google Docs full scroll, PDF whole-file), VLM/visual descriptor (kept `not_wired`, manual last resort only).
- **What happens on click of a content-dependent action:** dispatcher sees the capability's `neededKind`, calls `UCR.readOrAcquire(trigger: .userClick, allowedCost: .medium)`. UCR runs the ladder, returns text + `canContinue`. If `canContinue`, the action executes immediately with no extra user step. If not, an honest missing-context card with a real next step.

---

## Section 5 — SurgicalOCR segmentation design

SurgicalOCR stops being "crop a rect, return []." It becomes the region engine. **Prerequisite:** `OCRProcessor` must expose boxes — it currently iterates `VNRecognizedTextObservation` and discards `obs.boundingBox` (`OCRProcessor.swift:41-50`). Add:

```swift
struct OCRLine { let text: String; let rect: CGRect; let confidence: Float } // rect in image px (un-normalized)
func recognizeLines(from image: CGImage) async -> [OCRLine]
```

SurgicalOCR I/O:

```swift
struct SurgicalOCRInput {
    let windowBounds: CGRect          // focused window, screen coords (ScreenCaptureSource resolves)
    let axWebAreaFrame: CGRect?       // from BrowserContextExtractor
    let axScrollAreaFrame: CGRect?
    let browser: BrowserContext?      // tab titles, selected title → text matching
    let appKind: AppKind              // browserTopTabs | browserVerticalTabs | docs | pdf | codeEditor | logWindow | unknown
}
struct ContentExtractionResult {     // == the shape the prompt asked for
    let pageContentText: String
    let tabTitlesText: String
    let selectedTabTitle: String?
    let chromeText: String
    let sidebarText: String
    let contentRect: CGRect
    let tabStripRects: [CGRect]
    let sourceRects: [CGRect]
    let confidence: Double
    let source: ContentSource        // .ocrVisibleContent here
    let contaminationWarnings: [ContentWarning]
}
```

Region detection pipeline:

1. **Capture** focused-window crop via `ScreenCaptureSource.captureSingleFrame(targetAnchor:)`; get image + px dims.
2. **OCR boxes** via `OCRProcessor.recognizeLines`; map normalized Vision rects to px (flip Y).
3. **Seed regions from AX.** If `axWebAreaFrame` exists and is sane (inside window, area > 30% of window), trust it as the content rectangle seed. This is the cheap, high-confidence path. AX frames are the *hint*, OCR boxes are the *evidence*.
4. **Chrome / tab-strip detection** (geometry + text patterns):
   - **Top tabs:** a horizontal band in the top ~8% of the window with several short boxes of similar height/baseline, many matching `browser.tabTitles`. That band → `tabStripRects`; its text → `tab_titles_text`.
   - **Address bar / toolbar:** the band just below tabs containing a box matching a URL pattern (`^https?://` or host fragment) → `chrome_text`.
   - **Vertical / side tabs:** a tall narrow column (width < ~18% of window) on the left or right whose boxes match `browser.tabTitles` → side-tab region, removed from content.
   - **Sidebars:** a tall column adjacent to content, not matching tab titles, with link-like short lines → `sidebar_text` (kept separate; not page body).
5. **Content rectangle** = window minus (top chrome band + side-tab/sidebar columns + bottom status bar). Intersect with `axWebAreaFrame` when present. Boxes inside it → `page_content_text` in reading order (sort by y, then x).
6. **Selected tab title:** prefer `browser.selectedTitle` (AX `AXSelected`); else the tab-strip box visually emphasized / matching the window title prefix.
7. **OCR box grouping:** cluster boxes into paragraphs by vertical gap and x-overlap before joining, so `page_content_text` reads naturally.
8. **Confidence scoring:** `confidence = f(AX-frame agreement, fraction of boxes confidently classified, content-area coverage, tab-title match rate)`. AX-seeded + high coverage → high. Geometry-only guess → medium. No content region → low.
9. **Fallback when geometry is uncertain:** if AX frames are garbage and no clear chrome band is found (`confidence < floor`), do **not** dump the whole screen as page content. Either (a) return content = full window minus only the matched tab-title boxes, with `warnings += .lowConfidence`, or (b) if even that is dominated by tab/link text → `contaminationWarnings += .chromeOnly`, `pageContentText = ""`, let UCR mark `canContinue = false`. Returning honest emptiness beats returning chrome as content.

Per-layout heuristics:
- **Top tabs (Chrome/Safari/Firefox default):** top band = tabs, next band = omnibox; content below.
- **Vertical tabs (Arc, Edge vertical, Firefox sidebar):** left column = tabs; content to its right.
- **Fullscreen browser:** no OS chrome; tab band may be hidden — rely on AX `AXWebArea` frame as content; if absent, treat near-full window as content with low-confidence flag.
- **Reddit/forum:** content is the central column; right rail (subreddit info) → `sidebar_text`; left nav → sidebar. Keep only the central column as page body.
- **Google Docs:** the editing canvas is the content rect; ruler/toolbar/comments rail are chrome/sidebar. Full-doc text needs `google_docs_capture` (scroll), not single-frame OCR — single frame is "visible page" only.
- **PDF/document viewer:** page area is content; thumbnail rail = sidebar; prefer `pdf_text` route over OCR when the file is reachable.
- **Code editor / log window:** monospaced lines; gutter line-numbers column → strip; the editor pane is content; the file tree → sidebar; integrated terminal at bottom is a separate region (`codeOrLog` kind).

No VLM. VLM/visual descriptor stays `visual_descriptor_not_wired_yet` and is a manual last resort only.

---

## Section 6 — Followup continuation model (suspend/resume)

Replace the re-run-with-a-flag approach (`UnifiedActionDispatcher.executeFollowupCapability`) with a real session machine.

```swift
struct ActionExecutionSession {
    let sessionID: String
    let parentActionID: String
    let capabilityID: String
    let contextRequirement: NeededContextKind   // what the action is waiting for
    let continuationToken: UUID                  // opaque resume handle stored on the result card / followup
    var capturedBundle: ContextBundle?           // text + source + quality + regions + warnings (filled on capture)
    let resumeTarget: ResumeTarget               // .capability(id) | .composedPlanStep(planID, stepIndex)
    let createdAt: Date
    let focusSignature: String                   // window+url at suspend time
    let expiresAt: Date                          // e.g. createdAt + 60s
}

struct ContextBundle {                           // the inherited payload
    let text: String
    let source: ContentSource
    let quality: ContentQuality
    let confidence: Double
    let regions: ContentRegions?
    let warnings: [ContentWarning]
    let capturedAt: Date
}
```

Flow:

1. Capability executes, finds insufficient text, **yields** `.needsContext(.visiblePageText)` instead of failing. Executor creates an `ActionExecutionSession`, stores it in a `SessionStore` keyed by `continuationToken`, and emits a "capturing…" surface (not a dead button).
2. UCR runs `readOrAcquire(trigger: .followupResume or .userClick, parentActionID:)` automatically — no second user click required in the common case. (If acquisition needs explicit consent, e.g. full-doc, *then* a single capture button carries the `continuationToken`.)
3. On success, `capturedBundle` is filled. The executor **resumes the same `resumeTarget`** with the bundle — re-enters the exact capability/step, now with text. Composed plans resume at the *failed step index*, carrying the bundle forward, not from the top.
4. Result card is shown with the real output.
5. **Followups inherit the bundle:** each followup button carries the parent's `continuationToken`; when clicked it reads `capturedBundle` from the `SessionStore` instead of re-acquiring. `FollowupContextInherited` logs `context_bundle=yes`.
6. **Expiration / staleness:** session expires after ~60s or when `focusSignature` no longer matches the frontmost window. Resuming a stale session → `ActionResumeAborted reason=context_changed`, and the UI offers "re-capture on current window" rather than silently using old text.
7. **Cancellation on focus change:** if the user switches apps mid-capture, abort the resume (don't OCR the wrong window) and keep the session for a short grace period in case they switch back.

Why the current model fails: `executeFollowupCapability` has no session, no token, no bundle. It passes `source_action_id` as a loose string and re-invokes the capability against the *same empty envelope*; "capture" never actually happens (the acquisition primitive is a no-op), so the parent fails identically. There is nothing to resume because nothing was ever suspended.

---

## Section 7 — Result card / UI behavior

What the user sees per case (all copy through `ResultCardPresentation`; `UICopyGate` blocks raw ids/snake_case/oversized bodies — already exists, keep enforcing):

1. **Enough context, completes:** result card with output. `[ActionResultUI] shown=yes type=success`.
2. **Needs context, auto-captures:** transient "Reading the page…" state (spinner), no button to click. Auto-capture runs.
3. **Auto-capture succeeds, resumes:** spinner → result card. No intermediate "capture done" dead-end.
4. **Auto-capture fails (permission/setup):** honest missing-context card with the *one* real next step (e.g. "Allow Screen Recording in System Settings" deep-link), built by `MissingContextCardBuilder`. Not a generic "not enough content."
5. **Context changed mid-capture:** "The page changed — re-read current window?" single actionable button bound to a fresh session. Never silently use stale text.
6. **Content too low quality:** "Couldn't read enough of this page" + next-best (e.g. "Select the text you want and retry"). No fake result.
7. **OCR found only chrome/tabs:** treat as failure-with-reason: "I can see the tabs but not the page content yet — scroll the page into view and retry." `[OCRContentRejected] reason=chrome_only`.

Never show: dead followup buttons, capture-needed loops, dev/fake followups, internal snake_case, or "not enough content" with no next step.

---

## Section 8 — Integration with existing systems

| System | Verdict | Action |
|---|---|---|
| **ContextAcquisitionCoordinator** (`Phase35ContextLayer.swift`) | **modify/demote** | Stop being a 2nd acquisition engine. Remove its `SurgicalOCR.extract` call. Becomes ambient policy + cheap metadata/AX prefetch; expose `AcquisitionPolicy` + typed text cache for UCR. |
| **Phase35ContextLayer / allowedLevel** | **modify** | Re-home as `AcquisitionPolicy` keyed on `trigger`. `user_click`/`followup_resume` ⇒ `.medium`. Keep `nextContextNeeded` vocabulary. |
| **UniversalContentReader** | **modify (promote)** | Add `readOrAcquire`; make it the live, async, fetching orchestrator with text caching + segmentation + `canContinue`. Keep `gate`/`resolveActionScope` internal. |
| **SurgicalOCR** | **modify (implement)** | Replace stub with real segmentation returning `ContentExtractionResult`. |
| **OCRProcessor** | **modify** | Add `recognizeLines` returning boxes; keep existing `recognizeText`. |
| **BrowserContextExtractor** | **modify** | Add `visibleBodyText` (AX static-text under `AXWebArea`); keep metadata + frames. |
| **ScreenCaptureSource** | **keep** | Already supports targeted window crop. |
| **UnifiedProductBrain** | **keep + extend** | Only render actions whose `contextRequirement` is satisfiable. Stays sole writer of `unifiedSurfaceDecision`. |
| **LiquidActionRouter** | **keep** | Each generated action declares its `neededKind`. |
| **CheapAlwaysOnPortfolio** | **keep** | Cheap actions are metadata-only by contract; unchanged. |
| **UnifiedActionDispatcher** | **modify** | Replace `executeFollowupCapability` with `ActionExecutionSession` suspend/resume + token dispatch. |
| **CapabilityExecutor / ContextExecutionEngine** | **modify** | Gain `.needsContext` yield + resume; on `needsContext`, call `UCR.readOrAcquire` rather than failing. |
| **ComposedPlanExecutor / PrimitiveActionRuntime.runAcquisition** | **modify** | `capture_*` primitives call `UCR.readOrAcquire` instead of returning dead `needs_context`. Resume at failed step with carried bundle. |
| **ContextExecutionResult** | **keep + extend** | Carry `continuationToken`/bundle on cards & followups. |
| **DynamicActionUX** | **delete later** | Superseded by UnifiedProductBrain (per `results.md`/memory). Don't let it own UI. |
| **VisibleGeneratedAction** | **keep** | As a render model only. |
| **InlineAssistance** | **keep, audit** | Ensure it routes content needs through UCR, not its own reader. |
| **old panel systems** | **delete later** | UnifiedProductBrain is authoritative. |
| **HookCatalog / action ontology** | **keep ontology, delete legacy hooks later** | Actions still flow through `WorkflowActionOntology`/router (memory rule). |
| **PrimitiveActionRuntime** | **keep, modify acquisition only** | Registry/validator/executor stay; only acquisition primitives get real capture. |
| **ComposedActionClickDispatcher** | **modify** | Honor continuation tokens for composed followups. |
| **workspace / durable memory** | **keep** | Captured bundles may be persisted to the active window's compartment for short-term reuse. |
| **temporal stream / compartments** | **keep** | Source of current-focus dominance; acquisition reads focus from here. Background-tab demotion rules (Phase 61/62) must not regress. |

---

## Section 9 — Minimal staged implementation plan

Small, safe, ordered. Each stage is independently shippable and dogfoodable.

### Stage 1 — `UniversalContentReader.readOrAcquire` (orchestrator shell)
- **Files:** `Intelligence/UniversalContentReader.swift` (new async entry, reuse existing routes), new `Intelligence/ContentReadTypes.swift` (request/result/bundle/policy enums).
- **Behavior:** add `readOrAcquire` that runs the existing routes in cost order, persists *text* in a new typed cache, returns `canContinue`/`blockedReason`. No new capture yet — wraps what exists (selected/AX/file/metadata + existing real `routeOCR`).
- **Risks:** double-acquisition with the ambient coordinator; mitigate by reading the coordinator's cache first.
- **Acceptance logs:** `[ContentReadRequest] action=… needed=… source=…`, `[ContentReadResult] source=… chars=… quality=…`.
- **Dogfood success:** calling `readOrAcquire` on a selected-text page returns the selection without any followup.

### Stage 2 — click-triggered automatic visible-content capture
- **Files:** `Actions/UnifiedActionDispatcher.swift`, `Intelligence/ContextExecutionEngine.swift` / CapabilityExecutor, `Intelligence/Phase35ContextLayer.swift` (`AcquisitionPolicy` with `trigger`).
- **Behavior:** on click of a content-dependent capability, dispatcher calls `UCR.readOrAcquire(trigger:.userClick, allowedCost:.medium)` *before* executing; `user_click` raises ceiling to allow OCR. Uses the existing real `routeOCR` (full-frame for now).
- **Risks:** OCR latency on click (bounded by 3s deadline already in `routeOCR`); show spinner.
- **Acceptance logs:** `[AcquisitionPolicy] trigger=user_click allowed_level=visible_region reason=action_requires_visible_text`, `[ContentAcquireAttempt] route=… status=…`, `[ContentReadResult] source=ocr_capture …`. (Interim full-frame: `source=ocr_capture`, not `ocr_visible_content`; `page_content_text` may still contain chrome/tab text until Stage 3. Do **not** hold Stage 2 to the chrome-stripped bar — that arrives in Stage 3.)
- **Dogfood success:** click "extract key claims" on an article with no selection → OCR runs → action produces real output (even if it includes some chrome text). **This is the first end-to-end win.**

### Stage 3 — real `SurgicalOCR` segmentation
- **Files:** `Intelligence/SurgicalOCR.swift` (real impl), `Intelligence/OCRProcessor.swift` (`recognizeLines` with boxes), `Intelligence/BrowserContextExtractor.swift` (`visibleBodyText`).
- **Behavior:** UCR's OCR route switches from full-frame to segmented `ContentExtractionResult`; chrome/tabs stripped from `page_content_text`.
- **Risks:** AX frame garbage (known); fallback heuristics + `chrome_only` rejection handle it.
- **Acceptance logs:** `[OCRRegionDetect] window=… content_rect=… chrome_rects=… confidence=…`, `[OCRContentExtracted] chars=… region=page_content confidence=…`, `[OCRContentRejected] reason=chrome_only`.
- **Dogfood success:** on a Reddit/forum page, `page_content_text` contains the post, not the tab titles or sidebar.

### Stage 4 — capture-result caching (text, not counts)
- **Files:** `Intelligence/UniversalContentReader.swift`, `Intelligence/Phase35ContextLayer.swift` (replace `CachedVisibleResult` count fields with text-bearing entries or add a parallel text cache).
- **Behavior:** captured text is cached by `window|url|scrollSig|hash`, TTL ~25s, invalidated on focus/scroll/url change.
- **Risks:** stale text → wrong answers; staleness invalidation is the mitigation, surface `warnings=.stale`.
- **Acceptance logs:** `[ContentCache] store key=… chars=…`, `[ContentCache] hit key=… ttl_s=…`, `[ContentCache] invalidate reason=focus_changed`.
- **Dogfood success:** clicking two actions on the same page OCRs once; second is a cache hit.

### Stage 5 — parent action suspend/resume
- **Files:** new `Actions/ActionExecutionSession.swift` (+ `SessionStore`), `Actions/UnifiedActionDispatcher.swift`, CapabilityExecutor, `Intelligence/PrimitiveActionRuntime.swift`.
- **Behavior:** capability yields `.needsContext`; session created; UCR auto-acquires; resume re-enters the exact step with the bundle. Composed plans resume at failed step.
- **Risks:** timing/focus-change fragility (explicitly flagged in `results.md` §14); cover with `focusSignature` + expiry + abort path.
- **Acceptance logs:** `[ActionResume] parent=… context=visible_page_text status=resumed`, `[ActionResumeAborted] reason=context_changed`.
- **Dogfood success:** click a content action with no pre-acquired text → no manual capture step → result appears after auto-capture.

### Stage 6 — followup context inheritance
- **Files:** `Intelligence/ContextExecutionResult.swift`, `Intelligence/UnifiedProductBrain.swift` (followup model), `Actions/UnifiedActionDispatcher.swift`, `ComposedActionClickDispatcher`.
- **Behavior:** followup buttons carry the parent `continuationToken`; clicking reads `capturedBundle`, never re-acquires.
- **Risks:** token lifetime vs card lifetime; tie expiry to the card.
- **Acceptance logs:** `[FollowupContextInherited] followup=… parent=… context_bundle=yes`.
- **Dogfood success:** "draft reply" after "summarize" runs instantly on the same captured text.

### Stage 7 — old/dead UI path cleanup
- **Files:** remove/neutralize `DynamicActionUX`, old panel owners, the no-op `executeFollowupCapability` branch, the `SurgicalOCR` "crop_only" log path.
- **Risks:** hidden dependencies; do after Stages 1–6 prove the new path.
- **Acceptance:** no `regions=0 reason=crop_only…` logs remain; no dead followups in dogfood.

### Stage 8 — tests + dogfood proof (last, not first)
- **Files:** extend env-gated self-tests, but **gate acceptance on live dogfood logs**, not synthetic fixtures.
- **Dogfood success criteria:** the full acceptance log sequence in Section 10 appears in an interactive run on a real article, a Google Doc, and a Reddit page.

---

## Section 10 — Acceptance criteria (exact dogfood logs)

Success path (article, no selection, user clicks "extract key claims"):

```
[ContentReadRequest] action=extract_key_claims needed=visible_page_text source=user_click
[AcquisitionPolicy] trigger=user_click allowed_level=visible_region reason=action_requires_visible_text
[ContentAcquireAttempt] route=selected_text status=empty
[ContentAcquireAttempt] route=browser_ax status=empty
[OCRRegionDetect] window=Firefox content_rect=120,180,980,1400 chrome_rects=2 tab_strip_rects=1 confidence=0.81
[OCRContentExtracted] chars=2140 region=page_content confidence=0.81
[ContentReadResult] source=ocr_visible_content chars=2140 quality=usable can_continue=yes
[ActionResume] parent=extract_key_claims context=visible_page_text status=resumed
[ContentCache] store key=Firefox|example.com/x|scroll:0|h:9af3 chars=2140
[ActionResultUI] shown=yes type=success
[FollowupContextInherited] followup=draft_summary parent=extract_key_claims context_bundle=yes
```

Cache-hit on second action, same page:

```
[ContentReadRequest] action=create_decision_table needed=visible_page_text source=user_click
[ContentCache] hit key=Firefox|example.com/x|scroll:0|h:9af3 ttl_s=18
[ContentReadResult] source=cached chars=2140 quality=usable can_continue=yes
[ActionResultUI] shown=yes type=success
```

Failure paths (must also appear honestly):

```
[ContentReadRequest] action=summarize_visible_content needed=visible_page_text source=user_click
[ContentAcquireAttempt] route=ocr_visible_content status=attempt
[ContentAcquireFailed] reason=permission_denied
[ActionResultUI] shown=yes type=missing_context next_step=enable_screen_recording

[OCRRegionDetect] window=Chrome content_rect=none tab_strip_rects=1 confidence=0.22
[OCRContentRejected] reason=chrome_only
[ContentReadResult] source=ocr_visible_content chars=0 quality=none can_continue=no

[ActionResume] parent=extract_key_claims context=visible_page_text status=attempt
[ActionResumeAborted] reason=context_changed
```

The bar is the success block appearing in an interactive dogfood run — not a self-test asserting it.

---

## Section 11 — What not to do

- **Do not** enable global OCR on every ambient tick. OCR is pull-based off clicks/resume + one rate-limited speculative case.
- **Do not** use VLM/visual descriptor by default. It stays `not_wired`, manual last resort.
- **Do not** add more proof-only self-tests while dogfood still fails. Tests gate on live logs, written last.
- **Do not** generate actions from metadata that need content but can't acquire it. UnifiedProductBrain renders only satisfiable requirements.
- **Do not** keep capture as a manual followup loop. Click is consent; capture is automatic.
- **Do not** treat browser tab/chrome OCR as page content. Segmentation strips it; `chrome_only` is a rejection, not a result.
- **Do not** let background tabs drive current focus. Capture the focused window only (Phase 61/62 rules must not regress).
- **Do not** keep `SurgicalOCR` returning `[]` or leave the ambient path pointed at it. Don't keep `DynamicActionUX`/old panels as product owners.
- **Do not** store char counts as "context." Persist the actual text or it didn't happen.

---

## Section 12 — Implementation prompt for Codex/Antigravity

> **Task: wire automatic visible-content acquisition into Contextual's live click path.**
>
> Context: Contextual has three disconnected capture implementations. The working OCR
> (`UniversalContentReader.routeOCR` → `ScreenCaptureSource.captureSingleFrame` + `OCRProcessor.recognizeText`)
> is only called from self-tests. The ambient path (`OnDemandContextAcquisition.requestOCR` in
> `Intelligence/Phase31DebugInfra.swift`) calls `SurgicalOCR.extract`, which is a stub that returns `[]`.
> The live composed-plan path (`PrimitiveActionRuntime.runAcquisition`) returns `needs_context` and never
> captures. The ambient cache (`ContextAcquisitionCoordinator.CachedVisibleResult`) stores char counts, not
> text. Followups (`UnifiedActionDispatcher.executeFollowupCapability`) re-run the capability with a flag, with
> no suspend/resume. Fix this in small, separately-verifiable stages. Do NOT introduce VLM. Do NOT enable
> per-tick OCR. Do NOT add proof-only tests before the live path works.
>
> **Stage A — `UniversalContentReader.readOrAcquire(_ request: ContentReadRequest) async -> ContentReadResult`.**
> Add `ContentReadRequest`/`ContentReadResult`/`ContextBundle`/`AcquisitionTrigger`/`CostCeiling`/`NeededContextKind`
> in a new `Intelligence/ContentReadTypes.swift` (extend existing `ContentSource`/`ContentQuality`/`PrivacyMode`,
> don't duplicate). `readOrAcquire` runs routes in cost order — cache → selected text → browser AX text → segmented
> OCR → full doc → metadata — short-circuiting on first usable result, persisting the actual text, returning
> `canContinue`/`blockedReason`. Reuse the existing `route*` functions; wrap the existing real `routeOCR` for now.
> Log `[ContentReadRequest]` and `[ContentReadResult]`.
>
> **Stage B — click-triggered capture.** In `UnifiedActionDispatcher.dispatch`, for content-dependent
> capabilities call `UCR.readOrAcquire(trigger: .userClick, allowedCost: .medium)` before execution and pass the
> resulting text into the executor's context. Add `AcquisitionPolicy` (rehome `ContextAcquisitionCoordinator.allowedLevel`)
> so `trigger == .userClick` permits `.medium` (segmented OCR of the focused window). Log
> `[AcquisitionPolicy] trigger=user_click allowed_level=visible_region …` and `[ContentAcquireAttempt]`.
> Acceptance: clicking a content action on an article with no selection produces a real result.
>
> **Stage C — real `SurgicalOCR`.** Implement segmentation returning `ContentExtractionResult`
> (`page_content_text`, `tab_titles_text`, `selected_tab_title`, `chrome_text`, `sidebar_text`, `content_rect`,
> `tab_strip_rects`, `source_rects`, `confidence`, `source`, `contamination_warnings`). Add
> `OCRProcessor.recognizeLines(from:) -> [OCRLine]` (text+px rect+confidence; it currently discards `boundingBox`).
> Add `BrowserContextExtractor.visibleBodyText`. Detect top tabs / vertical tabs / chrome / sidebar / content rect
> using window bounds + AX `AXWebArea` frame + OCR-box geometry + tab-title text matching. Strip chrome/tabs from
> page content. If only chrome found → empty `page_content_text` + `chrome_only` warning. UCR's OCR route uses this.
> Log `[OCRRegionDetect]`, `[OCRContentExtracted]`, `[OCRContentRejected] reason=chrome_only`.
>
> **Stage D — text caching.** Cache captured text in UCR keyed by `window|url|scrollSig|contentHash`, TTL ~25s,
> invalidate on focus/scroll/url change. Log `[ContentCache] store|hit|invalidate`.
>
> **Stage E — suspend/resume.** Add `Actions/ActionExecutionSession.swift` + `SessionStore`. Capability yields
> `.needsContext(kind)` instead of failing; create a session (parentActionID, contextRequirement, continuationToken,
> resumeTarget, focusSignature, expiresAt); UCR auto-acquires; resume re-enters the exact capability/step with the
> bundle. Composed plans (`PrimitiveActionRuntime`/`ComposedPlanExecutor`) resume at the failed step. Replace
> `runAcquisition`'s dead `needs_context` for `capture_*` with a `UCR.readOrAcquire` call. Abort on focus change.
> Log `[ActionResume] status=resumed` and `[ActionResumeAborted] reason=context_changed`.
>
> **Stage F — followup inheritance.** Followup buttons carry the parent `continuationToken`; on click read
> `capturedBundle` from `SessionStore`, never re-acquire. Log `[FollowupContextInherited] context_bundle=yes`.
> Update `ContextExecutionResult`/`ResultCardPresentation` to carry the token; missing-context cards
> (`MissingContextCardBuilder`) only on genuine acquisition failure, always with a real next step.
>
> **Stage G — cleanup + proof.** Remove the `SurgicalOCR` crop-only path, the no-op followup branch, and
> dead UI owners (`DynamicActionUX`, old panels). Then extend env-gated self-tests, but gate acceptance on the
> live dogfood log sequence in this doc's Section 10 across an article, a Google Doc, and a Reddit page.
>
> Constraints: respect `ContentScopeModel` (AX/OCR never claim full_page/full_document; metadata never feeds
> cognitive actions). Keep `UnifiedProductBrain` the sole writer of `unifiedSurfaceDecision`. Keep current-focus
> dominance / background-tab demotion (Phase 61/62). Build to the fresh DerivedData binary, not the stale
> repo-local `build/DerivedData` copy. Verify each stage by interactive dogfood logs before moving on.

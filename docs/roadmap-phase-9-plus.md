# Contextual — Phase 9+ Roadmap

## Purpose

This document defines the evolution of Contextual beyond the MVP (Phases 1–8).

The goal is to transform the system from a functional assistant into a:
- reactive
- intelligent
- workflow-integrated
- eventually agentic system

This roadmap is iterative and will be expanded as each phase is completed.

---

## Current State (End of Phase 8)

The system currently has:

- Core pipeline:
  Sources → Context → Triggers → Intelligence → Actions → UI

- Working features:
  - Clipboard + selection awareness
  - Manual invocation
  - Suggestion system (in-panel)
  - Action execution (summarize, explain, rewrite)
  - Screen capture (manual)
  - OCR-based screen understanding
  - Analyze Screen action

- Limitations:
  - No proactive UI (no floating suggestions)
  - No result display (logs only)
  - Weak intelligence layer
  - Rigid action system
  - Minimal context understanding
  - No memory or personalization
  - Not yet reactive or agentic

---

## Guiding Principles

All future phases must follow:

- Maintain architecture boundaries
- Preserve local-first + privacy-first design
- Prefer simple, testable increments
- Avoid heavy AI unless necessary
- Avoid premature autonomy
- Prioritize usefulness over novelty

---

## Phase Structure

Each phase will include:

- Goal
- Key improvements
- Tickets (T#.#)
- Success criteria

Phases are appended progressively.

---

## Phase 9 — Usability Core

### Goal

Complete the core interaction loop inside the assistant panel.

Transform the system from:

Trigger → Suggestion → Action → (invisible result)

into:

Trigger → Suggestion → Action → Visible Result → User understands value

---

### Problems Being Solved

- Results are not visible (only logs)
- Actions feel unresponsive or unclear
- User does not know what input is being used
- Panel feels like a developer/debug tool
- Interaction loop feels incomplete

---

### Scope

This phase focuses strictly on improving usability within the assistant panel.

No new intelligence, reactivity, or advanced behaviors are introduced.

---

### Out of Scope

Do NOT implement in this phase:

- Floating suggestion cards
- Auto-opening panel
- Proactive triggers
- Agentic planning
- New complex actions
- Trigger/Reasoning redesign

These are handled in Phase 10+.

---

### Tickets

#### T9.1 — ResultView

Display action results inside the assistant panel.

Requirements:
- Show latest action result
- Scrollable content
- Clean, readable formatting (not logs)
- Persists until next action
- Clearly separated from debug content

---

#### T9.2 — Loading + Execution State

Make action execution visible and responsive.

Requirements:
- Show “Processing…” state during execution
- Disable action buttons while running
- Optional spinner or progress indicator

---

#### T9.3 — Input Source Preview

Show what context the assistant is using.

Examples:
- Using: Selected text (120 chars)
- Using: Clipboard
- Using: Screen (OCR, 2300 chars)

Requirements:
- Reflect current active context source
- Update dynamically per trigger

---

#### T9.4 — Panel Layout Cleanup

Transform the panel from a debug layout into a product UI.

Target structure:

[SuggestionCard]  
[Available Actions]  
[Input Preview]  
[Result View]  
[Assistant Controls]  
[Debug (collapsed)]

Requirements:
- Clear visual hierarchy
- Proper spacing and grouping
- Debug section minimized or collapsible

---

#### T9.5 — Permission + System Status

Expose system readiness clearly.

Show:
- Accessibility permission status
- Screen Recording permission status
- Local AI / model status

Requirements:
- Visible but non-intrusive
- Helps user understand why something may not work

#### T9.6 — Input Source Selection

Allow the user to choose which available input source an action should use.

Requirements:
- User can choose between available sources:
  - Selected text
  - Clipboard
  - Screen OCR
- The selected input source is shown clearly in the panel
- Suggestion cards indicate which source they will use
- Actions execute using the chosen source when possible
- No raw text is displayed
- No persistence or history
- Default behavior remains automatic priority:
  Selected text → Clipboard → Screen OCR

---

### Success Criteria

- User can clearly see action results inside the panel
- User understands what input is being used
- Actions feel responsive and predictable
- Panel feels like a usable product, not a debug tool
- No reliance on logs for core functionality
- No new UI surfaces (panel-only)

---

## Phase 10 — Proactive Suggestion Layer

### Goal

Introduce a non-intrusive, proactive suggestion system that surfaces high-value actions without requiring manual interaction.

Transform the system from:

User opens assistant → sees suggestions

into:

System detects opportunity → surfaces suggestion → user optionally engages

---

### Core Principle

The assistant must feel:

- reactive, not scheduled  
- intentional, not repetitive  
- helpful, not intrusive  

The system should not rely on rigid cooldown timers.

Instead, it should determine whether to act based on current context quality and user state.

---

### Problems Being Solved

- Assistant is fully passive
- Suggestions are hidden inside panel
- User must manually open assistant
- Cooldown system is rigid and non-adaptive
- System lacks real-time responsiveness

---

### Key Design Shift

Replace time-based cooldowns with:

**Context-aware suggestion gating**

The system should evaluate:

> “Is this suggestion worth showing right now?”

instead of:

> “Has enough time passed?”

---

### Trigger Eligibility Model (TES)

Each potential suggestion must pass a multi-factor evaluation:

- Signal strength (selection, clipboard, passive pattern)
- Context stability (has input changed?)
- User activity (typing, switching, idle)
- Recent suggestion history (accepted, dismissed)
- UI state (panel open, suggestion already visible)

Only high-confidence situations should surface UI.

Low-confidence situations must remain silent.

---

### Scope

This phase introduces:

- Floating suggestion UI
- Context-aware trigger gating (heuristic-based)
- Basic positioning
- Integration with existing suggestion system

No major AI upgrades are introduced.

---

### Out of Scope

Do NOT implement in this phase:

- Selection-anchored positioning
- Multi-step agent behavior
- Advanced reasoning models
- Memory or personalization
- UI redesign beyond minimal floating card

---

### Tickets

#### T10.1 — Floating Suggestion Card (MVP)

Introduce a lightweight floating suggestion UI.

Requirements:
- Displays a single high-confidence proposal
- Includes primary action + dismiss
- Only one card visible at a time
- Automatically disappears after short duration
- Accepting opens assistant panel

---

#### T10.2 — Panel Integration

When user accepts a floating suggestion:

- Assistant panel opens
- Context is preserved
- Action flow continues normally

---

#### T10.3 — Context-Aware Gating (TES v1)

Implement heuristic-based trigger gating.

Requirements:
- Suppress suggestions during active typing
- Suppress repeated suggestions for same context
- Prevent suggestions when panel is open
- Prevent stacking or rapid re-triggering
- Only allow high-signal contexts (selection, clipboard)

---

#### T10.4 — Suggestion Lifecycle Control

Improve suggestion lifecycle behavior.

Requirements:
- Suggestions auto-dismiss after timeout
- Dismissed suggestions are suppressed for current context
- Accepted suggestions suppress immediate follow-ups
- No duplicate suggestions for identical inputs

---

#### T10.5 — Safe Positioning (Fixed)

Render floating suggestion in a fixed, safe position.

Requirements:
- Positioned near top-right (menu bar area)
- Does not overlap critical UI
- No anchoring to selection yet

---

### Success Criteria

- Suggestions appear without manual invocation
- Suggestions feel relevant and timely
- No visible spam or rapid repetition
- User can ignore suggestions without friction
- Assistant feels more “alive” but not intrusive

---

### Resulting UX

User copies text  
↓  
Suggestion appears (top-right)  
↓  
User clicks action  
↓  
Assistant panel opens with result  

---

### Notes

This phase establishes the foundation for:

- advanced context awareness  
- smarter confidence modeling  
- future AI-based gating  

The assistant must remain conservative.

Silence is always preferred over a low-quality suggestion.

---

## Phase 11 — Intelligence Layer

### Goal

Transform the assistant from a reactive utility into an intentional, context-aware intelligence system.

The assistant should:
- understand context
- determine usefulness
- react selectively
- remain mostly silent
- surface only high-value suggestions

This phase introduces the foundation for future agentic behavior while remaining:
- local-first
- lightweight
- performance-conscious
- modular

---

## Core Philosophy

The assistant should not feel like:
- a menu of hardcoded actions
- a notification system
- a reactive macro tool
- a spammy assistant waiting for one suggestion to stick

It should feel like:
- a quiet intelligent helper
- something that understands intent
- something that only interrupts when it is confident
- something that feels fluid and adaptive

The long-term vision is:
- dynamic behavior
- adaptive actions
- context-driven reasoning
- eventually agentic assistance

The system should eventually evolve toward:
- generating its own action plans
- constructing temporary workflows
- adapting behavior based on context
- intelligently deciding when silence is better

However:

This phase does NOT implement:
- autonomous agents
- unrestricted computer control
- continuous AI loops
- heavy inference systems
- expensive background reasoning

Instead, this phase builds the architecture and intelligence foundations required for those future capabilities.

---

## Core Principle

The assistant should rarely speak.

Suggestions should be:
- high confidence
- contextually meaningful
- intentional
- useful

Silence is preferred over low-quality suggestions.

---

## Key Design Shift

Move from:

Trigger → Proposal → TES → UI

to:

Context → Intelligence → Proposal → TES → UI

TES becomes:
- a final safety layer
- a fallback suppression system

The Intelligence Layer becomes:
- the primary decision-maker

---

## Performance Philosophy

The assistant must remain lightweight.

No continuous heavy inference.

No constant LLM polling.

No expensive background loops.

All intelligence should be:
- event-driven
- incremental
- lightweight
- cached when possible
- heuristic-first unless escalation is justified

The system should:
- wake intelligently
- process quickly
- sleep aggressively

---

## Long-Term Intelligence Direction

The assistant should eventually evolve toward:

### Dynamic Action Systems

Instead of:
- fixed actions
- hardcoded proposal lists

The assistant should eventually support:
- generated intents
- adaptive actions
- temporary context-specific workflows
- composable behaviors

Future examples:
- “summarize this”
- “compare this to earlier notes”
- “rewrite this professionally”
- “extract todos”
- “explain this error”
- “prepare response draft”

Without requiring every action to be permanently hardcoded.

---

### Agentic Foundations

Future phases may introduce:
- task planning
- multi-step execution
- contextual workflows
- intent decomposition
- self-generated action chains

But only when:
- performance constraints are solved
- safety constraints are solved
- architecture is stable
- intelligence quality is high enough

This phase only prepares the infrastructure.

---

## Architecture Additions

Introduce:

### ContextFeatureExtractor
Computes lightweight structured features from context.

### ContextClassifier
Determines what type of content the user is interacting with.

### ProposalGenerationGate
Determines whether proposals should exist at all.

### ProposalScorer
Scores proposal usefulness and relevance.

### IntelligenceEngine
Central intelligence coordinator.

### SuggestionStrength
Weak / Medium / Strong suggestion categories.

---

## Intelligence Flow

Future architecture becomes:

Sources
↓
Context
↓
Context Features
↓
Context Classification
↓
Proposal Generation Gate
↓
Proposal Scoring
↓
TES Safety Layer
↓
UI Surface

---

## Intelligence Priorities

The assistant should prioritize:

1. usefulness
2. intentionality
3. low interruption frequency
4. context quality
5. confidence
6. performance efficiency

NOT:
- engagement
- suggestion frequency
- constant interaction

---

## Tickets

---

### T11.1 — Proposal Generation Gate

Prevent low-value proposals from being generated.

Requirements:
- Do not generate proposals for meaningless or low-signal contexts
- Suppress random short text
- Suppress obvious low-value situations
- Prefer no proposal over weak proposal

Examples:
- random word → no proposal
- short greeting → no proposal
- long paragraph → maybe proposal
- error log → strong proposal

This becomes the first true intelligence gate.

---

### T11.2 — Context Feature Extraction

Introduce lightweight feature extraction.

Compute:
- text length
- sentence count
- punctuation density
- question detection
- code-like patterns
- error/log patterns
- structural complexity
- formatting density

Requirements:
- local only
- fast
- no AI calls
- reusable by all future intelligence systems

---

### T11.3 — Context Classification

Classify context into categories.

Examples:
- question
- notes
- code
- error/log
- article
- random text
- command/instruction
- conversation

Requirements:
- lightweight
- heuristic-first
- modular
- extensible for future AI classifiers

---

### T11.4 — Action Relevance Scoring

Instead of always suggesting summarize/explain/rewrite:

Score action usefulness based on:
- context type
- feature set
- historical usefulness
- context complexity

Example:
- error log → explain/debug
- long article → summarize
- short message → no action

---

### T11.5 — Proposal Ranking

Rank proposals internally.

Requirements:
- best proposal only for floating UI
- secondary proposals remain panel-only
- prevent multiple equal-quality suggestions
- prioritize clarity over quantity

---

### T11.6 — Suggestion Strength Levels

Introduce:

- weak
- medium
- strong

Behavior:
- weak → suppressed entirely
- medium → panel-only
- strong → floating suggestion eligible

TES consumes suggestion strength instead of raw heuristic confidence.

---

### T11.7 — Redundancy Memory

Track lightweight interaction history.

Examples:
- repeated dismissals lower future priority
- repeated accepts slightly boost relevance
- ignored suggestions decay over time

Requirements:
- local only
- lightweight
- no persistent profiling yet
- no invasive tracking

---

### T11.8 — Dynamic Behavior Hooks

Prepare architecture for future adaptive behavior.

Introduce abstractions for:
- ActionIntent
- generated actions
- temporary workflows
- future agentic execution

Requirements:
- no autonomous execution yet
- no unrestricted computer control
- no self-modifying runtime logic

This is infrastructure only.

---

## Out of Scope

Do NOT implement yet:
- autonomous agents
- unrestricted desktop control
- background reasoning loops
- persistent memory systems
- cloud intelligence dependence
- heavy local LLM loops
- multi-agent systems
- continuous screen understanding

---

## Success Criteria

The assistant should:
- produce fewer suggestions
- produce better suggestions
- feel more intentional
- feel more context-aware
- remain lightweight
- avoid spam naturally
- rely less on hardcoded heuristics
- begin feeling adaptive and intelligent

The assistant should begin feeling:
- fluid
- selective
- aware
- quiet
- useful

Rather than:
- reactive
- noisy
- repetitive
- rigid

---

## Phase 12 — Liquid Intelligence Layer (v2)

### Goal

Introduce **multi-layer local intelligence** so the assistant can make:

- fast decisions  
- thoughtful decisions  
- minimal interruptions  

The assistant should feel:

- instant  
- intentional  
- adaptive  
- lightweight  
- quiet unless useful  

It should not feel:

- slow  
- blocked on thinking  
- fake or rule-based  
- spammy  
- constantly running  

---

### Core Principle

The assistant should not rely on a single intelligence mechanism.

It should use **layered intelligence**:

> fast → selective → deeper only when needed

---

### Updated Intelligence Flow

Context  
↓  
Heuristics (fast filter)  
↓  
Micro Intelligence (tiny local model — classification)  
↓  
IF confident → decision  
ELSE  
↓  
Local LLM (phi3) — deeper judgment  
↓  
Proposal  
↓  
TES safety fallback  
↓  
UI  

---

### Key Design Shift

Move from:

“LLM decides when needed”

to:

“A fast intelligence layer handles most decisions,  
LLM handles only ambiguity.”

---

### Performance Philosophy

All intelligence must be:

- event-driven  
- low-latency  
- cancelable  
- minimal input size  
- cached aggressively  

---

### Performance Rules

- No constant LLM loop  
- No LLM call on every selection change  
- No blocking UI on LLM  
- No full-text LLM calls by default  
- No background model spam  
- No cloud dependency  

---

### Micro Intelligence Rules

- Must run in milliseconds  
- Must be real model-based (not heuristics)  
- Must operate on compressed context only  
- Must output:
  - bestActionId
  - confidence
  - shouldSuggest  

---

### LLM Rules

LLM is:

- second-pass only  
- used only when:
  - micro decision confidence is low
  - context is ambiguous
- never blocks UI  
- always fails safely  

---

## Tickets

---

### T12.1 — Intelligence Decision Request Model

Create a structured request/response format for local intelligence decisions.

The model should decide:

- shouldSuggest  
- bestActionId  
- confidence  
- short reason  
- suggested title  

No execution. Decision only.

---

### T12.2 — Context Compression Layer

Before intelligence runs, compress context into a small safe packet.

Include:

- app name  
- window title metadata  
- source type  
- context type  
- feature summary  
- short text excerpt  

Do not send huge raw content.

---

### T12.3.5 — Micro Decision Engine (NEW)

Introduce a tiny local classification model for fast decision-making.

Responsibilities:

- take compressed context  
- output:
  - shouldSuggest  
  - bestActionId  
  - confidence  
- run in sub-20ms target  

Constraints:

- local only  
- no raw text storage  
- no large models  
- no generation (classification only)  

Notes:

- model may be ONNX / CoreML / similar  
- initial implementation may stub model loading  
- must be pluggable  

---

### T12.3 — Local Intelligence Decision Engine (UPDATED)

Acts as fallback intelligence layer.

Runs only when:

- micro decision confidence is below threshold  
- context is ambiguous  
- ProposalGate allows  
- SuggestionStrength is medium/strong  
- budget allows  

No longer primary decision-maker.

---

### T12.4 — Intelligence Budget Manager

Prevent intelligence from running too often.

Budget should consider:

- current execution state  
- recent calls  
- repeated similar context  
- model availability  
- system responsiveness  

This is not a rigid cooldown.  
It is a resource-aware permission check.

---

### T12.5 — Decision Cache

Cache intelligence decisions by privacy-safe content fingerprint.

If the same or very similar context appears again:

- reuse decision  
- avoid another model call  
- decay cache over time  

No raw text persistence.

---

### T12.6 — Multi-Layer Proposal Selection (UPDATED)

Selection logic:

1. Check cache  
2. Run MicroDecisionEngine  
3. If confident → use micro decision  
4. Else → run LocalIntelligenceDecisionEngine  
5. Apply decision  

Rules:

- Micro decision has priority when confident  
- LLM is fallback only  
- Heuristics remain safety fallback  
- Never block UI  

---

### T12.7 — Natural Proposal Titles

Allow intelligence layer to generate short, natural proposal titles.

Examples:

- “Want help understanding this error?”  
- “Want a quick summary of these notes?”  
- “Want me to explain this code?”  

Titles must be:

- short  
- safe  
- not include raw private text  

---

### T12.8 — Fallback and Timeout Behavior

If intelligence:

- fails  
- times out  
- model unavailable  
- returns invalid output  

Then:

- fall back to lower layer  
- never block UI  
- never freeze UI  
- log safely  

---

### T12.9 — Intelligence Debug Logging

Add metadata-only logs:

- when intelligence was skipped  
- when micro ran  
- when LLM ran  
- why each ran  
- what decision was returned  
- whether fallback was used  

No raw text.

---

### T12.10 — Phase 12 Tuning Pass

Tune the full intelligence loop.

Goals:

- fewer bad proposals  
- more useful proposals  
- no performance hit  
- no spam  
- minimal LLM usage  
- instant responsiveness  

---

### Out of Scope

Do NOT implement:

- autonomous agents  
- generated action execution  
- computer control  
- multi-step workflows  
- persistent personalization  
- continuous screen watching  
- cursor tracking  
- selection anchoring  
- multimodal reasoning beyond OCR  

---

### Success Criteria

After Phase 12:

- decisions feel instant  
- proposals feel more thoughtful  
- bad suggestions decrease  
- micro model handles most decisions  
- LLM runs rarely and selectively  
- no noticeable performance hit  
- assistant feels fluid and adaptive  
- TES becomes fallback, not the main brain  
- no autonomous behavior introduced  

---

## Phase 13 — Rich Context Layer

### Goal

Expand the assistant’s contextual awareness so intelligence and future dynamic actions can operate on richer, more human-like understanding.

The assistant should understand:

- what the user is doing  
- what is visible  
- what kind of workflow is happening  
- what the user likely needs  

without becoming:

- invasive  
- always-watching  
- performance-heavy  
- hardcoded to specific apps  
- noisy or creepy  

---

### Core Principle

The assistant should not continuously consume maximum context.

Instead:

> cheap context first  
> richer context only when justified

Context collection should be:

- layered  
- adaptive  
- budgeted  
- event-driven  

---

### Updated System Flow

Sources  
↓  
Cheap Context Signals  
↓  
Context Budget Manager  
↓  
Rich Context Collection (only if useful)  
↓  
Context Fusion  
↓  
Compressed Context Packet  
↓  
Intelligence Layer  
↓  
Actions / Proposals  
↓  
UI  

---

### Key Design Shift

Move from:

“React to clipboard and selected text”

to:

“Understand the user’s current situation.”

---

### Rich Context Philosophy

The assistant should become:

- more aware  
- more grounded  
- more situationally intelligent  

without becoming:

- surveillance software  
- a constant recorder  
- an always-running multimodal model  

---

### Performance Philosophy

Rich context must be:

- selective  
- scoped  
- decaying  
- interruptible  
- privacy-aware  
- compressed aggressively  

---

### Performance Rules

- No continuous full-screen AI analysis  
- No continuous OCR loops  
- No continuous audio recording  
- No always-on multimodal LLM inference  
- No constant screenshot spam  
- No raw context persistence by default  
- No cloud dependency  

---

### Context Collection Philosophy

Context sources should exist in tiers.

---

## Tier 1 — Cheap / Always-Available Context

Safe lightweight signals:

- active app  
- window title  
- selected text  
- clipboard text  
- app switching  
- focus changes  
- typing activity metadata  
- cursor activity metadata  

These may run frequently.

---

## Tier 2 — Medium-Cost Rich Context

Collected selectively:

- active window snapshot  
- OCR  
- AX hierarchy extraction  
- visible UI structure  
- window content descriptors  
- local image understanding  

These require:
- budget approval  
- freshness checks  
- usefulness justification  

---

## Tier 3 — Expensive / Sensitive Context

Highly gated:

- audio/transcription  
- continuous visual understanding  
- long-lived workflow memory  
- multimodal temporal reasoning  

These are:
- opt-in  
- manual or semi-manual  
- budget-limited  
- mostly future-facing infrastructure in Phase 13  

---

### Context Freshness Rules

Context must decay.

Old context should not contaminate:

- new selections  
- new apps  
- new workflows  
- new user intent  

The system should support:

- freshness windows  
- source expiration  
- confidence decay  
- source invalidation  
- source replacement  

---

### Privacy Philosophy

The assistant should understand context without hoarding it.

Rules:

- minimize raw data retention  
- compress aggressively  
- prefer metadata over content  
- avoid persistent raw recordings  
- never log raw sensitive context  
- only collect expensive context when justified  

---

### Multimodal Direction

The system should evolve toward:

- visual understanding  
- situational awareness  
- workflow understanding  
- intent inference  

not:

- chatbot-style interaction only  

---

## Tickets

---

### T13.1 — Context Capability Registry

Create a registry describing all context source capabilities.

Each source should declare:

- source ID  
- availability  
- permission state  
- freshness  
- collection cost  
- privacy sensitivity  
- latency category  
- manual vs automatic  
- stale state  

Examples:

- activeApp  
- windowTitle  
- selectedText  
- clipboard  
- screenOCR  
- screenVision  
- typingActivity  
- cursorActivity  
- audioInput  

This becomes the foundation for all future context decisions.

---

### T13.2 — Context Budget Manager

Introduce a budget system for context collection.

The manager decides:

- whether richer context is justified  
- whether collection cost is acceptable  
- whether enough context already exists  

Budget considerations:

- current system load  
- active action execution  
- recent expensive context collection  
- app responsiveness  
- user activity intensity  
- intelligence confidence  

This is not a rigid cooldown system.

---

### T13.4 — Visual Context Descriptor

Expand beyond OCR into lightweight visual understanding.

Possible outputs:

- editor visible  
- terminal visible  
- browser/article visible  
- chart/graph visible  
- image/media visible  
- dialog/error visible  
- form/input-heavy UI visible  

The system should extract:

- structural understanding  
- layout hints  
- UI type hints  

not full semantic reasoning yet.

---

### T13.5 — AX Window Content Extraction

Improve accessible window understanding using AX hierarchy.

Goals:

- better visible text extraction  
- UI structure understanding  
- reduced reliance on clipboard  
- app-agnostic behavior  

Requirements:

- avoid app-specific hardcoding  
- fail safely when AX is limited  
- no persistent raw UI dumps  

---

### T13.6 — Typing Activity Signals

Add lightweight typing activity awareness.

Metadata only:

- typing started/stopped  
- typing burst intensity  
- editing session activity  
- idle vs active editing  

Do NOT:

- store keystrokes  
- log typed content  
- become a keylogger  

---

### T13.7 — Cursor / Pointer Intent Signals

Add lightweight pointer-awareness.

Possible signals:

- cursor active vs idle  
- recent click intensity  
- interaction bursts  
- hovering patterns  
- user focus intensity  

Goals:

- understand interaction state  
- improve proposal timing  
- reduce interruptions during active work  

Do NOT:

- record detailed cursor history long-term  
- continuously store movement paths  

---

### T13.8 — Context Fusion Layer

Merge all active context sources into a unified structured context packet.

Responsibilities:

- resolve conflicts  
- prioritize fresher context  
- remove stale sources  
- normalize multimodal context  
- expose confidence/freshness metadata  

This becomes the canonical intelligence input.

---

### T13.9 — Context Freshness + Decay

Introduce source expiration and decay rules.

Examples:

- stale OCR expires  
- old clipboard context weakens  
- inactive typing sessions decay  
- outdated window snapshots invalidate  

Goals:

- prevent stale context contamination  
- improve proposal timing  
- improve situational accuracy  

---

### T13.10 — Rich Context Debug Logging

Add metadata-only logging for:

- source collection  
- source invalidation  
- freshness decay  
- budget approvals/denials  
- context fusion decisions  
- expensive context sampling decisions  

No raw context logging.

---

### T13.11 — Phase 13 Tuning Pass

Tune rich context behavior.

Goals:

- improve situational understanding  
- reduce unnecessary context collection  
- keep system lightweight  
- avoid creepy behavior  
- improve future action quality  
- maintain responsiveness  

---

### Exploratory / Infrastructure Hooks (NOT full implementation yet)

These are future-facing only:

- audio context  
- meeting awareness  
- continuous multimodal understanding  
- temporal workflow memory  
- persistent personalization  
- cross-device context  
- long-horizon agent planning  

Phase 13 should only prepare safe architectural hooks for these.

---

### Out of Scope

Do NOT implement yet:

- autonomous agents  
- unrestricted computer control  
- background recording systems  
- continuous audio recording  
- always-on full-screen multimodal inference  
- persistent raw surveillance memory  
- app-specific automation hardcoding  
- hidden data collection  

---

### Success Criteria

After Phase 13:

- the assistant understands richer context  
- proposals/actions feel more situationally aware  
- context collection feels adaptive and intentional  
- expensive context is collected selectively  
- stale context contamination is reduced  
- multimodal understanding groundwork exists  
- performance remains responsive  
- the assistant feels more “aware” without feeling invasive  
- the system remains local-first and privacy-first

---

## Phase 14 — Rich Context Activation

### Goal

Activate the rich context infrastructure built in Phase 13 and begin using it to meaningfully improve intelligence, proposals, timing, and future dynamic action generation.

Phase 13 built the nervous system.

Phase 14 begins teaching the assistant how to actually use it.

The assistant should begin feeling:

- situationally aware  
- adaptive  
- grounded in the current workflow  
- less random  
- less interruptive  
- more intentional  

without becoming:

- intrusive  
- over-reactive  
- constantly sampling expensive context  
- visually noisy  
- computationally heavy  

---

### Core Principle

Rich context should influence behavior.

Not merely exist.

The assistant should begin making decisions based on:

- workflow state  
- user interaction intensity  
- visible UI structure  
- contextual freshness  
- multimodal agreement  
- editing/activity state  

instead of relying primarily on:

- clipboard contents  
- selected text  
- simple heuristics  

---

### Updated System Flow

Sources  
↓  
Context Capability Registry  
↓  
Context Budget Manager  
↓  
Rich Context Collection  
↓  
Context Fusion Engine  
↓  
Canonical Fused Context Packet  
↓  
Intelligence + Proposal Systems  
↓  
Dynamic Action Selection  
↓  
UI / Interaction Layer  

---

### Design Philosophy

The assistant should stop behaving like:

> “Some text was copied.”

and start behaving more like:

> “The user is debugging code inside Xcode while actively typing and rapidly switching editor panes.”

---

### Activation Philosophy

Phase 14 is NOT about adding more sources.

It is about:

- activating existing context infrastructure  
- wiring it into decisions  
- improving timing  
- improving relevance  
- improving awareness  

The intelligence layer should finally begin consuming the fused context packet.

---

### Performance Philosophy

Rich context activation must remain:

- selective  
- event-driven  
- budget-aware  
- freshness-aware  
- cancelable  
- interrupt-safe  

Expensive context should still remain:

- sparse  
- justified  
- scoped  
- temporary  

---

### Behavioral Philosophy

The assistant should learn:

when to stay quiet.

Typing bursts, interaction bursts, rapid cursor movement, stale context, and weak multimodal confidence should all reduce interruption likelihood.

The assistant should become calmer during active work.

---

### Context-Aware Proposal Philosophy

Proposals should begin adapting to context.

Examples:

- editor visible + active typing → suppress interruptions
- error dialog + stopped typing → explain/debug proposal
- article visible + low activity → summarize proposal
- form-heavy UI + interaction burst → stay quiet
- stale clipboard + fresh AX content → prioritize AX

---

### Dynamic Action Direction

This phase begins preparing for:

- generated actions
- situational actions
- workflow-aware actions
- context-sensitive tools

but does NOT yet implement autonomous agents.

---

### Rich Context Consumption Rules

The intelligence layer should consume:

- fused context metadata
- freshness
- confidence
- multimodal hints
- interaction state
- visual descriptors
- structural UI hints

before escalating to expensive reasoning.

---

### Performance Rules

- No continuous multimodal loops
- No always-on screenshot reasoning
- No continuous OCR scanning
- No proposal spam during active interaction
- No blocking UI for context fusion
- No raw context persistence
- No cloud dependency

---

### Privacy Rules

The assistant should remain:

- local-first
- privacy-first
- minimally persistent
- metadata-oriented

Rich context should improve awareness,
not become surveillance.

---

## Tickets

---

### T14.1 — Canonical Fused Context State

Introduce a globally accessible canonical fused context packet.

Goals:

- maintain latest unified context state
- expose freshness/confidence centrally
- eliminate fragmented context access
- provide stable intelligence input

Requirements:

- lightweight updates
- freshness-aware replacement
- no raw persistence
- thread-safe access

---

### T14.2 — Rich Context Refresh Pipeline

Create a coordinated refresh pipeline for rich context.

Responsibilities:

- selective source refresh
- freshness-driven invalidation
- budget-aware collection
- asynchronous fusion updates
- cancellation support

The pipeline should avoid redundant expensive collection.

---

### T14.3 — Context-Aware Proposal Timing

Use typing/pointer/activity signals to improve interruption timing.

Examples:

- suppress during intense interaction
- allow during idle pauses
- defer during rapid editing
- soften proposal frequency during bursts

Goals:

- fewer interruptions
- calmer assistant behavior
- better timing awareness

---

### T14.4 — Rich Context Proposal Selection

Allow proposal selection to use:

- visual descriptors
- AX structure
- workflow metadata
- interaction state
- fused context confidence

Examples:

- editor + error dialog → explain/debug
- article + idle → summarize
- form-heavy UI → suppress
- terminal + stacktrace → explain

---

### T14.5 — Context-Aware Action Eligibility

Improve available action selection using fused context.

Actions should become:

- situationally aware
- workflow-aware
- multimodally informed

instead of relying mostly on selected text.

---

### T14.6 — Rich Analyze Screen Pipeline

Upgrade Analyze Screen to consume:

- OCR
- visual descriptors
- AX hierarchy
- fused context metadata
- active workflow hints

instead of OCR-only interpretation.

Still no full visual agent reasoning yet.

---

### T14.7 — Context Confidence Arbitration

Improve conflict handling between context sources.

Examples:

- stale clipboard vs fresh AX
- OCR vs visible editor metadata
- typing-active vs idle snapshot
- conflicting visual descriptors

Goals:

- reduce wrong context assumptions
- improve stability
- improve proposal accuracy

---

### T14.8 — Adaptive Context Sampling

Adjust expensive context collection dynamically.

Examples:

- active editing → reduce rich sampling
- idle reading → allow richer sampling
- repeated same workflow → reuse cached context
- weak confidence → allow richer collection

This should feel adaptive,
not cooldown-based.

---

### T14.9 — Rich Context UI Awareness

Begin lightly surfacing context awareness in the UI.

Possible metadata indicators:

- typing active
- editor visible
- browser/article visible
- OCR stale
- rich context active

No intrusive dashboards or debug spam.

---

### T14.10 — Rich Context Debug Visualization

Improve internal debugging visibility for fused context state.

Metadata-only.

Possible debug info:

- source freshness
- fusion confidence
- active visual descriptors
- interaction state
- arbitration decisions
- sampling decisions

No raw context logging.

---

### T14.11 — Phase 14 Tuning Pass

Tune rich context activation behavior.

Goals:

- reduce proposal spam
- improve timing quality
- improve situational awareness
- improve action relevance
- reduce unnecessary expensive sampling
- maintain responsiveness
- keep assistant feeling calm and intentional

---

### Out of Scope

Do NOT implement yet:

- autonomous agents
- unrestricted computer control
- persistent workflow memory
- continuous visual reasoning
- continuous audio understanding
- generated tool execution
- long-horizon planning
- cross-app automation graphs
- hidden background surveillance

---

### Success Criteria

After Phase 14:

- rich context meaningfully affects behavior
- proposal timing improves
- interruptions decrease
- actions feel more situationally aware
- multimodal context begins influencing intelligence
- expensive context is sampled adaptively
- stale context problems are reduced further
- Analyze Screen becomes substantially smarter
- assistant behavior feels calmer and more grounded
- performance remains responsive
- the system still feels privacy-first and local-first

---

## Phase 15 — Dynamic Intent + Action Synthesis

### Goal

Transform the assistant from a static action system into a contextually intelligent intent synthesis system.

Phase 13 built contextual infrastructure.

Phase 14 activated rich context consumption.

Phase 15 begins allowing the assistant to:

- infer workflows
- synthesize contextual intents
- dynamically generate actions
- compose actions from primitives
- adapt behavior situationally
- surface semantically useful assistance

without becoming:

- autonomous
- chaotic
- intrusive
- spammy
- unpredictable
- computationally excessive

---

### Core Principle

The assistant should stop thinking in terms of:

- summarize
- explain
- rewrite

and begin thinking in terms of:

- “The user is debugging”
- “The user is researching”
- “The user is writing”
- “The user is reviewing code”
- “The user is filling repetitive UI”
- “The user is context-switching heavily”
- “The user is investigating an issue”
- “The user is extracting information”

The assistant should synthesize contextual usefulness,
not merely expose generic utilities.

---

### Updated System Flow

Sources  
↓  
Rich Context Infrastructure  
↓  
Canonical Fused Context  
↓  
Workflow Inference Engine  
↓  
Intent Synthesis Engine  
↓  
Dynamic Action Generator  
↓  
Proposal Intelligence  
↓  
Action Execution Layer  
↓  
UI / Interaction Layer  

---

### Design Philosophy

The assistant should evolve from:

> “Some text exists.”

toward:

> “The user appears to be debugging a SwiftUI layout issue after repeatedly switching between Xcode, terminal output, and documentation.”

The system should begin understanding:

- workflow state
- behavioral patterns
- semantic usefulness
- situational intent
- contextual continuity

instead of reacting narrowly to individual triggers.

---

### Dynamic Action Philosophy

Dynamic actions are:

- generated contextually
- situationally synthesized
- confidence-scored
- temporary
- composable
- workflow-aware

Dynamic actions are NOT:

- arbitrary generated code
- unrestricted automation
- unrestricted tool execution
- autonomous agents
- uncontrolled planning loops

The assistant should generate:

- intentions
- structured proposals
- composed action plans

not unrestricted execution.

---

### Workflow Inference Philosophy

The assistant should begin inferring:

- editing workflows
- debugging workflows
- research workflows
- writing workflows
- review workflows
- browsing workflows
- repetitive interaction patterns
- contextual sessions

using:

- app transitions
- interaction timing
- contextual continuity
- multimodal agreement
- repeated behavioral patterns
- rich fused context

---

### Intent Synthesis Philosophy

The assistant should synthesize useful intentions dynamically.

Examples:

- “Explain likely cause of this stacktrace”
- “Summarize changes in this diff”
- “Extract TODOs from this screen”
- “Generate commit summary”
- “Draft response to selected message”
- “Compare these snippets”
- “Summarize article section”
- “Identify likely bug source”
- “Extract action items”
- “Explain highlighted API response”

The assistant should begin generating actions because they are useful in-context,
not because they were statically predefined.

---

### Action Composition Philosophy

Generated actions should be composed from safe primitives.

Examples:

- explain
- summarize
- rewrite
- extract
- compare
- classify
- structure
- transform

The assistant should synthesize execution plans from these primitives.

This preserves:

- determinism
- safety
- responsiveness
- explainability

while enabling flexible behavior.

---

### Proposal Philosophy

Proposal quality becomes more important than proposal quantity.

The assistant should prefer:

- fewer
- higher-confidence
- more contextually meaningful
- more situationally useful

proposals.

The assistant should increasingly optimize for:

- usefulness
- timing
- workflow continuity
- interruption cost
- contextual relevance

instead of simply reacting to triggers.

---

### Behavioral Philosophy

The assistant should begin feeling:

- thoughtful
- situationally aware
- workflow-sensitive
- calm
- useful
- intentional

instead of:

- reactive
- generic
- repetitive
- heuristic-heavy
- clipboard-driven

---

### Performance Philosophy

Dynamic intent generation must remain:

- lightweight
- local-first
- cancellable
- bounded
- confidence-aware
- budget-aware

The assistant should NOT:

- constantly generate actions
- continuously reason deeply
- aggressively sample context
- block interaction responsiveness

Most reasoning should remain:

- opportunistic
- event-driven
- selective
- confidence-gated

---

### Safety Philosophy

Generated actions must remain:

- constrained
- explainable
- interrupt-safe
- deterministic where possible
- confidence-scored
- reversible

The assistant should never:

- execute arbitrary generated code
- silently automate workflows
- create uncontrolled execution loops
- persist hidden behavioral memory
- escalate privileges autonomously

---

### Privacy Philosophy

The assistant remains:

- local-first
- privacy-first
- minimally persistent
- metadata-oriented
- transparency-oriented

Rich behavioral understanding should improve usefulness,
not become surveillance.

---

## Tickets

---

### T15.1 — Workflow Inference Engine

Introduce workflow inference infrastructure.

The system should begin inferring:

- debugging workflows
- writing workflows
- research workflows
- browsing workflows
- editing workflows
- review workflows

using:

- app transitions
- interaction state
- context continuity
- multimodal agreement
- behavioral repetition

The output should remain:

- lightweight
- confidence-scored
- temporary
- metadata-only

---

### T15.2 — Contextual Session Tracking

Introduce lightweight contextual session continuity.

The assistant should begin tracking:

- recent workflow continuity
- repeated contexts
- recurring interaction patterns
- active task continuity

without persistent long-term behavioral memory.

Goals:

- reduce contextual reset feeling
- improve proposal continuity
- improve workflow awareness

---

### T15.3 — Intent Synthesis Engine

Create a dynamic intent synthesis layer.

The assistant should generate:

- contextual intents
- situational assistance ideas
- workflow-aware proposal concepts

instead of relying entirely on predefined actions.

Generated intents should remain:

- structured
- confidence-scored
- non-executable
- temporary

---

### T15.4 — Generated Action Model

Introduce generated action structures.

Generated actions should contain:

- title
- description
- intent type
- confidence
- required context
- execution primitives
- interruption cost
- workflow relevance

Generated actions should remain:

- explainable
- deterministic
- non-autonomous

---

### T15.5 — Action Primitive Composition

Allow actions to be composed from primitives.

Examples:

- summarize + extract
- explain + compare
- structure + summarize
- classify + extract

The system should synthesize simple execution plans dynamically.

---

### T15.6 — Workflow-Aware Proposal Ranking

Proposal ranking should begin considering:

- workflow continuity
- repeated usefulness
- interruption cost
- recent proposal rejection
- active workflow type
- generated action confidence

instead of mostly static heuristics.

---

### T15.7 — Dynamic Intent Suppression

Suppress low-quality or low-usefulness generated intents.

Examples:

- weak contextual evidence
- repetitive generated proposals
- active interaction bursts
- stale workflows
- low multimodal agreement

Goals:

- maintain calmness
- reduce hallucinated usefulness
- reduce proposal spam

---

### T15.8 — Generated Action Safety Constraints

Introduce safety constraints for generated actions.

Generated actions must NOT:

- execute arbitrary commands
- access unrestricted APIs
- create uncontrolled loops
- escalate privileges
- silently automate workflows

All generated actions must remain bounded and reviewable.

---

### T15.9 — Dynamic Action Explainability

Generated actions should expose:

- why they appeared
- what context influenced them
- confidence
- workflow reasoning

without exposing raw sensitive context.

The assistant should increasingly feel transparent.

---

### T15.10 — Generated Intent Debug Visualization

Improve debugging visibility for:

- workflow inference
- generated intents
- proposal ranking
- suppression decisions
- execution composition
- contextual continuity

Metadata-only.

No raw context logging.

---

### T15.11 — Dynamic Action UX Foundations

Begin preparing the UI for contextual/generated actions.

Possible future-facing behaviors:

- contextual inline actions
- grouped workflow suggestions
- richer proposal cards
- intent categories
- lightweight workflow surfacing

Do NOT redesign the UI yet.

Focus on foundational support only.

---

### T15.12 — Phase 15 Tuning Pass

Tune dynamic intent behavior.

Goals:

- reduce low-value generated actions
- improve contextual usefulness
- improve workflow continuity
- improve proposal quality
- improve calmness
- improve trustworthiness
- maintain responsiveness
- avoid over-generation

The assistant should feel:

- intelligent
- grounded
- situationally useful
- non-intrusive

---

### Out of Scope

Do NOT implement yet:

- unrestricted autonomous agents
- browser automation
- shell execution
- generated Swift execution
- unrestricted tool ecosystems
- long-horizon planning
- persistent behavioral profiling
- cloud-dependent reasoning
- hidden background automation
- fully autonomous workflows

---

### Success Criteria

After Phase 15:

- the assistant begins synthesizing contextual intents
- actions become workflow-aware
- proposals feel more situationally useful
- workflow continuity improves
- proposal quality improves substantially
- generic summarize/explain behavior becomes less dominant
- generated actions remain calm and bounded
- interruption quality improves
- dynamic actions feel intentional
- the assistant begins feeling semantically intelligent
- responsiveness remains high
- privacy-first/local-first philosophy remains intact

---

# Phase 16 — Visible Intelligence

## Goal

Transform the assistant from:

> internally context-aware

into:

> visibly contextually useful.

Phase 15 built the cognitive scaffolding:

- workflow inference
- session continuity
- synthesized intents
- generated actions
- primitive composition
- safety systems
- explainability
- suppression
- workflow-aware ranking

But most of this intelligence still remains:

- hidden
- conservative
- indirect
- difficult to perceive externally

Phase 16 focuses on:

- surfacing intelligence
- contextual usefulness
- visible workflow awareness
- richer proposals
- dynamic assistance
- trustworthy proactive behavior

without becoming:

- spammy
- agentic
- autonomous
- noisy
- interruptive

---

## Core Principle

The assistant should begin feeling like:

> “it understands what I’m doing.”

instead of:

> “it detected some text.”

The assistant should now visibly adapt to:

- workflows
- app context
- interaction state
- recent continuity
- generated intents
- contextual confidence
- situational usefulness

---

## Phase 16 Philosophy

Phase 15 created:

```text
workflow → intent → generated action → plan → safety
```

Phase 16 makes this visible.

The intelligence pipeline should begin affecting:

- proposal cards
- action ordering
- contextual affordances
- generated suggestions
- workflow surfacing
- Analyze Screen usefulness
- interaction quality

---

## Behavioral Philosophy

The assistant should increasingly feel:

- intelligent
- grounded
- situationally aware
- workflow-aware
- adaptive
- calm
- trustworthy

while remaining:

- reviewable
- bounded
- local-first
- non-agentic
- non-autonomous

---

## Assistant Personality Direction

The assistant should start behaving less like:

> “generic AI utilities”

and more like:

> “a workflow-sensitive cognitive assistant.”

Examples:

- Xcode + stacktrace + paused typing
  → “Explain likely error”

- Long article + idle reading
  → “Summarize key arguments”

- Notes + repeated edits
  → “Structure these notes”

- Research workflow across browser tabs
  → “Compare findings”

- Form-heavy UI + active interaction
  → stay quiet

---

## Generated Action Philosophy

Generated actions should now become:

- partially surfaced
- visually differentiated
- contextually justified
- explainable
- ranked by usefulness

The user should begin seeing:

- why actions appeared
- workflow-aware suggestions
- contextual grouping
- generated assistance concepts

without exposing:

- raw sensitive context
- hidden reasoning chains
- private screen data

---

## Analyze Screen Philosophy

Analyze Screen should evolve from:

> OCR summarization

into:

> contextual screen understanding.

Still bounded.

Still non-agentic.

Still metadata-driven.

But substantially more useful.

The assistant should increasingly combine:

- OCR
- AX structure
- workflow inference
- visual descriptors
- contextual continuity
- interaction state

into:

- coherent situational assistance

---

## UI Philosophy

The UI should begin supporting:

- richer proposal cards
- contextual labels
- grouped suggestions
- generated assistance
- workflow surfacing
- explainability hints

without becoming:

- dashboard-heavy
- visually cluttered
- debug-oriented
- overwhelming

---

## Performance Philosophy

Even with visible intelligence:

- expensive sampling must remain adaptive
- OCR should remain sparse
- no continuous visual loops
- no persistent surveillance
- no cloud dependency
- no background autonomous execution

The system should remain:

- lightweight
- responsive
- interrupt-safe
- budget-aware

---

## Trust Philosophy

Generated assistance must remain:

- explainable
- suppressible
- confidence-scored
- bounded
- deterministic
- reviewable

The assistant should never feel:

- manipulative
- hidden
- uncontrollable
- overconfident
- autonomous

---

## Dynamic Assistance Direction

This phase begins introducing:

- visible generated actions
- contextual inline assistance
- workflow-aware suggestions
- richer proposal composition
- situational assistance surfacing

but NOT:

- autonomous agents
- unrestricted automation
- self-directed workflows
- hidden background execution

---

## Updated System Flow

Sources
↓
Rich Context Pipeline
↓
Workflow Inference
↓
Session Continuity
↓
Intent Synthesis
↓
Generated Actions
↓
Safety + Explainability
↓
Workflow-Aware Ranking
↓
Visible Assistance Layer
↓
UI / Interaction

---

## Performance Rules

- No unrestricted automation
- No autonomous execution
- No hidden workflows
- No continuous OCR loops
- No persistent visual surveillance
- No silent app control
- No unreviewed generated actions
- No excessive proposal spam

---

## Privacy Rules

The assistant remains:

- local-first
- privacy-first
- minimally persistent
- metadata-oriented
- bounded

Generated intelligence should improve usefulness,
not reduce user control.

---

## Tentative Ticket Direction

### T16.1 — Visible Generated Actions

Begin surfacing generated actions alongside static actions.

Generated actions should:

- appear visually distinct
- remain preview-oriented
- remain explainable
- remain bounded

---

### T16.2 — Contextual Proposal Cards

Upgrade proposal cards to display:

- workflow hints
- explainability summaries
- contextual reasoning
- confidence tiers
- generated intent origins

without becoming verbose.

---

### T16.3 — Workflow-Sensitive Action Ordering

Allow workflows and session continuity to more aggressively shape:

- action ordering
- proposal prominence
- generated action placement
- contextual grouping

---

### T16.4 — Analyze Screen Situational Understanding

Improve Analyze Screen usefulness by synthesizing:

- OCR
- AX metadata
- workflow inference
- visual descriptors
- contextual continuity

into more coherent assistance.

Reduce “uncertain generic narration.”

---

### T16.5 — Generated Assistance Categories

Introduce lightweight categories:

- Debugging
- Research
- Writing
- Review
- Organization
- Comparison

for generated assistance surfacing.

---

### T16.6 — Inline Contextual Assistance Foundations

Begin foundations for:

- inline contextual suggestions
- lightweight action chips
- contextual overlays

without implementing full inline UI yet.

---

### T16.7 — Dynamic Assistance Suppression Tuning

Improve suppression quality for visible generated assistance.

The assistant should surface:
- fewer
- higher quality
- more contextual
- more trustworthy

suggestions.

---

### T16.8 — Workflow Continuity Surfacing

Lightly surface active workflow continuity.

Examples:

- “Debugging workflow detected”
- “Research session active”
- “Writing workflow continuing”

Must remain subtle and non-intrusive.

---

### T16.9 — Generated Action Interaction Tracking

Track lightweight interaction outcomes:

- ignored
- dismissed
- expanded
- accepted
- repeated usefulness

without persistent behavioral profiling.

---

### T16.10 — Rich Assistance Ranking

Create a unified ranking layer combining:

- static actions
- generated actions
- workflow continuity
- interruption cost
- contextual confidence
- usefulness history

---

### T16.11 — Visible Intelligence Debugging

Improve internal debugging visibility for:

- generated action surfacing
- ranking decisions
- workflow influence
- suppression outcomes
- interaction usefulness

Metadata-only.

---

### T16.12 — Phase 16 Tuning Pass

Tune visible intelligence behavior.

Goals:

- improve generated usefulness
- improve trustworthiness
- reduce noisy surfacing
- improve contextual accuracy
- improve proposal quality
- improve workflow relevance
- maintain calmness
- maintain responsiveness

---

## Out of Scope

Do NOT implement yet:

- autonomous agents
- unrestricted computer control
- self-modifying workflows
- hidden execution chains
- long-horizon autonomous planning
- unrestricted app automation
- persistent behavioral profiling
- cloud reasoning dependency
- background invisible task execution

---

## Success Criteria

After Phase 16:

- generated actions become visibly useful
- proposal cards feel contextual
- workflows visibly affect assistance
- Analyze Screen becomes meaningfully smarter
- generated assistance feels intentional
- assistant usefulness becomes externally noticeable
- proposal quality improves substantially
- the assistant feels more alive without becoming intrusive
- trustworthiness remains high
- responsiveness remains strong
- the system still feels privacy-first and local-first

---

### Resulting UX

After Phase 9:

[Suggestion]  
"Want help understanding this?"  

[Actions]  
Explain | Summarize | Rewrite | Analyze Screen  

[Input]  
Using: Screen (OCR, 2327 chars)  

[Result]  
<clean readable output>  

[Controls]  
Invoke | Status  

[Debug ▼] (optional)

---

## Notes

This roadmap is a living document.

Details for each phase will be expanded as development progresses.
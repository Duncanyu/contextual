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
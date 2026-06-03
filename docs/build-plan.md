# Build Plan — Context-Aware macOS Assistant

## Core Principle

Build in small, controlled phases.

Each phase should:
- produce a working result
- be testable
- not depend on unfinished systems

Do NOT build everything at once.

---

## Development Rules

- Only work on ONE phase at a time
- Only work on ONE ticket at a time
- Do not skip ahead
- Do not add features outside the current phase
- Commit after every completed ticket

---

## Phase 0 — Project Setup

Goal:
Establish a clean, scalable foundation.

Tickets:

T0.1 — Create project repository  
- initialize git  
- create folder structure  

T0.2 — Add documentation  
- add spec-summary.md  
- add architecture.md  
- add build-plan.md  

T0.3 — Create AGENTS.md  
- define coding rules  
- define architecture constraints  

T0.4 — Create base macOS app (Xcode)  
- SwiftUI macOS app  
- opens successfully  

---

## Phase 1 — App Shell

Goal:
Create a usable assistant shell with no intelligence.

Tickets:

T1.1 — Menu bar app  
- create menu bar icon  
- app runs in background  

T1.2 — Assistant panel  
- window opens on click  
- basic layout  

T1.3 — Settings panel  
- simple settings view  

T1.4 — Pause / Resume toggle  
- global state  
- reflected in UI  

T1.5 — Keyboard shortcut  
- open assistant panel  

Success Criteria:
- app launches  
- panel opens  
- UI works  
- no AI involved  

---

## Phase 2 — System Sources

Goal:
Collect basic macOS signals.

Tickets:

T2.1 — ActiveAppSource  
- detect current app  
- update on change  

T2.2 — WindowTitleSource  
- get active window title  

T2.3 — ClipboardSource  
- detect clipboard changes  
- capture text only  

T2.4 — SelectionSource (optional early)  
- detect selected text  

T2.5 — SourceManager  
- normalize events  
- central event dispatch  

Success Criteria:
- events are detected  
- no crashes  
- no UI logic  

---

## Phase 3 — Context Model

Goal:
Create structured system state.

Tickets:

T3.1 — ContextModel struct  
- define fields  

T3.2 — ContextBuilder  
- update context from events  

T3.3 — Session state tracking  
- recent apps  
- recent events  

T3.4 — Debug panel  
- display context in UI  

Success Criteria:
- context updates correctly  
- visible in debug panel  

---

## Phase 4 — Trigger System

Goal:
Detect meaningful moments.

Tickets:

T4.1 — TriggerEngine  
- basic trigger logic  

T4.2 — Clipboard trigger  
- fire on useful text  

T4.3 — Selected text trigger  
- fire on selection  

T4.4 — Manual trigger  
- shortcut-based  

T4.5 — CooldownManager  
- prevent spam  

Success Criteria:
- triggers fire correctly  
- not too frequent  

---

## Phase 5 — Core Actions

Goal:
Provide real value.

Tickets:

T5.1 — Action protocol  
- define interface  

T5.2 — SummarizeAction  
- input: text  
- output: summary  

T5.3 — ExplainAction  
- input: text  
- output: explanation  

T5.4 — RewriteAction  
- input: text  
- output: improved text  

T5.5 — ActionRouter  
- route actions  

Success Criteria:
- actions work end-to-end  
- results display in UI  

---

## Phase 6 — Intelligence Layer

Goal:
Make assistant reactive and smart.

Tickets:

T6.1 — ModelManager  
- local model interface  

T6.2 — ReasoningEngine  
- interpret context  

T6.3 — ProposalGenerator  
- generate suggestions  

T6.4 — Action ranking  
- choose best action  

Success Criteria:
- suggestions are contextual  
- system feels reactive  

---

## Phase 7 — Suggestion System

Goal:
Surface actions cleanly.

Tickets:

T7.1 — SuggestionCard UI  
- small popup  

T7.2 — Accept / Dismiss  
- user control  

T7.3 — Cooldown integration  
- prevent repetition  

T7.4 — Suggestion logic connection  
- trigger → UI  

Success Criteria:
- suggestions appear  
- dismiss works  
- no spam  

---

## Phase 8 — Screen Awareness

Goal:
Enable visual understanding.

Tickets:

T8.1 — ScreenCapture module  
- manual capture  

T8.2 — OCR integration  
- extract text  

T8.3 — ScreenAnalyzeAction  
- explain screen  

Success Criteria:
- user can analyze screen  
- works reliably  

---

## Phase 9 — Expansion (Optional)

- browser integration  
- VS Code integration  
- file system actions  
- advanced reasoning  
- multi-step workflows  

---

## Development Workflow

For each ticket:

1. Define scope  
2. Prompt AI (Cursor/Claude)  
3. Generate code  
4. Review manually  
5. Run locally  
6. Fix issues  
7. Commit  

---

## AI Usage Rules

When using AI:

- give ONLY the current ticket  
- include constraints  
- do NOT include full spec  
- enforce architecture rules  

Example prompt:

"Implement ActiveAppSource in Swift.  
Use NSWorkspace.  
Emit events to SourceManager.  
Do not connect to UI."

---

## Testing Strategy

After each phase:

- verify functionality  
- check performance  
- ensure no crashes  
- validate architecture boundaries  

---

## Stop Conditions

Stop and refactor if:

- files become too large  
- logic leaks between layers  
- performance drops  
- suggestions feel wrong  
- system becomes hard to extend  

---

## Core Build Principle

Do not build fast.

Build in a way that allows you to KEEP building.

Every phase should make the next phase easier, not harder.

---

## Phase 12 — Micro classifier asset (T12.3.7)

Bundled `MicroDecisionClassifier.mlmodel` is produced by `Scripts/build_micro_classifier.py` (Python venv with `scikit-learn==1.5.1` + `coremltools`). Feature layout is duplicated in `Intelligence/MicroDecisionFeatureEncoder.swift`. Xcode compiles the `.mlmodel` to `.mlmodelc` in the app bundle.

T12.10 — Phase 12 tuning pass: thresholds and gates in `IntelligenceProposalSelector`, `IntelligenceBudgetManager`, `IntelligenceDecisionCache`, micro skip length, redundancy/floating cooldowns; no architecture change. Follow-up: classifier + `ContextClassifier` + relevance keys for notes/prose; content-stamped proposal cooldown; quiet Ollama tag probes. **Final blockers:** OCR async must not override `lastSourceTrigger` when selection dominates; notes/article rewrite guard + phi3 guard; TES `proposalGateAllows` + effective input; floating lifecycle 12m prune + channel reset; serve-spawn tags settle delay.

## Phase 23 — Generated Actions Architecture

Replace capability-driven ambient proposals with context-generated actions. `OpportunityEngine` now emits `GeneratedActionProposal` values, validates specificity and confidence, composes them into existing `ExecutionPrimitive` plans, and passes generated titles through to Jarvis. Capability selector paths are deprecated for production proposal generation; primitive composition remains bounded and read-only.

## Phase 24 — Problem-Driven Generated Actions

Move proposal generation from deterministic workflow/action mappings to a problem-first generated path: infer `ProblemSignal` from local context, ask the planner model for concrete candidate actions, validate out generic/capability-shaped labels, compose accepted actions into existing primitives, and surface the generated title through Jarvis. Deterministic generated actions remain only as an explicit fallback when no validated planner candidate is available.

## Phase 24.1 — Deterministic Fallback Leakage Fix

Suppress instead of falling back when the planner returns no usable candidates. Add generated proposal quality filtering for duplicated/generic titles, low-confidence website/document/code/product context gates before planner execution, workflow actionability diagnostics, and planner success counters so dogfood sessions can verify accepted, rejected, and suppressed planner outputs.

## Phase 25 — Environment Actions

Add an environment action route after generated actions so Jarvis can choose cognitive output, local/preview environment actions, hybrid actions, or silence. Environment actions cover focus media, Reduce Interruptions previews, workspace app-set memory, and passive-watching suppression with explicit logs and honest unavailable status for unwired system controls.

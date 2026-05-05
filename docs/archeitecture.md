# System Architecture — Context-Aware macOS Assistant

## Core Principle

The system is modular, layered, and event-driven.

Each layer has one responsibility.
No layer should directly depend on another’s internal logic.

All data flows through a structured pipeline.

---

## High-Level Architecture

macOS Sources  
↓  
Source Manager  
↓  
Context Builder  
↓  
Context Model  
↓  
Trigger System  
↓  
Intelligence Layer  
↓  
Action Router  
↓  
Action Modules  
↓  
UI Layer  

---

## Core Layers

### 1. System Sources

Purpose:
Collect raw signals from macOS and apps.

Examples:
- Active app
- Window title
- Clipboard
- Selected text
- Keyboard shortcut
- Screen capture (optional)

Rules:
- No reasoning
- No UI
- No AI calls
- Only emit events

---

### 2. Source Manager

Purpose:
Central hub for all sources.

Responsibilities:
- Start/stop sources
- Normalize events
- Prevent duplicates
- Forward clean events

Output:
Standardized `SourceEvent`

---

### 3. Context Builder

Purpose:
Convert raw events into structured state.

Responsibilities:
- Maintain session state
- Track recent activity
- Merge signals into context
- Remove unnecessary data

Output:
`ContextModel`

Rules:
- No AI calls
- No suggestions
- No UI logic

---

### 4. Context Model

Purpose:
Single source of truth for current user state.

Contains:
- active app
- window title
- activity state
- user intent signals
- app-specific context
- system state
- candidate actions
- confidence signals
- privacy level

Rules:
- Compact
- Extendable
- Privacy-aware

---

### 5. Trigger System

Purpose:
Decide whether deeper reasoning is needed.

Responsibilities:
- Detect meaningful events
- Apply confidence thresholds
- Enforce cooldowns
- Respect permissions

Output:
`TriggerPacket` OR nothing

Rules:
- Most events should be ignored
- Prefer silence over noise

---

### 6. Intelligence Layer

Purpose:
Interpret context and propose actions.

Sub-layers:

#### Always-On Layer
- lightweight rules
- pattern detection
- event filtering

#### Reasoning Layer
- interprets context
- generates suggestions
- ranks actions

#### Execution Layer
- runs after user accepts action
- generates results

Rules:
- AI is NOT always running
- Only triggered when needed
- Prefer smaller models first

---

### 7. Action Router

Purpose:
Dispatch accepted actions.

Responsibilities:
- Receive selected action
- Validate permissions
- Gather inputs
- Call correct module

Rules:
- No business logic
- Only routing

---

### 8. Action Modules

Purpose:
Execute specific capabilities.

Examples:
- SummarizeAction
- ExplainAction
- RewriteAction
- CompareTabsAction
- DebugErrorAction
- ScreenAnalyzeAction

Each module includes:
- input requirements
- processing logic
- optional AI call
- output formatter

Rules:
- Fully isolated
- Replaceable
- No cross-module dependencies

---

### 9. UI Layer

Purpose:
Display assistant and interactions.

Components:
- Menu bar icon
- Suggestion card
- Assistant panel
- Result view
- Settings panel

Responsibilities:
- Show suggestions
- Display results
- Handle user input

Rules:
- No business logic
- No AI calls
- Only reflects system state

---

### 10. Storage Layer

Purpose:
Store lightweight local data.

Stores:
- settings
- permissions
- cooldowns
- recent suggestions
- preferences

Avoid storing:
- raw clipboard history
- screenshots
- sensitive data

---

### 11. Permissions Layer

Purpose:
Control access to data sources.

Responsibilities:
- track permissions
- enforce access rules
- expose toggles

Rules:
- every module must check permissions
- no silent escalation

---

## Data Flow

1. Source emits event  
2. Source Manager normalizes  
3. Context Builder updates state  
4. Trigger System evaluates  
5. Intelligence Layer reasons  
6. UI shows suggestion  
7. User accepts or dismisses  
8. Action Router dispatches  
9. Action Module executes  
10. UI shows result  

---

## Architectural Rules (CRITICAL)

1. Sources collect only  
2. Context Builder structures only  
3. Trigger System filters only  
4. Intelligence Layer reasons  
5. Action Router routes only  
6. Action Modules execute  
7. UI displays only  

---

## AI Usage Rules

- Never call AI from UI
- Never call AI from Sources
- All AI calls go through Intelligence Layer
- AI is only triggered after meaningful events
- AI is never always-on

---

## Permission Rules

- Every source declares required permission
- Every action declares required permission
- If permission is missing → feature is skipped
- System must degrade gracefully

---

## Modularity Rules

To add a new source:
- create module
- emit SourceEvent
- register in Source Manager

To add a new action:
- create module
- define inputs
- register in Action Router

To add new UI:
- read from existing system state
- do not duplicate logic

---

## Folder Structure

/App  
/SystemSources  
/SourceManager  
/Context  
/Triggers  
/Intelligence  
/Actions  
/UI  
/Storage  
/Permissions  

---

## Core Design Philosophy

The system should behave like an operating layer, not an app.

- Reactive, not command-based  
- Context-driven, not input-driven  
- Lightweight by default  
- Scalable through modularity  

---

## Failure Conditions

Architecture fails if:

- layers mix responsibilities  
- AI calls are scattered  
- UI contains logic  
- sources contain decisions  
- modules depend on each other  
- performance degrades  

---

## Core Principle

The assistant must scale by adding modules, not by increasing complexity.

Each part should remain small, focused, and replaceable.

This is what prevents the system from collapsing as it grows.
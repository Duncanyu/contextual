# AGENTS.md — Coding Rules for Context-Aware macOS Assistant

## Project Summary

This project is a macOS-native, privacy-first, context-aware assistant.

It runs in the background, observes permitted local context and surfaces useful actions without requiring commands.

The app must feel native, lightweight, modular and scalable.

## Core Architecture

Follow this pipeline:

SystemSources → SourceManager → ContextBuilder → TriggerEngine → IntelligenceLayer → ActionRouter → UI

## Non-Negotiable Rules

- Do not build outside the current ticket.
- Do not implement extra features unless explicitly requested.
- Do not mix architecture layers.
- Do not put business logic in UI files.
- Do not call AI models directly from UI.
- Do not access macOS APIs outside SystemSources.
- Do not store raw clipboard history, screenshots or sensitive content.
- Do not add cloud/network functionality unless explicitly requested.
- Do not make irreversible system changes without user confirmation.
- Keep files small and focused.

## Layer Rules

### SystemSources
Collect macOS/app events only.

Allowed:
- active app detection
- window title detection
- clipboard monitoring
- selected text access
- keyboard shortcuts
- screen capture later

Not allowed:
- UI logic
- AI calls
- action decisions

### SourceManager
Normalize and dispatch source events.

Not allowed:
- UI logic
- action execution
- AI calls

### Context
Build and maintain structured context.

Not allowed:
- showing UI
- calling AI
- executing actions

### Triggers
Decide whether context is worth deeper reasoning.

Not allowed:
- final suggestion wording
- action execution
- UI rendering

### Intelligence
Interpret context and generate proposals.

All AI/model calls must go through this layer.

### Actions
Execute accepted actions only.

Each action must be isolated and registered through ActionRouter.

### UI
Display app state, suggestions, panels and results.

UI must not contain core system logic.

### Permissions
Every source and action must check required permissions before running.

## Development Rules

- Work one ticket at a time.
- Keep changes scoped.
- Update docs/build-plan.md if scope changes.
- Prefer simple working code over overengineering.
- Add debug visibility where useful.
- After each task, summarize:
  - files changed
  - what was implemented
  - what remains

## Current Build Order

1. Phase 0: Project setup
2. Phase 1: App shell
3. Phase 2: System sources
4. Phase 3: Context model
5. Phase 4: Trigger system
6. Phase 5: Core actions
7. Phase 6: Intelligence layer
8. Phase 7: Suggestion system
9. Phase 8: Screen awareness

## Current Constraint

Unless explicitly told otherwise, assume we are building the smallest working slice for the current ticket only.
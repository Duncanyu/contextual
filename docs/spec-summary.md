# Context-Aware macOS Assistant — Spec Summary

## Core Definition

A privacy-first, context-aware desktop assistant that continuously interprets the user’s workflow and surfaces relevant actions in real time without requiring commands.

The system runs locally and uses lightweight context signals to understand what the user is doing. It provides immediate, actionable assistance without interrupting the workflow.

---

## Core Value Proposition

The computer understands what the user is doing and provides useful actions instantly without requiring prompts or context switching.

---

## What Makes It Different

Unlike traditional assistants (Siri, Google Assistant), this system is:

- Context-based instead of command-based  
- Proactive instead of reactive  
- Workflow-integrated instead of task-oriented  
- Continuously adaptive instead of interaction-driven  

---

## Core Behavior

The assistant:

- Runs continuously in the background  
- Observes lightweight signals (apps, windows, clipboard, selection)  
- Maintains awareness of user context  
- Surfaces actions only when useful  
- Stays silent when uncertain  

---

## Interaction Model

Instead of:

User → Command → Response  

The system operates as:

Context → Suggestion → User Accepts or Ignores  

Suggestions are:

- Question-based, not commands  
- Contextual and specific  
- Easily dismissible  
- Non-intrusive  

---

## Primary Use Cases

- Research and information gathering  
- Comparing options (products, ideas, tools)  
- Writing and editing  
- Debugging and coding  
- Managing information overload (tabs, notes)  
- Decision making  
- Frequent context switching  

---

## Core Capabilities

The assistant surfaces actions such as:

- Summarize content  
- Explain content or errors  
- Rewrite or refine text  
- Compare items or pages  
- Extract key points  
- Suggest next steps  
- Detect useful patterns (e.g. repeated tabs, switching)  

---

## What It Is NOT

- Not a chatbot  
- Not a voice assistant  
- Not autonomous  
- Not constantly interrupting  
- Not reading everything by default  
- Not replacing the user’s workflow  

---

## Privacy Model

- Local-first by default  
- No data leaves the device unless explicitly allowed  
- Uses metadata by default  
- Uses deeper context only with permission  
- Screen capture is optional and user-controlled  

---

## UX Model

The system has three layers:

### 1. Background Presence
Runs silently, no UI

### 2. Suggestion Layer
Small, lightweight suggestion cards

- One at a time  
- Dismissible  
- Contextual  

### 3. Assistant Panel
Opened via:
- menu bar
- keyboard shortcut
- accepting a suggestion

Displays:
- current context
- relevant actions
- results

---

## Behavior Rules

- Never interrupt aggressively  
- Never spam suggestions  
- Only act on high-confidence context  
- Always be dismissible  
- Prefer silence over low-value suggestions  

---

## Mental Model

The assistant is:

> A system layer that turns what you are already doing into immediate useful actions.

---

## Failure Conditions

The system fails if:

- Suggestions are irrelevant  
- It triggers too often  
- It feels intrusive  
- It slows down the system  
- It behaves unpredictably  
- It becomes cluttered  

---

## Core Principle

The assistant should feel intelligent and reactive without constantly using heavy AI.

Lightweight awareness runs continuously.  
Deep reasoning runs only when needed.  
Heavy processing runs only on demand.
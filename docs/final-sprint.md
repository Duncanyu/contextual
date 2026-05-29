# Contextual — Final Product Roadmap

## Mission

Contextual is a local-first, privacy-first ambient intelligence assistant.

It continuously understands what the user is doing, what workflow they are in, and what assistance would be helpful.

The goal is not to replace the user.

The goal is to reduce friction, surface intelligence, and provide assistance at the right moment.

---

# Core Product Philosophy

Contextual should feel like:

- Jarvis
- an intelligent observer
- workflow-aware
- context-aware
- proactive but not annoying
- local-first
- trustworthy

Contextual should NOT feel like:

- a chatbot
- a generic AI wrapper
- a browser automation toy
- an autonomous computer operator

Computer control exists to support the assistant.

Computer control is NOT the product.

---

# Architecture

Sources
→ Context
→ Triggers
→ Intelligence
→ Suggestions
→ Actions

Everything should flow through this pipeline.

---

# Phase A — Finish Agentic v1

Status: IN PROGRESS

Purpose:

Finish the existing agentic work so it stops becoming a permanent distraction.

Success criteria:

- scroll works
- keyboard shortcuts work
- typing works
- clicking works occasionally
- simple workflows can execute
- failures are safe
- no infinite loops
- demoable

Non-goals:

- OpenAI Operator
- browser agent parity
- fully autonomous desktop control
- reliable arbitrary visual grounding

Definition of done:

Agentic mode is usable for demonstrations and bounded tasks.

Once complete:

FREEZE.

No more major architecture changes.

No more planner rewrites.

No more grounding rewrites.

No more "one more fix".

---

# Phase B — Workflow Intelligence

Status: NEXT

Purpose:

Detect what the user is doing.

Examples:

Coding
Researching
Studying
Writing
Reading
Gaming
Watching lectures
Emailing
Shopping
Comparing products

Outputs:

workflow=coding
workflow=studying
workflow=researching

Confidence scored.

This becomes the foundation for suggestions.

Success criteria:

Contextual can identify major workflows accurately.

---

# Phase C — Generated Actions

Status: PLANNED

Purpose:

Make Contextual useful.

Examples:

Reading article
→ Summarize article

Watching lecture
→ Generate notes

Studying
→ Generate quiz

Viewing PDF
→ Extract formulas

Reading Reddit
→ Summarize thread

Debugging
→ Explain error

Comparing products
→ Create comparison table

Success criteria:

Contextual consistently proposes genuinely useful actions.

---

# Phase D — Ambient Suggestions

Status: PLANNED

Purpose:

Become proactive.

Examples:

Minecraft detected
No audio playing
Long session

→ Want music?

Long study session

→ Want a quiz?

Research workflow

→ Summarize findings so far?

Repeated compile failures

→ Explain likely error?

Many tabs open

→ Summarize active tabs?

Success criteria:

Suggestions feel helpful rather than random.

---

# Phase E — Context Memory

Status: PLANNED

Purpose:

Remember short-term workflow state.

Examples:

Current task
Current project
Current workflow
Current objective

Examples:

User researching laptops

User studying calculus

User debugging Contextual

User writing report

Success criteria:

Suggestions become personalized to ongoing work.

---

# Phase F — Ambient Automations

Status: PLANNED

Purpose:

Small deterministic automations.

Examples:

Turn on Focus Mode

Enable DND

Launch Spotify

Open notes

Create reminder

Open study materials

Open frequently used tools

Success criteria:

Automation saves effort without requiring full agentic control.

---

# Phase G — Jarvis Layer

Status: LONG TERM

Purpose:

Combine:

- workflow understanding
- context memory
- generated actions
- ambient suggestions
- deterministic automations

Into one unified assistant.

Examples:

"You're studying calculus and haven't taken a break in 90 minutes."

"You're playing Minecraft with no audio. Want music?"

"You've been debugging the same error for 30 minutes."

"You appear to be comparing USB-C chargers."

"You watched this lecture yesterday. Want a quiz?"

Success criteria:

Contextual feels alive.

Not because it controls the computer.

Because it understands what is happening.

---

# Research Principles

Based on:

- Context-aware computing
- Ambient intelligence
- Ubiquitous computing
- Workflow-aware assistants
- Human-in-the-loop AI

Research consistently shows that context acquisition, interpretation, and action are the core stages of context-aware systems. Ambient agents derive value from understanding and reacting to context rather than from raw UI control.  [oai_citation:0‡Emerald Publishing](https://www.emerald.com/imds/article/123/11/2771/183902/Beyond-AI-powered-context-aware-services-the-role?utm_source=chatgpt.com)

---

# Immediate Goal

Finish Agentic v1.

Then freeze it.

Then return to the actual product:

Contextual = Ambient Intelligence Assistant.

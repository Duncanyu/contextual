


## PRODUCT DEFINITION — CONTEXT-AWARE DESKTOP ASSISTANT
## Core Definition
A privacy-first, context-aware desktop layer that continuously interprets your workflow and
surfaces relevant actions in real time without requiring commands.
## Expanded Definition
This product runs locally on your computer and observes lightweight context signals by
default, with optional deeper context if permitted by the user. It continuously interprets what
you are doing and maintains a live set of relevant actions instead of one-off suggestions. It
allows you to act instantly without switching tools or writing prompts, while staying present
but non-intrusive.
## Key Clarification
The system is continuously available but only surfaces a small set of relevant actions at any
given time. It is active without being overwhelming.
## What Makes It Different
Compared to Apple Siri and Google Assistant, which are command-based, reactive, and
task-oriented, this system is context-based, proactive, workflow-integrated, and continuously
adaptive rather than interaction-based.
## Core Value Proposition
Your computer understands what you are doing and gives you the right tools instantly
without you having to ask or switch context.
## Primary Use Cases
Researching and gathering information
Comparing options such as products, tools, or ideas
Writing, editing, and structuring content
Debugging and coding workflows
Managing information overload such as tabs and notes
Making decisions
Handling frequent context switching
General everyday computer usage
## What It Actually Does
Continuously surfaces relevant actions such as summarizing content, explaining concepts or
errors, comparing items or pages, organizing tabs or notes, suggesting next steps, rewriting
or refining content, extracting key information, and detecting useful patterns like repeated
searches or multiple related tabs.
## What It Is Not
Not a chatbot interface
Not a voice assistant
Not a fully autonomous system making decisions for the user
Not constantly interrupting with notifications
Not blindly reading all screen content by default
Not replacing the user’s workflow


## Privacy Positioning
Private by default. All processing happens locally. No content is accessed or shared unless
explicitly permitted by the user.
## Privacy Model
Default mode uses metadata only, such as apps, tabs, time, and behavioral patterns.
Optional mode allows user-triggered context like selected or copied text.
Advanced mode allows deeper context for specific apps or sites only with explicit opt-in.
## Behavior Philosophy
The assistant is continuously present but not intrusive.
It surfaces useful actions instead of generating noise.
It never interrupts aggressively.
It avoids over-assuming intent.
It is always dismissible.
It minimizes interaction friction.
It feels like a tool rather than a personality.
## Interaction Model
Instead of the user issuing commands, the system understands context, surfaces relevant
actions, and allows the user to act instantly or ignore them.
## Mental Model
A context-aware action layer that turns what you are already doing into immediate, useful
actions.
## Failure Conditions
The system fails if it shows too many irrelevant actions, becomes visually cluttered, feels
intrusive or distracting, requires too much setup, slows down the system, or behaves
unpredictably.

## CORE USER EXPERIENCE — MACOS CONTEXT-AWARE ASSISTANT
High-Level UX Model
The system operates as a background presence that continuously observes context and
supports the user without requiring commands. It is not a foreground application but a
system layer that appears only when useful and remains accessible on demand.
The experience is composed of three layers:
## 1. Background Presence
The assistant runs silently in the background and continuously observes context
through permitted system signals. It does not display UI or interrupt the user during
normal operation.
## 2. Proactive Suggestions
When the system detects a high-confidence opportunity to help, it surfaces a small,
non-intrusive suggestion. These suggestions appear as lightweight floating cards or
macOS-style notifications. They are minimal, dismissible, and do not stack.


- On-Demand Assistant
The user can explicitly invoke the assistant at any time through a menu bar icon or
keyboard shortcut. This opens a full assistant panel with deeper capabilities and
context-aware actions.
## Core Interaction Flow
## Passive Mode
The user works normally. The system observes context and does not display any UI unless a
useful opportunity is detected.
## Suggestion Trigger
When the system detects a relevant action, a single suggestion card appears. The user can
accept the suggestion to expand the assistant, or ignore it with no consequence.
## Active Mode
When the user engages (via suggestion, menu bar, or shortcut), the assistant panel opens. It
displays the current context and a set of relevant actions. The user can select an action or
dismiss the panel.
UX Components
## Menu Bar Application
A persistent icon in the macOS menu bar acts as the control center. It provides access to the
assistant, system status, settings, permissions, and future features such as history. It is
always accessible but does not interrupt.
## Suggestion Cards
These are small, contextual UI elements that appear only when needed. They contain a
single high-confidence action and a dismiss option. Only one suggestion is shown at a time.
Suggestions automatically disappear after a short duration if not interacted with.
## Assistant Panel
This is the primary interaction interface. It appears when the user engages with the system.
It shows the system’s understanding of the current context and presents a limited set of
relevant actions. It allows deeper interaction, such as viewing results or selecting additional
actions.
## Quick Trigger
A global keyboard shortcut allows instant access to the assistant. When triggered, the
assistant opens with preloaded context, enabling fast interaction without navigating UI.
## Behavior Rules
The system follows strict behavioral constraints:
● It limits suggestion frequency to prevent spam.
● It only surfaces suggestions when confidence is sufficiently high.
● It avoids generic or vague prompts.
● It remains silent when uncertain.


● It ensures every interaction is dismissible.
The goal is to remain helpful without becoming intrusive.
## Privacy Experience
The system must provide transparent control over permissions and data access. Users can:
● View and manage permissions (accessibility, clipboard, screen capture).
● Enable or disable advanced features such as deeper context awareness.
● Pause the assistant instantly.
● Understand when the system is actively using additional context.
The system should include clear indicators when advanced capabilities such as screen
capture are active.
Screen Capture Integration (Planned Capability)
Screen capture is not part of the default experience but is supported as an optional
capability.
Initial behavior:
● Screen analysis is triggered explicitly by user action.
● The system captures context only when requested.
Advanced mode (optional):
● Users may enable continuous visual awareness.
● The system can then provide deeper, more context-rich suggestions.
In all cases, screen data is processed locally and not stored or transmitted.
## Design Principles
The assistant should feel:
● Present but not intrusive
● Fast and responsive
● Context-aware rather than reactive
● Minimal in visual footprint
● Consistent with macOS design expectations
It should behave like a system utility rather than a standalone application.
## Mental Model
The assistant is an ambient system layer that enhances the user’s workflow by surfacing the
right actions at the right time, without requiring explicit commands.
## Failure Conditions


The system fails if:
● Suggestions are irrelevant or low quality
● It interrupts too frequently
● It becomes visually cluttered
● It introduces noticeable latency
● It requires excessive user configuration
● It behaves unpredictably or inconsistently
## PIPELINE — INPUT, PROCESSING, OUTPUT
The system pipeline follows a simple structure:
## Input → Processing → Output
The goal is to make the assistant feel reactive and intelligent without constantly running a
heavy AI model in the background. The system should behave like a lightweight always-on
awareness layer that calls deeper AI only when there is a meaningful reason to do so.
## INPUT
Input refers to how the assistant gathers context from the Mac.
The system should collect context through permission-based macOS signals. It should not
rely on constantly reading everything or running screen capture at all times.
Core inputs include:
● Active app name
● Active window title
● App switching events
● Time spent in apps or windows
● Idle/active status
● Clipboard changes
● Selected text, where available
● Keyboard shortcut activation
● Menu bar interaction
● Browser tab titles and domains, if available
● Recent related tabs or windows
● Optional screen capture
● Optional OCR or visual context from screenshots
Input should be split into tiers:
## Default Input
The default input layer uses lightweight metadata such as app name, window title, app
switching behavior, time spent, and idle status. This layer is always on and should be
extremely lightweight.


User-Intent Input
This includes clipboard changes, selected text, manual shortcut activation, and menu bar
interaction. These signals are stronger because they suggest the user may want help with
something specific.
App-Specific Input
This includes browser tab titles, domains, URLs, related open tabs, VS Code context, Finder
context, or other app-specific information. These should be added gradually through
integrations or macOS accessibility features.
## Screen Capture Input
Screen capture is an important planned capability, but it should not be the default source of
context. It should start as user-triggered or action-triggered. The assistant may capture the
screen only when the user requests screen analysis or enables an advanced mode. Screen
data should be processed locally and should not be stored or transmitted by default.
## PROCESSING
Processing refers to how raw input becomes an intelligent suggestion or action.
The system should not ask a large local AI model what to do every second. Instead, it should
use a two-layer intelligence model:
Tiny Always-On Brain
This is the lightweight background system. It tracks events, updates state, detects
meaningful changes, and decides whether deeper reasoning may be useful. It uses
counters, timers, simple similarity checks, cached context, and lightweight rules. It should
consume very little CPU or memory.
Occasional AI Brain
This is called only when something meaningful happens. It receives a compact context
packet and decides what the user may be doing, whether the assistant should ask a
question, and what action may be useful. Larger local AI models should only be used on
demand, not continuously.
The processing flow is:
## 1. Raw Event Collection
The system receives events such as app changes, window changes, clipboard
changes, selected text, shortcut activation, tab changes, or screen capture requests.
## 2. Context State Update
The system updates its internal state with recent activity. This includes active app,
active window, recent apps, recent tabs, clipboard status, selected text availability,
idle time, and recent user patterns.
## 3. Trigger Filter
The lightweight system decides whether the current situation is worth deeper
reasoning. Most events should not trigger AI. The system should only continue if
there is a meaningful signal, such as copied content, selected text, multiple related


tabs, rapid context switching, long focused activity, user shortcut activation, or screen
analysis request.
## 4. Context Packet Creation
If deeper reasoning is needed, the system creates a compact context packet. This
packet contains only the relevant information needed to understand the situation. It
should avoid unnecessary raw data.
Example context packet:
## {
"active_app": "Safari",
"window_title": "MacBook Air M3 Review",
"recent_tabs": ["MacBook Air M3", "Dell XPS 13", "ThinkPad T14"],
## "clipboard_type": "none",
"selected_text_available": false,
"pattern_hint": "possible comparison",
"screen_context_available": false
## }
## 5. Reasoning Layer
The reasoning layer asks:
● What is the user likely doing?
● Is there something useful the assistant can offer?
● Should the assistant stay silent?
● What question should be asked?
● What action should be offered?
The assistant should be question-first and proposal-based. It should not behave like a rigid
rule engine.
Instead of:
“Comparison detected. Compare tabs.”
It should ask:
“Are you comparing these options? I can turn them into a quick comparison.”
## 6. Decision Layer
The system decides whether to surface anything to the user. It considers confidence,
recent suggestions, user preferences, permissions, cooldowns, and whether the
suggestion is actually useful.
If confidence is low, the assistant should stay silent.
## 7. Action Routing
If the user accepts a suggestion, the action router sends the request to the correct
action module, such as summarize, explain, compare, rewrite, debug, organize,
screen analyze, or create next steps.
- AI Usage Rules
AI should be used only when needed.


Use lightweight rules for:
● Detecting app changes
● Tracking time spent
● Detecting clipboard changes
● Tracking app switching frequency
● Detecting repeated or related tabs
● Enforcing cooldowns
● Checking permissions
● Deciding whether an event is worth deeper analysis
Use AI for:
● Understanding ambiguous context
● Generating useful questions
● Summarizing text
● Explaining errors or concepts
● Comparing multiple items
● Understanding screen capture or OCR output
● Rewriting or refining content
● Creating structured next steps
## Optimization Principles
The system should be event-driven, not constantly polling. It should avoid continuous AI
calls, avoid continuous screen capture, and avoid storing large raw data.
Optimization rules:
● Use system events whenever possible
● Throttle background checks
● Cache recent context
● Build small context packets
● Use rules as filters before AI
● Call AI only after meaningful triggers
● Use screen capture only on demand or in explicit advanced mode
● Discard raw screenshots after processing unless the user saves them
● Store metadata and summaries instead of full raw content
● Keep the assistant useful even when the AI layer is disabled
## Performance Model
Always-On Layer:
Lightweight event tracking, state updates, cooldowns, and simple trigger filtering.
## Occasional Layer:
Context packet reasoning and proposal generation.


On-Demand Layer:
Local LLM, OCR, vision model, summarization, comparison, explanation, or deeper action
execution.
## OUTPUT
Output refers to what the user sees and what the assistant can do.
The output should feel Siri-like, native to macOS, and non-intrusive. The assistant should
mostly run in the background, but it should be callable at any time and able to surface useful
suggestions when appropriate.
Output has three levels:
## 1. Suggestion Card
A small, lightweight suggestion appears when the assistant has a useful question or
action to offer.
## Examples:
“Are you comparing these tabs? I can turn them into a quick comparison.”
[Compare] [Dismiss]
“You copied an error message. Want me to help figure it out?”
[Explain] [Suggest Fix] [Dismiss]
“Want me to pull the important points from this selected text?”
[Summarize] [Dismiss]
Suggestion cards should:
● Be short and contextual
● Ask a question instead of making a hard assumption
● Show one main action at a time
● Be dismissible
● Never stack
● Auto-disappear after a short time
● Respect cooldowns and user preferences
## 2. Assistant Panel
The assistant panel opens when the user clicks the menu bar icon, uses a keyboard
shortcut, or accepts a suggestion.
The panel should show:
● Current understood context
● A small set of relevant actions
● A place to view action results
● Optional follow-up actions
● Settings or permission shortcuts when needed


## Example:
Context: Comparing products in Safari
## Suggested Actions:
● Compare open tabs
● Summarize differences
● Extract pros and cons
● Recommend best option based on criteria
## 3. Action Results
When the user accepts an action, the assistant produces a result.
Possible results include:
## ● Summary
## ● Explanation
● Comparison table
● Rewritten text
● Debugging explanation
● Suggested fix
● Organized tab group
● Extracted key points
● Next-step checklist
● Screen analysis result
Actions should be previewed before being applied. The assistant should not make
irreversible changes without confirmation. Results should be copyable, dismissible, and
reversible when possible.
## FULL PIPELINE SUMMARY
## Input:
The assistant gathers lightweight macOS context through app activity, window titles,
clipboard changes, selected text, browser/app context, user triggers, and optional screen
capture.
## Processing:
A tiny always-on brain tracks events and builds context. It filters for meaningful moments.
When needed, it creates a compact context packet and sends it to an occasional AI
reasoning layer. The reasoning layer proposes a useful question or action. The decision
layer decides whether to show it. If the user accepts, the action router executes the correct
action module.
## Output:
The assistant surfaces a small Siri-like suggestion, opens a fuller assistant panel when
engaged, and produces useful action results such as summaries, explanations,
comparisons, rewrites, debugging help, organization, or screen analysis.
## Core Pipeline Principle


The assistant should feel AI-native and reactive, but it should not rely on heavy AI running
constantly. The intelligence comes from combining lightweight always-on awareness with
occasional deeper reasoning at the right moments.

## INPUT / SOURCES — MACOS CONTEXT-AWARE ASSISTANT
This section defines where the assistant gets information from and what sources it uses to
make decisions.
The system should be designed around modular sources. Each source should be separate,
permission-aware, and replaceable. The assistant should not depend on one giant input
stream. Instead, it should gather small pieces of context from different macOS and app-level
sources.
## Core Principle
The assistant should collect only the context it needs, only when it needs it, and preferably
through local, permission-based macOS features.
## SOURCE CATEGORIES
The system has five main source categories:
- macOS Native Sources
- User-Intent Sources
- App-Specific Sources
## 4. Screen / Vision Sources
## 5. Intelligence / Decision Sources
## 6. MACOS NATIVE SOURCES
These are the core system-level sources used to understand what is happening on the Mac.
## Active App Source
Purpose: Detect which app the user is currently using.
Possible implementation:
● NSWorkspace
● frontmost application tracking
## Provides:
● current active app
● app bundle identifier
● app name
● app launch/quit events
● app switching events
Used for:


● understanding current workflow
● deciding which actions are relevant
● detecting app switching patterns
● building the context packet
## Example:
Active app: Safari
Previous app: Notes
Recent app switches: Safari → Notes → Safari
## Window Title Source
Purpose: Understand the current focused window at a lightweight level.
Possible implementation:
● Accessibility API
● window metadata where available
## Provides:
● active window title
● document/file name if exposed
● webpage title if exposed
● project/file context in some apps
Used for:
● detecting what the user is working on
● building context without reading full content
● identifying research, coding, writing, or comparison workflows
## Example:
Active app: VS Code
Window title: main.py — ProjectName
## Idle / Activity Source
Purpose: Detect whether the user is actively working or idle.
Possible implementation:
● system idle time APIs
● event monitoring
## Provides:
● idle time
● active session length
● return-from-idle events
Used for:


● detecting work sessions
● deciding when to summarize or offer recap
● avoiding suggestions while the user is away
## Time / Session Source
Purpose: Track lightweight session context.
## Provides:
● time of day
● duration in current app
● duration in current task-like state
● recent activity window
Used for:
● understanding patterns
● preventing repeated suggestions
● managing cooldowns
● detecting long focused sessions
## 2. USER-INTENT SOURCES
These sources are important because they suggest the user may want help.
## Clipboard Source
Purpose: Detect copied content that may be actionable.
Possible implementation:
● NSPasteboard monitoring
## Provides:
● copied text
● copied URL
● copied file path
● copied image, if supported later
● clipboard change timestamp
Used for:
● copied error detection
● copied paragraph rewriting
● copied link summarization
● copied product/page comparison
● user-intent based context
## Important:
Clipboard reading should be transparent and optionally toggleable. The system should avoid
storing full clipboard history by default.


## Selected Text Source
Purpose: Use user-highlighted text as explicit context.
Possible implementation:
● Accessibility API
● app-specific selection APIs where available
## Provides:
● selected text
● selection length
● source app
● source window
Used for:
● summarize selected text
● explain selected text
● rewrite selected text
● extract key points
● translate or reformat later
## Important:
Selected text is one of the strongest signals because the user intentionally highlighted
something.
## Keyboard Shortcut Source
Purpose: Let the user summon the assistant directly.
Possible implementation:
● global keyboard shortcut
## Provides:
● explicit user request
● current context at activation time
Used for:
● opening assistant panel
● asking the assistant to analyze current context
● triggering screen analysis
● bypassing automatic suggestion logic
## Menu Bar Source
Purpose: Provide always-available manual control.
## Provides:


● open assistant
● pause assistant
● permissions/settings
● manual screen analysis
● recent suggestions/history later
Used for:
● control center
● user trust
● explicit assistant activation
## 3. APP-SPECIFIC SOURCES
App-specific sources make the assistant more useful than basic system monitoring.
These should be implemented as plugins or modules, not hardcoded into the core system.
## Browser Source
Purpose: Understand browser-based workflows.
Possible sources:
● Safari integration
● Chrome integration
● browser extension
● AppleScript where possible
● Accessibility API fallback
## Provides:
● active tab title
● active tab domain
● active tab URL, if permitted
● recent tab titles
● related open tabs
● browser window context
Used for:
● research detection
● product comparison
● repeated search detection
● tab organization
● page summarization
● source grouping
## Example:
Recent tabs:
● MacBook Air M3 Review


● Dell XPS 13 Review
● ThinkPad T14 Review
Possible assistant question:
“Are you comparing these laptops? I can organize them into a quick comparison.”
VS Code / Coding Source
Purpose: Understand coding workflows.
Possible sources:
● VS Code extension later
● clipboard
● selected text
● active window title
● terminal output copied by user
## Provides:
● current file name
● selected code
● copied error
● project context, if extension exists
● language/framework hints
Used for:
● explain code
● debug copied errors
● suggest fixes
● create debugging checklist
● explain terminal output
## Finder Source
Purpose: Understand file-based workflows.
Possible sources:
● Finder selected items
● file paths
● file metadata
## Provides:
● selected file names
● selected folders
● file types
● recent file interaction
Used for:


● summarize PDFs later
● organize files
● rename files
● extract info from documents
● clean Downloads folder
## Notes / Writing App Source
Purpose: Support writing and note organization.
Possible sources:
● selected text
● clipboard
● Accessibility API
● app integrations later
## Provides:
● highlighted paragraph
● current document title where available
● copied/written text fragments
Used for:
● rewrite
● summarize
● structure notes
● expand ideas
● clean up rough writing
## Terminal Source
Purpose: Understand command-line workflows.
Possible sources:
● copied terminal output
● selected text
● active window title
## Provides:
● copied errors
● command output
● stack traces
● install/build messages
Used for:
● explain terminal errors
● suggest fixes


● summarize logs
● generate next debugging steps
## 4. SCREEN / VISION SOURCES
Screen capture is a planned major capability.
## Screen Capture Source
Purpose: Let the assistant understand visual context when normal APIs are not enough.
Possible implementation:
● ScreenCaptureKit
● macOS Screen Recording permission
## Provides:
● screenshot of current screen or window
● visual layout
● visible text through OCR
● image/chart/interface context
Used for:
● analyze current screen
● explain visual errors
● understand apps that do not expose text
● summarize visible content
● interpret diagrams, charts, images, or UI state
Default behavior:
Screen capture should not be the default always-on input. It should start as user-triggered.
Recommended modes:
● Manual screen analysis
● Suggestion-triggered screen analysis with confirmation
● Advanced continuous visual awareness only if explicitly enabled
## Screen Data Handling:
● process locally
● do not upload
● do not store raw screenshots by default
● discard screenshots after analysis unless user saves them
● show clear indicator when active
● allow instant pause
OCR Source
Purpose: Extract visible text from screenshots.


Possible implementation:
● Apple Vision OCR
● local OCR model if needed
## Provides:
● text from screen
● rough layout
● text blocks
Used for:
● summarizing visible pages
● explaining error dialogs
● reading inaccessible text
● extracting information from images or PDFs
## Vision Understanding Source
Purpose: Understand visual content beyond plain OCR.
Possible implementation:
● local vision model later
● small multimodal model when practical
● optional cloud model only if user explicitly enables it later
## Provides:
● image understanding
● chart/diagram interpretation
● UI state interpretation
Used for:
● “what am I looking at?”
● screen explanation
● diagram analysis
● visual comparison
## 5. INTELLIGENCE / DECISION SOURCES
These are not information sources from macOS. They are reasoning sources used to decide
what to do with the information.
## Rule / Heuristic Source
Purpose: Fast, lightweight filtering.
Used for:
● cooldowns


● rate limits
● permission checks
● detecting obvious events
● detecting repeated tab patterns
● detecting copied text
● deciding whether an event is worth deeper reasoning
This should be the always-on decision layer.
## Small Classifier Source
Purpose: Cheaply classify context before calling a larger model.
Possible use:
● classify current state as writing, coding, research, comparing, idle, overloaded,
debugging, or unknown
● decide whether the assistant should stay silent
● score usefulness of possible actions
This can be rule-based at first and replaced later with a small local model.
Local LLM Source
Purpose: Deeper reasoning and natural language generation.
Used for:
● generating useful questions
● interpreting ambiguous context
● summarizing
● explaining
● comparing
● rewriting
● creating next steps
● deciding action wording
## Important:
The local LLM should not run constantly. It should only be called when the lightweight
system decides deeper reasoning is useful.
Local Vision / OCR Source
Purpose: Understand screenshots and visual context.
Used for:
● screen analysis
● OCR extraction
● visual reasoning
● interpreting diagrams or inaccessible apps
This should be on-demand or advanced-mode only.


## Optional Cloud Source
Purpose: Future fallback for stronger reasoning if the user explicitly enables it.
## Default:
## Disabled.
If ever added:
● user must opt in
● data sent must be shown/controlled
● never silently used
● local-first remains the default
## SOURCE ACTIVATION RULES
Each source should have an activation rule.
## Examples:
## Active App Source:
Always active. Very cheap.
## Window Title Source:
Active when permission allows. Lightweight.
## Clipboard Source:
Active only if clipboard monitoring is enabled.
## Selected Text Source:
Activated when user highlights text, invokes assistant, or accepts a relevant action.
## Browser Source:
Activated when browser is frontmost or browser integration is enabled.
## Screen Capture Source:
Activated only by user request, accepted suggestion, or advanced mode.
Local LLM:
Activated only after a meaningful trigger creates a context packet.
## Vision Model:
Activated only after screen capture or image-based input.
## SOURCE DESIGN TEMPLATE
Every source should be defined using the same template:
## Source Name:
What it observes:
Permission required:
## Cost:


Default state:
When it activates:
What it outputs:
What actions it supports:
Privacy notes:
## Example:
## Source Name: Screen Capture Source
What it observes: Current screen or selected window
Permission required: Screen Recording
## Cost: High
Default state: Off / manual only
When it activates: User requests screen analysis or enables advanced mode
What it outputs: Screenshot, OCR text, visual layout
What actions it supports: screen explanation, visual debugging, chart analysis, visible text
summary
Privacy notes: Process locally, discard raw screenshots, show active indicator
## CORE SOURCE PRINCIPLE
The assistant should not be built around one invasive input source. It should combine many
small, permission-aware sources into a compact context packet.
The product becomes powerful by layering sources:
Basic metadata gives awareness.
User-intent signals give relevance.
App-specific sources give precision.
Screen capture gives universal fallback.
AI reasoning turns the context into useful questions and actions.
The system should always start with the cheapest and least invasive source, then escalate
only when needed.
## CONTEXT MODEL — MACOS CONTEXT-AWARE ASSISTANT
The context model is the core data structure that represents the current state of the user’s
workflow. It is the single, standardized object that all parts of the system use to understand
what is happening.
## Core Principle
All raw input from macOS, apps, clipboard, and screen capture must be transformed into a
clean, structured context object before any reasoning or actions occur.
The context model acts as the “language” of the system. Every module reads from it and
writes to it. This prevents messy dependencies and keeps the system modular.
Purpose of the Context Model


● Normalize all incoming signals into a consistent structure
● Provide a snapshot of the user’s current situation
● Allow reasoning layers to operate cleanly
● Enable easy addition of new features without breaking existing logic
● Support both rule-based and AI-based decision making
## CONTEXT MODEL STRUCTURE
The context model should be a compact, structured object composed of the following
sections:
## 1. Core Metadata
- App and Window Context
## 3. Activity State
## 4. User Intent Signals
- App-Specific Context
## 6. Screen / Vision Context
## 7. System State
## 8. Suggested Action Space
- Confidence and Reasoning Hints
## 10. Privacy Level
## 11. CORE METADATA
Basic information about the context snapshot.
## Fields:
● timestamp
● session_id
● event_id
● source_trigger (what caused this context to be built)
## Example:
timestamp: 2026-05-01T14:32:10
source_trigger: clipboard_changed
## 2. APP AND WINDOW CONTEXT
Describes where the user is currently working.
## Fields:
● active_app_name
● active_app_bundle_id
● active_window_title
● app_category (browser, editor, terminal, notes, etc.)
● recent_apps (last 3–5 apps used)
## Example:


active_app_name: Safari
active_window_title: MacBook Air M3 Review
app_category: browser
## 3. ACTIVITY STATE
Represents what the system believes the user is doing at a high level.
This is an interpreted field, not raw data.
Possible values:
● browsing
● research
● comparison
● writing
● editing
● coding
● debugging
● reading
● idle
● context_switching
● unknown
## Example:
activity_state: comparison
This field can be rule-based initially and improved later using AI.
## 4. USER INTENT SIGNALS
Captures strong indicators that the user may want help.
## Fields:
● selected_text_available (true/false)
● selected_text_length
● clipboard_changed (true/false)
● clipboard_type (text, url, code, image, none)
● manual_trigger (true/false)
● keyboard_shortcut_used (true/false)
## Example:
selected_text_available: true
clipboard_type: text
These signals heavily influence whether the assistant should act.


## 5. APP-SPECIFIC CONTEXT
Holds structured data from specific apps or integrations.
Fields may include:
## Browser Context:
● active_tab_title
● active_tab_domain
● recent_tab_titles
● related_tabs_detected (true/false)
## Editor Context:
● current_file_name
● language (python, js, etc.)
● error_detected (true/false)
## Finder Context:
● selected_files
● file_types
## Terminal Context:
● copied_output
● error_like_output (true/false)
## Example:
active_tab_title: Dell XPS 13 Review
recent_tab_titles: [MacBook Air M3, Dell XPS 13, ThinkPad T14]
This section should remain modular and expandable.
## 6. SCREEN / VISION CONTEXT
Used only when screen capture or visual analysis is active.
## Fields:
● screen_capture_available (true/false)
● screen_capture_type (manual, suggested, continuous)
● ocr_text_summary
● visual_context_tags (chart, code, webpage, UI, etc.)
## Example:
screen_capture_available: true
visual_context_tags: ["webpage", "product", "specs_table"]


This section should be empty unless screen capture is used.
## 7. SYSTEM STATE
Tracks environment and behavioral context.
## Fields:
● idle_time_seconds
● session_duration
● app_switch_frequency
● focus_state (focused, distracted, idle)
## Example:
focus_state: distracted
app_switch_frequency: high
This helps detect patterns like overload or context switching.
## 8. SUGGESTED ACTION SPACE
Represents possible actions the system could take.
This is not final output, but a list of candidates.
## Fields:
● candidate_actions (list of action identifiers)
## Examples:
candidate_actions:
● summarize_text
● compare_tabs
● explain_error
● organize_tabs
This list is generated before final decision making.
## 9. CONFIDENCE AND REASONING HINTS
Helps the system decide whether to act.
## Fields:
● activity_confidence (0–1)
● intent_confidence (0–1)
● usefulness_score (0–1)
● pattern_hint (short description)


## Example:
activity_confidence: 0.82
pattern_hint: "multiple similar tabs open"
Low confidence should result in no suggestion.
## 10. PRIVACY LEVEL
Tracks what level of data access was used to build the context.
## Fields:
● privacy_level (metadata_only, user_intent, app_specific, screen_capture)
## Example:
privacy_level: user_intent
This ensures transparency and enforces limits.
## CONTEXT MODEL FLOW
All input sources feed into this model:
## Raw Input → Context Builder → Context Model → Processing → Output
No module should directly use raw input. Everything must go through the context model.
## EXAMPLE CONTEXT PACKET
## {
"timestamp": "2026-05-01T14:32:10",
## "source_trigger": "browser_tab_change",
"active_app_name": "Safari",
"active_window_title": "MacBook Air M3 Review",
## "app_category": "browser",
## "activity_state": "comparison",
## "user_intent_signals": {
"selected_text_available": false,
"clipboard_changed": false,
"manual_trigger": false
## },
## "app_specific_context": {
## "recent_tab_titles": [
"MacBook Air M3",
"Dell XPS 13",
"ThinkPad T14"
## ],
"related_tabs_detected": true


## },
## "system_state": {
## "focus_state": "focused",
## "app_switch_frequency": "low"
## },
## "candidate_actions": [
## "compare_tabs",
## "summarize_pages",
## "extract_key_differences"
## ],
## "confidence": {
## "activity_confidence": 0.85,
## "usefulness_score": 0.88
## },
## "privacy_level": "metadata_only"
## }
## CORE CONTEXT MODEL PRINCIPLE
The assistant should never reason directly on raw system data.
All understanding must pass through a structured context model that is:
● small
● modular
● easy to extend
● privacy-aware
● compatible with both rules and AI
This is what keeps the system scalable and prevents it from becoming messy.
## ABILITIES / ACTIONS — MACOS CONTEXT-AWARE ASSISTANT
This section defines what the assistant can actually do once it understands context.
## Core Principle
The assistant is not a single tool. It is a system that proposes and executes modular actions.
Each action should be independent, reusable, and triggered based on context.
Actions should never run automatically without user confirmation unless explicitly designed
as safe (e.g., opening a panel). The assistant proposes actions first, then executes them
when the user accepts.
## ACTION DESIGN PHILOSOPHY
● Actions should solve real, common tasks
● Actions should feel immediate and useful
● Actions should be context-driven, not manually searched
● Actions should be modular and extensible
● Actions should require minimal user effort


● Actions should be reversible or non-destructive
Each action should follow a consistent structure:
## Action Name
What it does
Input required
Output produced
When it is suggested
Permission required
## ACTION CATEGORIES
Actions are grouped into the following categories:
## 1. Understanding Actions
## 2. Transformation Actions
## 3. Comparison Actions
## 4. Organization Actions
## 5. Decision Support Actions
## 6. Coding / Debugging Actions
## 7. System / Workflow Actions
## 8. Screen / Vision Actions
## 9. Future / Advanced Actions
## 10. UNDERSTANDING ACTIONS
Purpose: Help the user understand content quickly.
## Summarize Content
What it does:
Condenses text into key points.
## Input:
Selected text, clipboard text, or page content
## Output:
Short summary or bullet points
When suggested:
Large text selection, long copied text, article reading
## Permission:
User-intent or app-specific
## Explain Content
What it does:
Explains concepts, errors, or content in simpler terms.
## Input:
Selected text or copied content


## Output:
Explanation or breakdown
When suggested:
Technical text, errors, complex paragraphs
## Permission:
## User-intent
## Extract Key Points
What it does:
Pulls out main ideas, facts, or highlights.
## Input:
Text or page content
## Output:
List of key points
When suggested:
Reading/research context
## 2. TRANSFORMATION ACTIONS
Purpose: Modify or improve user content.
## Rewrite Text
What it does:
Improves clarity, tone, or structure.
## Input:
Selected text
## Output:
Rewritten version
When suggested:
Writing/editing context
## Clean Up Text
What it does:
Fixes grammar, formatting, or rough notes.
## Input:
Selected or pasted text
## Output:
Cleaned version


When suggested:
Messy notes or drafts
## Expand Content
What it does:
Adds detail or elaborates on ideas.
## Input:
Short text or notes
## Output:
Expanded version
When suggested:
Brief or incomplete content
## 3. COMPARISON ACTIONS
Purpose: Help users compare options or data.
## Compare Tabs
What it does:
Creates a structured comparison of open tabs.
## Input:
Tab titles, URLs, or content
## Output:
Comparison table or summary
When suggested:
Multiple similar tabs detected
## Compare Items
What it does:
Compares products, options, or ideas.
## Input:
Selected items or inferred context
## Output:
Differences, pros/cons
When suggested:
Research or decision context
## 4. ORGANIZATION ACTIONS
Purpose: Reduce clutter and structure information.


## Organize Tabs
What it does:
Groups or labels related tabs.
## Input:
Open tab list
## Output:
Organized tab groups
When suggested:
Many open tabs or repeated topics
## Extract Structure
What it does:
Turns content into structured format.
## Input:
Text or notes
## Output:
Outline, checklist, or sections
When suggested:
Unstructured notes or long text
## 5. DECISION SUPPORT ACTIONS
Purpose: Help users decide between options.
## Suggest Best Option
What it does:
Analyzes options and recommends one.
## Input:
Multiple items or pages
## Output:
Recommendation with reasoning
When suggested:
Comparison context
Generate Pros and Cons
What it does:
Lists advantages and disadvantages.
## Input:
Items or topic


## Output:
Pros/cons list
When suggested:
Decision-making context
## 6. CODING / DEBUGGING ACTIONS
Purpose: Help with programming workflows.
## Explain Error
What it does:
Explains error messages or logs.
## Input:
Copied error or selected text
## Output:
Explanation and possible cause
When suggested:
Error-like clipboard content
## Suggest Fix
What it does:
Provides possible solutions.
## Input:
Error or code snippet
## Output:
Suggested fixes
When suggested:
Debugging context
## Improve Code
What it does:
Suggests improvements or refactors.
## Input:
Selected code
## Output:
Optimized version
When suggested:
Code selection
## 7. SYSTEM / WORKFLOW ACTIONS


Purpose: Improve workflow efficiency.
## Focus Prompt
What it does:
Suggests refocusing when switching context.
## Input:
App switching patterns
## Output:
Prompt or suggestion
When suggested:
Frequent switching
## Session Summary
What it does:
Summarizes recent activity.
## Input:
Session data
## Output:
Activity summary
When suggested:
End of session or idle return
## Next Step Suggestion
What it does:
Suggests what to do next.
## Input:
Current context
## Output:
Action suggestion
When suggested:
Ambiguous or stalled state
## 8. SCREEN / VISION ACTIONS
Purpose: Use visual context when available.
## Analyze Screen
What it does:
Explains what is on the screen.


## Input:
## Screenshot
## Output:
Description or summary
When suggested:
User-triggered or advanced mode
Extract Text from Screen
What it does:
Runs OCR on visible content.
## Input:
## Screenshot
## Output:
Extracted text
When suggested:
Image or inaccessible text
## Explain Visual Error
What it does:
Interprets UI errors or diagrams.
## Input:
## Screenshot
## Output:
## Explanation
When suggested:
Visual debugging context
## 9. FUTURE / ADVANCED ACTIONS
These can be added later without changing the system core.
## Examples:
● File organization and cleanup
● PDF summarization
● Calendar/task integration
● Multi-step workflow automation
● Cross-app context linking
## ACTION SELECTION PRINCIPLES
The assistant should:


● Show only 2–5 actions at a time
● Prioritize high-confidence actions
● Avoid overwhelming the user
● Prefer question-based phrasing
● Allow easy dismissal
## ACTION EXECUTION RULES
● Actions should be previewed before applying
● No irreversible changes without confirmation
● Results should be copyable
● Results should be dismissible
● Actions should not block user workflow
## ACTION MODULE DESIGN
Each action should be implemented as an independent module.
Module structure:
● input handler
● processing logic
● optional AI call
● output formatter
## Example:
## Action: Summarize Content
Input: selected_text
Processing: local AI summarization
Output: bullet point summary
## CORE ACTION PRINCIPLE
The assistant’s value comes from surfacing the right action at the right time.
The system should not try to do everything automatically. It should propose useful actions,
let the user decide, and execute them cleanly.
The actions define what the assistant can do, while the context model defines when those
actions are relevant.
## TRIGGER SYSTEM — MACOS CONTEXT-AWARE ASSISTANT
The trigger system determines when the assistant should react.
## Core Principle
The assistant should not react to everything. It should only react when there is a meaningful
opportunity to help. The trigger system acts as a filter between raw context and visible
suggestions.


The goal is to:
● Avoid noise
● Avoid unnecessary AI calls
● Surface only high-value moments
● Maintain a reactive, intelligent feel
The trigger system sits between the context model and the decision engine.
## FLOW POSITION
## Raw Input → Context Model → Trigger System → Reasoning Layer → Output
The trigger system decides whether the context is worth deeper reasoning.
## TRIGGER SYSTEM STRUCTURE
The system consists of:
## 1. Event Triggers
## 2. Context Triggers
## 3. Confidence Filters
## 4. Cooldown System
## 5. Permission Filters
## 6. Trigger Output
## 7. EVENT TRIGGERS
These are direct signals from user activity.
## Examples:
● clipboard_changed
● selected_text_detected
● app_switched
● tab_changed
● keyboard_shortcut_used
● menu_bar_clicked
● screen_capture_requested
Event triggers are lightweight and always available.
They do not directly cause actions. They only signal that something happened.
## Example:
clipboard_changed → potential trigger
selected_text_detected → strong trigger
## 2. CONTEXT TRIGGERS
These are higher-level conditions derived from the context model.


## Examples:
## Comparison Context
● multiple similar tabs open
● repeated related searches
## Debugging Context
● clipboard contains error-like text
● active app is editor or terminal
## Writing Context
● selected text length above threshold
● active app is notes or document editor
## Information Overload
● many tabs open
● frequent context switching
## Focused Session
● long time in one app
Context triggers are more meaningful than raw events.
They represent “situations” instead of raw signals.
## 3. CONFIDENCE FILTERS
Before triggering any suggestion, the system evaluates confidence.
## Fields:
● activity_confidence
● intent_confidence
● usefulness_score
## Rules:
● If confidence is low → do nothing
● If usefulness is unclear → do nothing
● Only high-confidence contexts proceed
This ensures the assistant does not feel random or annoying.
## 4. COOLDOWN SYSTEM
Prevents the assistant from becoming intrusive.


## Rules:
● Only one suggestion at a time
● Minimum time between suggestions
● No repeated suggestion for same context
● Suppress triggers after user dismissal
## Example:
If user dismisses “Compare tabs” → do not show again for that session
Cooldown parameters:
● global cooldown (e.g., 2–5 minutes)
● context-specific cooldown
● action-specific cooldown
## 5. PERMISSION FILTERS
Ensures triggers respect user privacy and system permissions.
## Rules:
● If source requires permission and is disabled → skip
● If screen capture not allowed → no vision triggers
● If clipboard monitoring disabled → ignore clipboard triggers
## Example:
If screen capture is disabled:
Do not trigger screen analysis suggestions
## 6. TRIGGER OUTPUT
The trigger system outputs either:
● no action (silent)
● or a trigger packet for reasoning
Trigger packet example:
## {
## "trigger_type": "context",
"context_reason": "multiple similar tabs detected",
## "confidence": 0.87,
## "candidate_actions": ["compare_tabs", "summarize_pages"],
"requires_ai": true
## }
If no meaningful trigger exists:
→ system remains silent


## TRIGGER TYPES
Triggers can be categorized as:
## Strong Triggers
These almost always lead to suggestions:
● selected_text_detected
● clipboard_changed (with meaningful content)
● manual shortcut activation
● screen_capture_requested
## Medium Triggers
Require context confirmation:
● tab patterns
● app switching patterns
● repeated searches
● long focused sessions
## Weak Triggers
Rarely trigger alone:
● single app change
● short activity bursts
● minimal context
Weak triggers should be combined with other signals.
## TRIGGER STRATEGY
The system should prioritize:
User-Intent First
If the user selects text, copies content, or triggers the assistant:
→ almost always respond
## Context Patterns Second
If the system detects meaningful patterns:
→ consider suggestion
## Passive Monitoring Last
If no strong signal exists:
→ stay silent
## QUESTION-FIRST TRIGGERS
All triggers should lead to a proposed question, not a command.


Instead of:
“Compare these tabs.”
## Use:
“Are you comparing these tabs? I can turn them into a quick comparison.”
This maintains a reactive and non-intrusive experience.
## ANTI-SPAM RULES
The assistant must:
● never show multiple suggestions simultaneously
● avoid repeating dismissed suggestions
● avoid generic prompts
● avoid interrupting during active typing if possible
● prioritize quality over quantity
## FAILURE CONDITIONS
The trigger system fails if:
● it fires too often
● it fires without clear value
● it repeats suggestions
● it ignores user dismissals
● it surfaces low-confidence actions
## CORE TRIGGER PRINCIPLE
The assistant should not react frequently.
It should react correctly.
The trigger system exists to ensure that only meaningful, high-confidence opportunities are
surfaced, preserving a clean and intelligent user experience.

## PERMISSION MODEL — MACOS CONTEXT-AWARE ASSISTANT
The permission model defines what the assistant is allowed to access, when it can access it,
and how that access is controlled by the user.
## Core Principle
The assistant must be private by default, transparent in capability, and progressive in
access. It should start with minimal permissions and only expand when the user explicitly
allows it.


The goal is to:
● Build trust through clarity and control
● Avoid unnecessary or invasive access
● Allow advanced capabilities without forcing them
● Keep the system usable even with minimal permissions
## PERMISSION DESIGN PHILOSOPHY
● Default to the least invasive level
● Request permissions only when needed
● Explain why each permission is required
● Allow users to enable/disable each permission independently
● Never silently escalate permissions
● Always provide a way to pause or revoke access
## PERMISSION TIERS
The system is divided into progressive permission tiers.
Each tier unlocks more capability.
Tier 0 — System Metadata (Default, No Prompt)
This tier requires no special permissions.
## Provides:
● active app name
● app switching
● session duration
● idle time
● basic timing signals
Used for:
● baseline awareness
● minimal context understanding
● safe, always-on operation
This tier must always be available.

## Tier 1 — Accessibility Access
## Requires:
● macOS Accessibility permission
## Provides:


● active window title
● selected text
● UI element access (limited)
Used for:
● text-based actions
● understanding document context
● enabling most core features
## Importance:
This is the most important permission for functionality.
## User Experience:
● requested early but not forced
● clearly explained as enabling “context-aware assistance”

## Tier 2 — Clipboard Access
## Requires:
● user consent (no explicit system dialog, but must be disclosed)
## Provides:
● copied text
● copied URLs
● copied content types
Used for:
● debugging copied errors
● summarizing copied content
● interpreting user intent
## Privacy Handling:
● do not store clipboard history by default
● process only recent clipboard changes
● allow user to disable at any time

Tier 3 — App-Specific Access
## Requires:
● per-app integration or user approval


## Provides:
● browser tab titles and domains
● editor context (via extensions)
● Finder selection
● app-specific structured data
Used for:
● deeper context understanding
● more accurate action suggestions
## Examples:
● browser integration for tab comparison
● VS Code extension for debugging context
## Design:
This tier should be modular and optional.

Tier 4 — Screen Recording (Screen Capture)
## Requires:
● macOS Screen Recording permission
## Provides:
● screenshots
● visual context
● OCR text
● UI layout understanding
Used for:
● screen analysis
● visual debugging
● interpreting inaccessible apps
● extracting information from images
## Default Behavior:
● disabled by default
● activated only when needed
## Modes:
## Manual Mode:


● user explicitly requests screen analysis
## Suggestion Mode:
● assistant suggests screen analysis, user confirms
## Advanced Mode:
● continuous visual awareness (explicit opt-in only)
## Privacy Rules:
● process locally
● do not upload
● do not store raw screenshots by default
● discard after processing
● provide visual indicator when active
● allow instant pause

Tier 5 — Advanced Integrations (Future)
Optional future tier.
## Provides:
● file system organization
● calendar/task integration
● cross-app workflows
● automation capabilities
## Requires:
● explicit user opt-in
● granular control per integration

## PERMISSION STATES
Each permission can be in one of three states:
## ● Disabled
## ● Enabled
## ● Temporarily Paused
The system should adapt behavior based on these states.
## Example:


If screen recording is disabled:
● do not suggest screen-based actions
If clipboard is disabled:
● ignore clipboard triggers

## PERMISSION REQUEST STRATEGY
Permissions should not be requested all at once.
## Instead:
● request only when needed
● provide clear explanation
● tie request to a feature
## Example:
User selects text → assistant suggests “Summarize”
→ system requests Accessibility permission with explanation
This creates a natural permission flow.

## PERMISSION DASHBOARD
The assistant should include a central control panel where users can:
● view all permissions
● enable/disable each permission
● understand what each permission does
● pause the assistant entirely
● control advanced modes
This builds transparency and trust.

## VISUAL INDICATORS
The system should provide feedback when higher-level access is active.
## Examples:
● indicator when screen capture is active
● indicator when advanced mode is enabled


This prevents the assistant from feeling hidden or intrusive.

## FAIL-SAFE BEHAVIOR
If permissions are restricted:
● the system should degrade gracefully
● continue operating with available data
● avoid errors or broken behavior
## Example:
No screen capture:
● rely on metadata and text context
No accessibility:
● rely on app-level context and clipboard

## SECURITY PRINCIPLES
● never store sensitive data unless required
● never transmit user data without explicit opt-in
● avoid long-term storage of raw content
● prefer derived summaries over raw data
● isolate permission usage per module

## CORE PERMISSION PRINCIPLE
The assistant should feel powerful without feeling invasive.
It should earn trust by:
● starting simple
● explaining access clearly
● giving users full control
● expanding capability only when allowed
The permission model ensures the assistant remains both useful and trustworthy as it
becomes more capable.


## INTELLIGENCE LAYER — MACOS CONTEXT-AWARE ASSISTANT
The intelligence layer defines how the assistant thinks.
It determines how context is interpreted, how decisions are made, and how actions are
proposed. This layer is responsible for making the system feel reactive, adaptive, and
intelligent rather than rigid or rule-based.
## Core Principle
The assistant should not rely on a single large model running constantly. Instead, it should
use layered intelligence:
● Lightweight, always-on logic for awareness
● Selective AI reasoning for understanding
● On-demand AI for generating results
The system should feel AI-driven, but remain efficient and controllable.
## INTELLIGENCE STRUCTURE
The intelligence layer is divided into three levels:
- Always-On Intelligence (Lightweight Layer)
- Reasoning Intelligence (Selective Layer)
- Execution Intelligence (On-Demand Layer)
## 4. ALWAYS-ON INTELLIGENCE
This layer runs continuously in the background.
## Purpose:
● Track activity
● Detect basic patterns
● Filter events
● Decide whether deeper reasoning is needed
## Characteristics:
● extremely lightweight
● rule-based or heuristic-based
● no large models
● minimal CPU and memory usage
## Responsibilities:
● track app changes
● track clipboard events
● track selection events
● track tab patterns
● detect repeated behavior


● enforce cooldowns
● check permissions
● maintain session state
## Example:
User switches apps rapidly
→ Always-on layer detects high switching frequency
→ flags possible “context switching” state
This layer does not decide what to do. It only decides:
“Is this worth thinking about?”
## 2. REASONING INTELLIGENCE
This layer is responsible for interpreting context and proposing actions.
## Purpose:
● understand what the user is doing
● decide whether to surface something
● generate useful questions or suggestions
## Characteristics:
● runs only when triggered
● uses a small or mid-sized local model
● receives compact context packets
● returns structured decisions
## Inputs:
● context model
● trigger packet
● permission state
● recent assistant history
## Responsibilities:
● interpret activity state
● infer user intent
● evaluate usefulness of possible actions
● generate proposal (question-first)
● rank candidate actions
## Example:
Input context:
● Safari active


● multiple similar tabs open
Reasoning output:
“User may be comparing products”
“High usefulness for comparison”
Generated proposal:
“Are you comparing these options? I can turn them into a quick comparison.”
This layer is what replaces rigid rule-based logic with adaptive reasoning.
## 3. EXECUTION INTELLIGENCE
This layer runs only after the user accepts an action.
## Purpose:
● perform the requested task
● generate outputs such as summaries, comparisons, explanations
## Characteristics:
● on-demand only
● may use larger local models
● may use OCR or vision models
● can take more compute temporarily
## Responsibilities:
● summarize text
● explain errors
● compare multiple items
● rewrite content
● analyze screenshots
● generate structured outputs
## Example:
User clicks “Compare Tabs”
→ Execution layer gathers relevant data
→ calls local model
→ returns comparison table
This layer should not run unless the user explicitly requests an action.
## MODEL USAGE STRATEGY
The system should not rely on one large model.


Instead, use different levels of intelligence:
## No Model
Used for:
● event tracking
● simple pattern detection
● cooldown logic
● permission checks
Small Model (Optional)
Used for:
● classifying context
● estimating usefulness
● deciding whether to trigger reasoning
## Medium Model
Used for:
● reasoning about context
● generating proposals
● ranking actions
Larger Model (Optional)
Used for:
● complex summarization
● detailed explanation
● advanced comparison
● vision understanding
The system should remain functional even if only the basic layers are available.
## LOCAL-FIRST DESIGN
All intelligence should run locally by default.
## Rules:
● no constant cloud calls
● no background data transmission
● no hidden processing
● all reasoning happens on-device
Optional future:
Cloud-based reasoning may be added only if:
● explicitly enabled by the user


● clearly explained
● fully controllable
## REASONING STYLE
The assistant should be question-first.
Instead of:
“Summarize this text.”
It should propose:
“Want me to pull out the important points from this?”
Instead of:
“Compare these tabs.”
It should propose:
“Are you comparing these options? I can organize them into a quick comparison.”
This makes the system feel reactive and natural.
## DECISION LOGIC
The intelligence layer must decide:
● Should the assistant say anything?
● What is the user likely trying to do?
● What actions are relevant?
● How confident is the system?
● Should it stay silent?
If confidence is low:
→ do nothing
If usefulness is unclear:
→ do nothing
Silence is always better than noise.
## OPTIMIZATION STRATEGY
To prevent performance issues:
● do not run AI continuously
● use event-driven triggers


● build small context packets
● cache recent context
● reuse recent reasoning when possible
● limit model calls with cooldowns
● avoid unnecessary screen capture
The assistant should feel intelligent without consuming noticeable resources.
## FAILURE CONDITIONS
The intelligence layer fails if:
● it relies too heavily on AI for simple tasks
● it generates generic or irrelevant suggestions
● it triggers too often
● it consumes too much CPU or memory
● it becomes unpredictable
● it ignores user dismissals
## CORE INTELLIGENCE PRINCIPLE
The assistant should feel like it understands the user, but it should only think deeply when
needed.
Lightweight awareness should run constantly.
Deep reasoning should happen occasionally.
Heavy processing should happen only on demand.
This layered intelligence approach allows the system to be reactive, intelligent, and efficient
at the same time.
## SYSTEM ARCHITECTURE — MACOS CONTEXT-AWARE ASSISTANT
The system architecture defines how the project is structured internally so it can stay clean,
scalable, and easy to extend.
## Core Principle
The assistant should be built as a modular macOS-native system where each layer has one
clear responsibility. No single file or module should control everything.
The architecture should separate:
● macOS system access
● context building
● intelligence and decision making
● action execution
● user interface
● storage and settings
## HIGH-LEVEL ARCHITECTURE


The system should follow this structure:
macOS Sources
## ↓
## Source Manager
## ↓
## Context Builder
## ↓
## Context Model
## ↓
## Trigger System
## ↓
## Intelligence Layer
## ↓
## Action Router
## ↓
## Action Modules
## ↓
Output UI
## MAIN ARCHITECTURE LAYERS
- macOS System Layer
## 2. Source Manager
## 3. Context Builder
## 4. Trigger System
## 5. Intelligence Layer
## 6. Action Router
## 7. Action Modules
- UI Layer
## 9. Storage Layer
- Settings and Permissions Layer
## 11. MACOS SYSTEM LAYER
## Purpose:
Handles direct interaction with macOS APIs.
## Responsibilities:
● active app detection
● app switching detection
● window title access
● accessibility access
● clipboard monitoring
● keyboard shortcut handling
● screen capture
● menu bar integration
Possible technologies:


## ● Swift
● SwiftUI
● AppKit
● NSWorkspace
● Accessibility API
● NSPasteboard
● ScreenCaptureKit
● Vision framework
## Rule:
This layer should only collect system information. It should not decide what actions to
suggest.
## 2. SOURCE MANAGER
## Purpose:
Coordinates all input sources.
## Responsibilities:
● start and stop sources
● check permissions
● normalize raw source events
● prevent duplicate events
● send clean events to the context builder
Example sources:
● ActiveAppSource
● WindowTitleSource
● ClipboardSource
● SelectionSource
● BrowserSource
● ScreenCaptureSource
● ShortcutSource
## Rule:
Each source should be independent and replaceable.
## 3. CONTEXT BUILDER
## Purpose:
Transforms raw events into a structured context model.
## Responsibilities:
● merge recent events
● maintain current session state
● track recent apps/tabs/actions
● create context packets


● remove unnecessary raw data
● enforce privacy limits
## Input:
raw source events
## Output:
standardized context model
## Rule:
No reasoning should happen directly on raw system events. Everything should pass through
the context builder.
## 4. TRIGGER SYSTEM
## Purpose:
Decides whether the current context is worth deeper reasoning.
## Responsibilities:
● detect meaningful moments
● apply cooldowns
● apply confidence thresholds
● suppress repeated suggestions
● check permission availability
● create trigger packets
## Examples:
● selected text detected
● copied error-like text
● several related tabs open
● user invoked assistant manually
● screen analysis requested
## Rule:
The trigger system does not generate final suggestions. It only decides whether the
intelligence layer should be called.
## 5. INTELLIGENCE LAYER
## Purpose:
Interprets context and decides what the assistant should propose.
## Responsibilities:
● infer what the user may be doing
● rank possible actions
● decide whether to stay silent
● generate question-first suggestions


● choose the most relevant action set
## Sub-layers:
● lightweight always-on logic
● selective reasoning model
● on-demand execution model
## Rule:
Large AI models should not run continuously. They should only be called after meaningful
triggers or user actions.
## 6. ACTION ROUTER
## Purpose:
Routes accepted actions to the correct module.
## Responsibilities:
● receive selected action
● check required permissions
● gather required context
● call the correct action module
● return results to UI
## Example:
User clicks “Compare Tabs”
→ Action Router sends request to CompareTabsAction
## Rule:
The action router should not contain action-specific logic. It only routes.
## 7. ACTION MODULES
## Purpose:
Perform specific assistant abilities.
## Examples:
● SummarizeAction
● ExplainAction
● RewriteAction
● CompareTabsAction
● DebugErrorAction
● OrganizeTabsAction
● ScreenAnalyzeAction
● ExtractKeyPointsAction
Each module should contain:


● input requirements
● permission requirements
● processing logic
● optional AI call
● output formatter
## Rule:
Each action should be isolated. Adding a new action should not require rewriting the whole
system.
## 8. UI LAYER
## Purpose:
Displays suggestions, assistant panel, results, and settings.
Main UI components:
● menu bar icon
● suggestion card
● assistant panel
● results view
● permissions/settings screen
● pause/resume control
## Responsibilities:
● show suggestions
● display current context
● display action results
● allow accept/dismiss
● allow manual assistant opening
● allow permission control
## Rule:
The UI should not contain core logic. It should display state and send user actions back to
the system.
## 9. STORAGE LAYER
## Purpose:
Stores lightweight local data.
## Stores:
● settings
● permissions state
● cooldowns
● recent suggestions
● user preferences
● action history


● cached context summaries
Should avoid storing:
● raw screenshots
● full clipboard history
● unnecessary sensitive content
● large raw logs
## Rule:
Store metadata and summaries by default, not raw private data.
## 10. SETTINGS AND PERMISSIONS LAYER
## Purpose:
Manages user control and privacy.
## Responsibilities:
● track enabled permissions
● expose toggles
● pause assistant
● manage advanced mode
● handle onboarding permission requests
● enforce module access limits
## Examples:
● clipboard monitoring enabled/disabled
● screen capture enabled/disabled
● accessibility enabled/disabled
● advanced visual awareness enabled/disabled
## Rule:
Every source and action must check permissions before running.
## RECOMMENDED PROJECT STRUCTURE
A clean folder structure could look like:
/App
MenuBarApp
AppEntry
AppLifecycle
/SystemSources
ActiveAppSource
WindowTitleSource
ClipboardSource
SelectionSource


ShortcutSource
ScreenCaptureSource
/SourceManager
SourceManager
SourceEvent
/Context
ContextBuilder
ContextModel
SessionState
/Triggers
TriggerEngine
TriggerPacket
CooldownManager
/Intelligence
ReasoningEngine
ModelManager
PromptBuilder
ProposalGenerator
/Actions
ActionRouter
ActionProtocol
SummarizeAction
ExplainAction
RewriteAction
CompareTabsAction
DebugErrorAction
ScreenAnalyzeAction
## /UI
SuggestionCard
AssistantPanel
ResultView
SettingsView
PermissionsView
/Storage
LocalStore
PreferencesStore
HistoryStore
/Permissions
PermissionManager
PermissionState


## KEY DATA FLOW
- macOS source detects event
- Source Manager normalizes event
- Context Builder updates context model
- Trigger System checks whether it matters
- Intelligence Layer decides whether to propose action
- UI displays suggestion
- User accepts or dismisses
- Action Router executes accepted action
- Action Module generates result
- UI displays result
## ARCHITECTURAL RULES
- Sources collect only
Sources should never decide what to do.
- Context Builder structures only
It converts events into context, but does not generate UI suggestions.
- Trigger System filters only
It decides whether deeper reasoning is worth it.
- Intelligence Layer reasons
It decides what question or action should be proposed.
- Action Router routes only
It sends accepted actions to the correct module.
- Action Modules execute
Each module handles one ability.
- UI displays only
UI should not contain business logic.
- Permissions are checked everywhere
Every source and action must respect the permission layer.
## SCALABILITY DESIGN
The architecture should support adding new sources and actions without rewriting the
system.
To add a new source:
● create new source module
● define output event
● register with Source Manager
To add a new action:
● create new action module
● define input requirements
● define permission requirements
● register with Action Router


To add a new UI surface:
● connect it to existing system state
● avoid duplicating logic
## TECH STACK DIRECTION
Since the product is Mac-first and should feel native, the preferred direction is:
● Swift / SwiftUI for native UI
● AppKit where needed for menu bar and overlay behavior
● macOS APIs for system access
● local model execution through a separate model manager
● local storage for settings and lightweight history
Possible future additions:
● browser extension for richer browser context
● VS Code extension for coding context
● local model server if needed
● optional cross-platform rewrite later
## CORE ARCHITECTURE PRINCIPLE
The assistant should be built like a system, not a single app screen.
Each layer should do one job.
Each source should be replaceable.
Each action should be modular.
The UI should be separate from logic.
AI should be called through a controlled intelligence layer.
This structure prevents the project from collapsing as more features are added.
## MVP SCOPE — MACOS CONTEXT-AWARE ASSISTANT
The MVP defines the smallest version of the product that is:
● usable
● testable
● valuable
● not overwhelming to build
## Core Principle
The MVP should prove that the assistant can:
● understand context
● propose useful actions
● feel reactive
● not be annoying


It should NOT try to solve every use case or include every feature.
The goal is to validate:
“Does this actually help me while I use my Mac?”
## MVP GOALS
The MVP must demonstrate:
● context awareness from macOS signals
● reactive suggestion generation
● at least a few genuinely useful actions
● clean, non-intrusive UX
● stable architecture that can grow
## MVP ENVIRONMENT
The MVP will be:
● macOS only
● local-first
● native UI (SwiftUI/AppKit)
● no cloud dependency
● minimal permissions required
## MVP PERMISSIONS
## Required:
● Accessibility (for selected text + window context)
● Clipboard access (for copied content)
Optional (NOT required for MVP):
## ● Screen Recording
● Advanced app integrations
● File system access
## MVP INPUT SOURCES
Only include:
● active app detection
● window title (when available)
● clipboard changes
● selected text
● keyboard shortcut
● menu bar interaction
Do NOT include:


● continuous screen capture
● deep browser integrations
● complex app plugins
## MVP CONTEXT CAPABILITIES
The assistant should be able to detect:
● user selected text
● user copied content
● basic app context (browser vs editor vs notes)
● simple patterns (multiple tabs, repeated switching optional)
It does NOT need:
● perfect activity classification
● full workflow understanding
● advanced pattern detection
## MVP ACTION SET
Limit to 4–6 core actions.
These should be the most universally useful.
Required MVP actions:
## 1. Summarize Text
## Input:
selected text or clipboard text
## Output:
short summary
## 2. Explain Text
## Input:
selected text or clipboard content
## Output:
clear explanation
## 3. Rewrite Text
## Input:
selected text
## Output:
cleaned or improved version


- Compare Items (Basic)
## Input:
selected text OR inferred simple context
## Output:
simple comparison or differences
Optional (if easy):
## 5. Explain Error
## Input:
clipboard content
## Output:
error explanation
Do NOT include:
● complex multi-step workflows
● file system automation
● tab organization (unless trivial)
● screen analysis
## MVP TRIGGERS
Only use strong triggers:
● selected text detected
● clipboard changed
● keyboard shortcut used
● menu bar activation
Optional simple trigger:
● multiple similar tab titles (basic implementation only)
Do NOT include:
● complex behavioral triggers
● long session detection
● advanced pattern detection
## MVP INTELLIGENCE
## Use:
● lightweight rules for triggers
● one local AI model for reasoning + execution
Do NOT include:


● multiple model layers
● advanced classifiers
● vision models
● continuous AI inference
Model usage:
● only triggered when user interacts or strong signal exists
● no background AI processing
## MVP OUTPUT UX
Include only:
## 1. Menu Bar App
● open assistant
● basic settings
● pause toggle
## 2. Suggestion Card
● small popup
● triggered by selected text or clipboard
● shows one action
● dismissible
## 3. Assistant Panel
● opens via shortcut or click
● shows 2–4 actions
● displays results
Do NOT include:
● complex layouts
● history view
● advanced UI customization
## MVP PERFORMANCE TARGET
The assistant should:
● use minimal CPU when idle
● not continuously call AI
● respond quickly when triggered
● not slow down the system
## MVP DATA STORAGE
Store only:
● user preferences
● permission states
● cooldown timers


Do NOT store:
● clipboard history
● screenshots
● sensitive content
## MVP DEVELOPMENT PRIORITY
Build in this order:
- Menu bar app + basic UI
- Keyboard shortcut + assistant panel
- Clipboard + selected text detection
- Context builder (minimal version)
- Trigger system (basic rules)
- Intelligence layer (single model call)
- Core actions (summarize, explain, rewrite)
- Suggestion card UI
- Basic cooldown system
## MVP SUCCESS CRITERIA
The MVP is successful if:
● it runs without noticeable performance impact
● it provides useful suggestions at least some of the time
● it does not feel intrusive
● it is stable and does not break easily
● you personally find yourself using it
## MVP FAILURE CONDITIONS
The MVP fails if:
● it feels annoying or spammy
● suggestions are irrelevant
● it is too slow
● it crashes or behaves unpredictably
● it becomes too complex to extend
## CORE MVP PRINCIPLE
The MVP should feel like a simple, useful assistant—not a complete system.
It should prove that:
context + timing + useful actions = real value
Once this is validated, additional capabilities can be layered on cleanly without rewriting the
system.


## SCALABILITY PLAN — MACOS CONTEXT-AWARE ASSISTANT
The scalability plan defines how the assistant can grow without becoming messy, slow, or
difficult to maintain.
## Core Principle
The system should scale by adding modules, not by making the core bigger.
The assistant should be designed so new sources, actions, models, and UI surfaces can be
added without rewriting the entire project.
## WHAT SCALABILITY MEANS FOR THIS PROJECT
Scalability does not initially mean millions of users.
For this project, scalability means:
● the codebase stays organized as features are added
● new actions can be added easily
● new input sources can be connected cleanly
● performance remains stable
● privacy rules stay enforceable
● AI usage remains controlled
● future platform expansion is possible
## SCALING SOURCES
Input sources should be modular.
To add a new source:
- Create a new source module
- Define what it observes
- Define required permissions
- Define its output event format
- Register it with the Source Manager
Examples of future sources:
● browser extension
● VS Code extension
● Finder file context
● Calendar integration
● Notes integration
● screen capture source
● OCR source
The core system should not need to know how each source works internally.
## SCALING ACTIONS


Actions should also be modular.
To add a new action:
- Create a new action module
- Define required input
- Define required permissions
- Define processing logic
- Define output format
- Register it with the Action Router
Examples of future actions:
● summarize PDF
● organize Downloads folder
● explain screenshot
● compare browser tabs
● draft email
● create checklist
● group related files
● prepare meeting notes
The Action Router should only route actions. It should not contain action-specific logic.
## SCALING INTELLIGENCE
The intelligence layer should support multiple levels of reasoning.
Initial version:
● rules for triggers
● one local model for reasoning and execution
Future version:
● lightweight classifier for context detection
● medium local model for proposals
● stronger model for action execution
● vision model for screen analysis
● optional cloud model only with explicit user opt-in
The system should choose the cheapest useful intelligence layer first.
Priority order:
- rules / heuristics
- small classifier
- local LLM
- local vision model
- optional cloud model


Heavy models should never run constantly.
## SCALING PERFORMANCE
Performance must be protected as features grow.
## Rules:
● event-driven updates instead of constant polling
● cooldowns for repeated triggers
● cache recent context
● limit context packet size
● avoid continuous screen capture
● load heavy models only when needed
● unload or pause unused models
● process screenshots only on demand unless advanced mode is enabled
The always-on layer should remain lightweight even if advanced features are added.
## SCALING PRIVACY
Privacy rules must scale with features.
Every new source or action must declare:
● what data it accesses
● what permission it needs
● whether data is stored
● whether AI is used
● whether anything leaves the device
No module should bypass the permission system.
Future advanced features should remain opt-in.
## Examples:
● screen capture: opt-in
● file access: opt-in
● browser content access: opt-in
● cloud model use: opt-in
## SCALING UI
The UI should remain simple even as features grow.
The assistant should never show every possible action.
## Rules:
● show only the most relevant 2–5 actions


● hide advanced actions behind the assistant panel
● keep suggestion cards minimal
● avoid clutter
● group actions by context
● allow users to disable actions they do not want
The assistant should feel smarter as it grows, not busier.
## SCALING STORAGE
Storage should stay local and lightweight.
## Store:
● user preferences
● permission states
● action settings
● cooldowns
● recent suggestion history
● cached summaries if useful
Avoid storing:
● raw clipboard history
● raw screenshots
● full screen recordings
● unnecessary private content
● massive logs
If long-term memory is added later, it should store derived preferences and summaries, not
raw activity.
## SCALING CODEBASE STRUCTURE
The codebase should use clear module boundaries.
Core folders should remain separated:
● SystemSources
● SourceManager
## ● Context
## ● Triggers
## ● Intelligence
## ● Actions
## ● UI
## ● Storage
## ● Permissions
Do not allow:


● UI logic inside system sources
● action logic inside the router
● raw macOS API calls inside action modules
● model calls scattered across the project
● permission checks duplicated randomly
All AI calls should go through the Model Manager.
All permissions should go through the Permission Manager.
All actions should go through the Action Router.
All context should go through the Context Builder.
## SCALING DEVELOPMENT
Development should happen in phases.
Phase 1 — MVP
● menu bar app
● assistant panel
● clipboard and selected text
● basic context model
● summarize, explain, rewrite
## Phase 2 — Better Context
● improved app detection
● browser tab awareness
● better trigger reasoning
● action ranking
● suggestion history
## Phase 3 — Screen Awareness
● manual screen capture
## ● OCR
● screen explanation
● visual debugging
## Phase 4 — App Integrations
● browser extension
● VS Code extension
● Finder/file context
● Notes/writing context
## Phase 5 — Advanced Agent Behavior
● multi-step actions
● memory/preferences
● deeper workflow understanding


● advanced model routing
## Phase 6 — Portability
● evaluate Windows support
● evaluate browser-only version
● separate platform-specific code from core logic
## SCALING TO OTHER PLATFORMS
The first version is macOS-first.
To make future porting possible:
● keep macOS APIs isolated in the SystemSources layer
● keep core logic platform-independent where possible
● avoid hardcoding macOS assumptions outside system modules
● use generic event and context formats
● design actions around abstract inputs, not platform APIs
Future platform targets may include:
● Windows desktop app
● browser extension
● iOS companion app
● cross-platform desktop shell
## SCALING USER CONTROL
As the assistant becomes more powerful, user control becomes more important.
Users should be able to:
● disable specific sources
● disable specific actions
● adjust suggestion frequency
● pause the assistant
● choose local vs optional cloud models
● control screen capture mode
● clear stored data
The more capability the assistant gains, the more control it must provide.
## SCALING FAILURE PREVENTION
As features grow, the project may fail if:
● everything becomes connected to everything
● AI calls are added randomly
● screen capture becomes overused


● suggestions become too frequent
● permissions become unclear
● UI becomes crowded
● performance degrades
The solution is to keep strict boundaries.
Every new feature must answer:
● What source does it use?
● What context does it need?
● What action does it provide?
● What permission does it require?
● What model does it call?
● What output does it show?
## CORE SCALABILITY PRINCIPLE
The assistant should scale by becoming more modular, not more complicated.
New sources should plug into the Source Manager.
New context should flow through the Context Builder.
New reasoning should go through the Intelligence Layer.
New actions should register with the Action Router.
New UI should display existing system state.
This keeps the product expandable without allowing the codebase to collapse.
## VALIDATION PLAN — MACOS CONTEXT-AWARE ASSISTANT
The validation plan defines how to test whether the assistant is actually useful before
building too much.
## Core Principle
The product should be validated through real usage, not just whether the software
technically works.
The main question is:
“Does this assistant make using a Mac feel easier, faster, or more intelligent without
becoming annoying?”
## VALIDATION GOALS
The validation process should test:
● whether suggestions are useful
● whether suggestions appear at the right time
● whether the assistant feels helpful rather than intrusive
● whether performance remains lightweight


● whether users trust the privacy model
● whether users would keep the assistant installed
## WHAT TO VALIDATE FIRST
## 1. Usefulness
Do users accept suggestions?
Do actions save time?
Do users return to the assistant voluntarily?
## 2. Timing
Do suggestions appear when they are actually relevant?
Do they appear too early, too late, or too often?
## 3. Annoyance
Do users dismiss suggestions frequently?
Do they feel interrupted?
Do they disable the assistant?
## 4. Performance
Does the assistant noticeably slow down the Mac?
Does CPU or memory usage stay low while idle?
## 5. Trust
Do users understand what the assistant can access?
Are they comfortable granting permissions?
## MVP VALIDATION TEST
Test the MVP with yourself first.
Test period:
● 5–7 days
Daily questions:
● Did I use it today?
● Did it surface anything useful?
● Did I accept any suggestions?
● Did I dismiss anything because it was annoying?
● Did it slow down my Mac?
● Did I manually open it?
## EARLY USER TESTING
After personal testing, test with 3–5 trusted users.
Ideal testers:
● Mac users
● students
● developers
● people who write, browse, research, or multitask often


Do not start with a large public launch.
## TESTING METHOD
Give users the app with minimal explanation.
Tell them:
“This is a Mac assistant that notices context and offers useful actions. Use your computer
normally.”
Then observe:
● what they click
● what they ignore
● what confuses them
● what they disable
● what they ask for
Do not over-explain the product. If it needs too much explanation, the UX is not clear
enough.
## METRICS TO TRACK LOCALLY
The MVP should track lightweight local metrics.
Useful metrics:
● number of suggestions shown
● number of suggestions accepted
● number of suggestions dismissed
● number of times assistant panel opened manually
● most used actions
● least used actions
● average time between suggestions
● action completion count
● crash/error count
Avoid tracking:
● raw clipboard content
● raw selected text
● screenshots
● sensitive user content
Suggested success metrics:
● suggestion acceptance rate above 20–30%
● low disable/pause rate
● users manually open assistant at least occasionally


● no noticeable idle performance impact
● at least one action becomes repeatedly useful
## QUALITATIVE FEEDBACK QUESTIONS
Ask testers:
● What did the assistant do that was actually useful?
● What felt annoying?
● What felt creepy or uncomfortable?
● Did you understand why it suggested something?
● Did you trust what it could see?
● Which action would you use again?
● What did you expect it to do that it did not?
● Would you keep this installed for a week?
## VALIDATION SCENARIOS
Test common workflows:
## Writing:
● select paragraph
● rewrite
● summarize
● clean up notes
## Research:
● open multiple related tabs
● ask for comparison
● extract key points
## Coding:
● copy error
● explain error
● suggest fix
General Mac use:
● manually open assistant
● ask it to work with current context
● dismiss suggestions
● pause/resume assistant
## PRIVACY VALIDATION
Users should be able to answer:


● what the app can see
● what permissions are enabled
● whether screen capture is on
● whether data leaves the device
If users cannot explain this after onboarding, the privacy UX needs improvement.
## PERFORMANCE VALIDATION
## Track:
● idle CPU usage
● idle memory usage
● model load time
● action response time
● battery impact
● crash frequency
## Target:
● idle usage should feel unnoticeable
● AI should only run after meaningful triggers or user action
● no constant high CPU or memory usage
## ANNOYANCE TEST
The assistant should be tested for over-triggering.
Red flags:
● user dismisses most suggestions
● user says “why is this showing up?”
● same suggestion appears repeatedly
● suggestions interrupt active typing
● assistant appears without clear reason
If this happens:
● increase confidence threshold
● increase cooldowns
● reduce trigger types
● improve context detection
## ITERATION LOOP
After each test cycle:
- Review accepted suggestions
- Review dismissed suggestions
- Remove low-value triggers


- Improve wording
- Adjust cooldowns
- Improve action quality
## 7. Retest
Do not add more features until the current suggestions are useful.
## VALIDATION PHASES
## Phase 1 — Personal Dogfooding
Use it yourself daily. Fix obvious issues.
## Phase 2 — Small Trusted Test
Give it to 3–5 users. Focus on usefulness, annoyance, and trust.
## Phase 3 — Narrow Beta
Test with 10–20 Mac users. Focus on stability and repeated use.
## Phase 4 — Public Demo / Waitlist
Only after repeated use is proven.
## WHAT COUNTS AS SUCCESS
The product is worth continuing if:
● users keep it installed
● users accept suggestions regularly
● users manually call on it
● at least 2–3 actions are repeatedly useful
● users say it feels helpful rather than annoying
● performance impact is minimal
● privacy concerns are manageable
## WHAT COUNTS AS FAILURE
The product needs major rethinking if:
● users ignore almost everything
● suggestions feel random
● users disable it quickly
● performance is noticeable
● users do not trust permissions
● users cannot explain why they would use it
## CORE VALIDATION PRINCIPLE
Do not validate the idea by asking:
“Would you use this?”


Validate by watching:
“Do people actually keep it running, accept its suggestions, and call on it when they need
help?”
The assistant is only valuable if it becomes something users naturally leave on.

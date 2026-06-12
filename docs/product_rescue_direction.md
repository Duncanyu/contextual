# Product Rescue Direction — June 2026

This document is the product truth for Contextual after the Phase 51 rescue
sprint. It exists because the project drifted toward "generic ambient AI
assistant" — a lane Apple owns at the OS level — and because the core
usefulness layer (content acquisition) was overclaiming what it could read.

## What Contextual is

**A local-first workflow copilot for power users working across
browser / docs / code / files.**

It specializes in:

- Browser and document research (rental/listing comparison, paper reading,
  multi-tab synthesis)
- Document summarization and review (PDF, DOCX, plain text, web articles,
  Google Docs via explicit capture)
- Code/log debugging assistance (diagnose visible errors, explain context)
- Action item / checklist / draft / artifact extraction from real content
- Workspace mechanics: side-by-side layout, workspace restore, app pairs
- Local memory of recurring workflows (work pairs, playlists, workspaces)
- Explicit, reviewable, bounded actions — every action shows a real result,
  a real effect, or a real explanation

## What Contextual is not

- Not a Siri clone. No voice, no general chat, no "ask me anything."
- Not an agent. It never takes multi-step autonomous actions.
- Not a toast factory. No fake "completed" states, no debug-button drawer.
- Not an AX wrapper pretending visible text is the full document.
- Not a clipboard macro toolkit.

## What Apple/Siri will do better — concede it

Apple has OS-level advantages we cannot beat and should not chase:

- **App Intents**: first-party deep actions inside any adopting app
- **On-screen awareness**: private, OS-level screen understanding
- **Personal context**: mail, messages, calendar, photos at the OS layer
- **System integration**: Siri invocation, hardware, private cloud compute

Anything that amounts to "system-wide ambient assistant that knows
everything you do" is Apple's lane. Pretending AX/OCR gives us full context
is how we lose — it produces weak summaries that feel fake.

## Where Contextual can still win

1. **Depth over breadth in the work loop.** Apple optimizes for everyone;
   Contextual optimizes for someone with 14 tabs, a PDF lease, a code editor
   and a deadline. Workflow-level intelligence (compare these listings,
   diff these clauses, extract the action items across sources) is not what
   App Intents delivers.
2. **Source-native acquisition with consent.** We can do honest, explicit,
   user-approved full-content capture (file APIs, PDFKit, export routes,
   select-all capture, a browser extension bridge) and say exactly what we
   read. Apple's on-screen awareness is opaque; ours is auditable.
3. **Transparency as a feature.** Every result card carries source + scope
   ("AX · visible content", "Clipboard · full document"). Logs show every
   route attempt. Power users trust what they can verify.
4. **Local-first memory the user can inspect.** Work pairs, playlists,
   workspace patterns — small, legible, deletable.

## Context acquisition strategy

The single most important rule after this sprint:

> **Scope is truth.** Every acquisition declares what it actually covers
> (`full_page`, `full_document`, `main_article`, `visible_viewport`,
> `selected_text`, `partial_visible_text`, `metadata_only`, `failed`) and
> nothing downstream may claim more than the declared scope.

Hard constraints (enforced by `ContentScopeModel` + `ContentScopeGate`):

- AX visible text can NEVER satisfy `full_page` / `full_document`
- OCR can NEVER satisfy `full_page` / `full_document`
- Metadata can NEVER feed a cognitive action
- Google Docs AX editor tiles are `partial_visible_text`, period
- URL/title/tabs can NEVER produce a "page summary"

Route priority (highest fidelity first):

1. Native file/document APIs (PDFKit, plain text, DOCX, RTF)
2. Browser DOM / extension / protocol bridge *(architecture in place;
   extension bridge is the next real route to build)*
3. App-specific routes (Google Docs export/capture; Gmail thread)
4. User-approved select-all/copy capture with clipboard restore
   *(today's only honest full-document route for web editors)*
5. AX visible text — visible scope only
6. OCR/vision — visible scope only, expensive, explicit
7. Metadata — never content, only context

When full scope is unavailable, the product response is a **setup/capture
card** ("Capture full document", "Enable page access"), not a fake summary.

## Action strategy

- Titles are scope-truth: "Summarize visible content" until the system can
  *prove* "Summarize this page/document".
- The panel is ranked, not dumped: Suggested now → Understand this →
  Act on this → Workspace → Utilities. Utilities never take a top slot.
- Friction actions split manual vs proactive: proactive layout suggestions
  require verified switching history; manual clicks always work on the best
  live targets or show a blocked card explaining why.
- Music is a preference, not a surprise: only in stable work contexts, only
  named playlists or plain resume, learned playlists only at high confidence,
  suppressed when anything is already playing.
- No silent failure anywhere: every click ends in a result card, a capture
  card, a blocked card, or a failure card.

## Dogfood success criteria

The sprint (and any future sprint) is only "done" when the dogfood matrix
passes — not when unit tests pass. The matrix cases:

1. Firefox normal webpage → visible-scope summary with honest title/label
2. Firefox Google Docs → partial AX never claims page/document; capture
   card offers user-approved full capture
3. Rental/listing page → metadata never summarized; capture path offered
4. Gmail → selection summarized as selection
5. Preview PDF → real full-document summary (PDFKit)
6. TextEdit document → full-document summary (file-backed)
7. Xcode/code/log → visible-scope diagnosis
8. Music → no random playlist, suppressed when playing, Spotify only if installed
9. Manual side-by-side → works on click with live targets
10. Proactive side-by-side → only with verified pair; blocked card otherwise

Run it: `CONTEXTUAL_RUN_DOGFOOD_MATRIX=1` or the "Run dogfood matrix"
button in the panel debug section. Logs: `[DogfoodMatrix]` /
`[DogfoodMatrixSummary]`.

## What to build next (in order of product leverage)

1. **Browser extension bridge** (`browser_dom_firefox` / `browser_dom_chromium`):
   content script extracts title, headings, article/main text, full DOM text
   on user approval; native-messaging or localhost loopback to the app.
   This unlocks honest `full_page` for the browser — the product's center.
2. **Google Docs export route** (Drive API / export endpoint when the user
   connects an account) so full-document no longer requires select-all capture.
3. **Readability extraction** (`html_readability` / `main_article`) over
   bridge-acquired DOM.
4. **Comparison artifacts**: side-by-side listing/document comparison cards —
   the first true "workflow copilot" deliverable beyond summarize.

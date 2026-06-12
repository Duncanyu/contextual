# Phase 63 Unified Suggestion Surface Audit

## 1. Liquid actions
- Source file: `LiquidActionRouter.swift` / `LiquidActionQuality.swift`
- Model type: `LiquidActionSelection` / `Phase35ActionProposal`
- UI component: `AssistantPanelView` (via `VisibleGeneratedActionsSection` or `SuggestionCard`)
- Can float: Yes (via `LiquidSurfaceBridge`)
- Can appear in panel: Yes
- Click path: `invokeGeneratedExecutionProposal`
- Result path: `GeneratedExecutionResultPresenter`
- Uses contracts/worthiness: Yes (`ProposalWorthiness`)
- Bypasses unified scoring: Yes, has its own `LiquidSurfaceBridge` logic for floating
- Debug-only: No

## 2. Composed plans
- Source file: `ComposedActionPlanner.swift`
- Model type: `ComposedPlan`
- UI component: Same as Liquid (often surfaced as a generated proposal)
- Can float: Yes
- Can appear in panel: Yes
- Click path: `ComposedPlanExecutor`
- Result path: `GeneratedExecutionResultPresenter`
- Uses contracts/worthiness: Yes
- Bypasses unified scoring: Yes
- Debug-only: No

## 3. Cheap portfolio actions
- Source file: `CheapAlwaysOnPortfolio.swift`
- Model type: Legacy `ActionProtocol` / `ActionProposal`
- UI component: `AssistantPanelView` static actions section
- Can float: Yes (if ambient Jarvis selected it)
- Can appear in panel: Yes
- Click path: `CapabilityExecutor`
- Result path: Text-based result
- Uses contracts/worthiness: Mixed (relies on usefulness registry)
- Bypasses unified scoring: Sometimes (relies on portfolio merge)
- Debug-only: No

## 4. Music/media actions
- Source file: `CheapAlwaysOnPortfolio.swift` / `MediaAwarenessModel.swift`
- Model type: Portfolio action (`play_focus_media`)
- UI component: Static panel action or `AmbientFloatingSuggestion`
- Can float: Yes
- Can appear in panel: Yes
- Click path: Native capability
- Result path: Silent or minor text update
- Uses contracts/worthiness: No (uses simple domain rules)
- Bypasses unified scoring: Yes
- Debug-only: No

## 5. Friction/window actions
- Source file: `FrictionEngine.swift`
- Model type: `ActionProtocol`
- UI component: Panel static action
- Can float: Rarely
- Can appear in panel: Yes
- Click path: Native capability
- Result path: Direct window manipulation
- Uses contracts/worthiness: No
- Bypasses unified scoring: Yes
- Debug-only: No

## 6. Setup/acquisition actions
- Source file: `AcquisitionPlanner.swift` / `BrowserBridge`
- Model type: `ActionProtocol`
- UI component: Panel static action
- Can float: No
- Can appear in panel: Yes
- Click path: Direct native setup
- Result path: Silent
- Uses contracts/worthiness: No
- Bypasses unified scoring: Yes
- Debug-only: No

## 7. Memory/workspace actions
- Source file: `WorkspaceMemoryEngine.swift` / `BrowserTabMemory`
- Model type: `ActionProtocol`
- UI component: Panel static action
- Can float: No
- Can appear in panel: Yes
- Click path: Direct native
- Result path: Silent
- Uses contracts/worthiness: No
- Bypasses unified scoring: Yes
- Debug-only: No

## 8. Static/UCR dogfood actions
- Source file: `UCRDogfoodTestAction.swift`
- Model type: `ActionProtocol`
- UI component: Always visible in Panel when UCR dogfood is on
- Can float: No
- Can appear in panel: Yes
- Click path: Direct action
- Result path: Text or popup
- Uses contracts/worthiness: No
- Bypasses unified scoring: Yes
- Debug-only: Yes (supposed to be)

## 9. Inline assistance
- Source file: `InlineAssistanceEngine.swift`
- Model type: Inline state
- UI component: `InlineAssistanceDebugView`
- Can float: No
- Can appear in panel: Yes (Debug only)
- Click path: None
- Result path: None
- Uses contracts/worthiness: No
- Bypasses unified scoring: Yes
- Debug-only: Yes

## 10. VisibleGeneratedAction
- Source file: `VisibleGeneratedActionPanelAdapter.swift`
- Model type: `GeneratedExecutionProposalPanelItem`
- UI component: `VisibleGeneratedActionsSection`
- Can float: No
- Can appear in panel: Yes
- Click path: Generated execution
- Result path: Result card
- Uses contracts/worthiness: Yes
- Bypasses unified scoring: N/A (panel only)
- Debug-only: No

## 11. DynamicActionUX
- Source file: `AssistantPanelView.swift`
- Model type: `DynamicActionDisplaySummary`
- UI component: `DynamicActionPreviewView`
- Can float: No
- Can appear in panel: Yes (Debug only)
- Click path: Debug execute
- Result path: Debug
- Uses contracts/worthiness: No
- Bypasses unified scoring: Yes
- Debug-only: Yes

## 12. RichAssistanceRank
- Source file: `PanelRanker.swift`
- Model type: `PanelRankingInput`
- UI component: `AssistantPanelView` sections
- Can float: No
- Can appear in panel: Yes
- Click path: Static action execute
- Result path: Text
- Uses contracts/worthiness: No
- Bypasses unified scoring: N/A
- Debug-only: No

## 13. Ambient Jarvis suggestions
- Source file: `AmbientJarvisSuggestionSelfTest.swift` / `Phase35ContextLayer.swift`
- Model type: `ActionProposal`
- UI component: `SuggestionCard`
- Can float: Yes
- Can appear in panel: No (usually)
- Click path: Depends on underlying action
- Result path: Text or execution card
- Uses contracts/worthiness: No (uses older ambient rules)
- Bypasses unified scoring: Yes
- Debug-only: No

## 14. Result-card followups
- Source file: `GeneratedExecutionResultPresenter.swift`
- Model type: `FollowupAction`
- UI component: Followup buttons on result card
- Can float: Yes (if result card is floating)
- Can appear in panel: Yes (if result card is in panel)
- Click path: Generated execution
- Result path: New result card
- Uses contracts/worthiness: No (uses specific followup logic)
- Bypasses unified scoring: Yes
- Debug-only: No

## 15. Debug-only panels
- Source file: `AssistantPanelView.swift`
- Model type: Various
- UI component: `DisclosureGroup` at bottom of panel
- Can float: No
- Can appear in panel: Yes
- Click path: None
- Result path: None
- Uses contracts/worthiness: No
- Bypasses unified scoring: Yes
- Debug-only: Yes

---

### Analysis of Fragmentation

Currently, `play_focus_media` (a music action) behaves like a completely different kind of suggestion than `extract_key_claims` (a liquid action) because they originate from different engines (`CheapAlwaysOnPortfolio` vs `LiquidActionRouter`), pass through different policy filters (`SurfacePolicy` vs `LiquidSurfaceBridge`), and are rendered by completely separate sections in the `AssistantPanelView` (`panelActionRow` in static sections vs `generatedProposalCard` in `VisibleGeneratedActionsSection`).

There is no unified "Candidate" model. When the system wants to decide whether to show a floating popup, it checks `AmbientJarvis` rules, then `LiquidSurfaceBridge` rules separately. If it decides to show a panel, it runs `PanelRanker` for static actions, and a completely separate `VisibleGeneratedActionsSection` for dynamic actions. Debug items also just inject themselves anywhere.

To fix this, we need `UnifiedSuggestion` to represent ALL of these before any UI is rendered, and a `UnifiedSurfaceArbiter` to decide where they go.

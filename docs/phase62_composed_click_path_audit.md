# Phase 62 Composed Click Path Audit

## Current Runtime Path

[ComposedClickPathAudit] scope=phase62 path="composed plan generated -> panel candidate -> user click -> executor"

1. `DeterministicPanelActionPlanner.evaluate` builds `WorkflowSignals`, classifies the current browser/app context, and asks `ComposedActionPlanner.plansFor(...)` for composed plans.
2. Valid plans are currently bridged into the panel as `PortfolioCandidate` records whose `capabilityId` is shaped like `composed_plan:<plan_id>`.
3. `AppDelegate.publishDeterministicPanelActions` converts each valid candidate into a `DeterministicCapabilityPanelAction` and publishes it through `AppState.availableActions`.
4. `AssistantPanelView` and the floating suggestion path render `ActionProtocol` rows/buttons. The user click calls `AppState.invokeAction(id:sourceSurface:)`.
5. `AppState.invokeAction` records `PendingActionClickContext`, then the delegate resolves the stored action and calls `DeterministicCapabilityPanelAction.execute(...)`.
6. Before this audit fix, `DeterministicCapabilityPanelAction.execute(...)` treated every row as a legacy registry-backed capability and looked up `CognitiveCapabilityRegistry.shared.get(seed.capabilityId)`.

## Findings

[ComposedClickPathFinding] severity=high id=legacy_executor_assumption file=Actions/ActionRouter.swift finding="composed_plan rows entered DeterministicCapabilityPanelAction but execution looked up CognitiveCapabilityRegistry, so ComposedPlanExecutor was not the first-class click target"

[ComposedClickPathFinding] severity=high id=identity_loss file=Intelligence/Phase35ContextLayer.swift finding="the panel row carried only capabilityId=composed_plan:<id>; plan title, mode, source scope, expected output, steps, followups, safety review, and capture approval were not preserved as a typed UI identity"

[ComposedClickPathFinding] severity=high id=followup_gap file=App/AppState.swift finding="result card followups only routed ontology/static actions; composed followups had no distinct click path back into ComposedPlanExecutor"

[ComposedClickPathFinding] severity=medium id=result_card_gap file=Intelligence/ContextExecutionResult.swift finding="composed executor logs could produce rendered text in tests, but real click presentation still depended on legacy capability result-card assumptions"

## Required Fix Shape

- Preserve a first-class visible action identity for composed plans before the candidate reaches UI.
- Let `DeterministicCapabilityPanelAction` recognize composed plan identity and dispatch directly to `ComposedPlanExecutor`.
- Render composed outputs through the existing result-card surface with user-visible titles and followups.
- Route composed followup buttons through a composed followup dispatcher, not the legacy ontology registry.
- Keep legacy capability actions on the existing `CognitiveCapabilityRegistry` path.

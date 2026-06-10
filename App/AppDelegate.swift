import AppKit

extension Notification.Name {
	static let contextualManualTrigger = Notification.Name("com.contextual.manualTrigger")
	static let contextualOpenTaskPanel = Notification.Name("com.contextual.openTaskPanel")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	/// TEMPORARY: Set to `true` to run the task-inference bakeoff harness on launch and exit.
	/// Keep `false` for normal app usage.
	private static let runTaskInferenceBakeoffOnLaunch = false
	private let appState = AppState()
	private var menuBarController: MenuBarController?
	private var floatingSuggestionController: FloatingSuggestionWindowController?
	private var floatingResultCardController: FloatingResultCardWindowController?
	private var sourceManager: SourceManager?
	private let contextBuilder = ContextBuilder()
	private let triggerEngine = TriggerEngine()
	private let actionRouter = ActionRouter()
	private var manualTriggerObserver: NSObjectProtocol?
	private var canonicalContextObserver: NSObjectProtocol?
	private var openTaskPanelObserver: NSObjectProtocol?

	private var lastFinishedActionKey: String?
	private var lastFinishedAt: Date?

	/// Phase 43 — Per-capability timestamp for cognitive floating cooldown (90s window).
	private var lastCognitiveFloatShownAt: [String: Date] = [:]

	private var lastReasonedActions: [any ActionProtocol] = []
	private var lastReasonedActionsAt: Date?
	private var lastReasonedTriggerType: TriggerType?
	private let availableActionsCacheTTLSeconds: TimeInterval = 300

	private var lastReasonedProposal: ActionProposal?
	private var lastReasonedProposalKey: String?

	private var lastContextLogSignature: String?
	private var lastPreserveLogAt: Date?
	private var lastManualInvocationAt: Date?
	private var didLogManualGuard: Bool = false

	/// Dedupes identical `[TES]` suppression/allow logs during rapid context polling.
	private var lastTESLogSignature: String?
	private var lastTESLogAt: Date?

	private var lastProposalGateLogSignature: String?
	private var lastProposalGateLogAt: Date?
	private var lastActionRelevanceLogSignature: String?
	private var lastActionRelevanceLogAt: Date?
	private var lastProposalRankingLogSignature: String?
	private var lastProposalRankingLogAt: Date?
	private var lastSuggestionStrengthLogSignature: String?
	private var lastSuggestionStrengthLogAt: Date?

	/// Invalidates in-flight async `updateAvailableActions` when newer context arrives (T12.6).
	private var contextPipelineGeneration: UInt64 = 0
	private let intelligenceProposalSelector = IntelligenceProposalSelector()

	private var lastPipelineActiveAppKey: String?
	private var proposalTimingDeferredWorkItem: DispatchWorkItem?
	private var lastProposalTimingSignature: String?
	private var lastProposalTimingLogAt: Date?

	/// Holds the active generated execution runtime so cancel can reach it (T18.4).
	private var activeGeneratedExecutionRuntime: GeneratedExecutionRuntime?

	private var twoStageWarmupComplete: Bool = false
	private var deferredWarmupTrigger: (packet: TriggerPacket, context: ContextModel, generation: UInt64)?

	// Phase 4S — When fast visibility detects a strong entity/title but cannot
	// generate a real action intent (router/planner not warmed), store a pending
	// retry request so proposals recover once warmup completes.
	struct ActionIntentPendingRequest {
		let packet: TriggerPacket
		let context: ContextModel
		let snapshot: CanonicalGeneratedExecutionContextSnapshot
		let situational: SituationalContextSnapshot
		let generation: UInt64
		let fingerprint: String
		let title: String
		let classification: FastVisibilityTitleClassification
		let storedAt: Date
		let expiresAt: Date
	}
	private var pendingActionIntentRequest: ActionIntentPendingRequest?

	/// T18.6A — Tracks the previous context fingerprint components so we can detect meaningful
	/// context changes (page nav, app switch, workflow change) and log them.
	private struct ChimeInContextSnapshot: Equatable {
		let bundle: String      // bundle ID or app name slug
		let titlePrefix: String // first 40 chars of window title
		let workflow: String    // WorkflowType rawValue
		let hasOCR: Bool
		let hasSelectedText: Bool
	}
	private var lastChimeInContext: ChimeInContextSnapshot?

	func applicationDidFinishLaunching(_ notification: Notification) {
		ValidationConfiguration.logStatus()
		AmbientMVPMode.logStatus()
		UsefulActionOpportunityRegistry.logRegistry()
		// Phase 18C — hard proof that the binary actually contains the new
		// engine + mode types. If any of these symbols were missing, this file
		// would not have compiled in the first place.
		_ = ContextExecutionEngine.self
		_ = AmbientMVPMode.self
		_ = ValidationConfiguration.self
		print("[Phase18C] compiled=yes context_execution_engine=yes ambient_mvp_mode=yes")
		DogfoodChecklist.printIfEnabled()
		
		menuBarController = MenuBarController(appState: appState)
		floatingSuggestionController = FloatingSuggestionWindowController(appState: appState)
		floatingResultCardController = FloatingResultCardWindowController(appState: appState)

		let env = ProcessInfo.processInfo.environment
		if env["CONTEXTUAL_RUN_BROWSER_TAB_MEMORY_SELFTEST"] == "1" {
			Task {
				let ok = await BrowserTabMemorySelfTest.run()
				print("[BrowserTabMemorySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_WORKING_MEMORY_SELFTEST"] == "1" {
			Task {
				let ok = await WorkingMemorySelfTest.run()
				print("[WorkingMemorySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_ACTION_INTENT_SELFTEST"] == "1" {
			Task {
				let ok = await ActionIntentSelfTest.run()
				print("[ActionIntentSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_MANUAL_INVOKE_JARVIS_SELFTEST"] == "1" {
			Task {
				let ok = await ManualInvokeJarvisSelfTest.run()
				print("[ManualInvokeJarvisSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_CONTEXT_EXECUTION_SELFTEST"] == "1" {
			Task {
				let ok = await ContextExecutionSelfTest.run()
				print("[ContextExecutionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_AMBIENT_JARVIS_SUGGESTION_SELFTEST"] == "1" {
			Task {
				let ok = await AmbientJarvisSuggestionSelfTest.run()
				print("[AmbientJarvisSuggestionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_DAY1_VALIDATION_MODE_SELFTEST"] == "1" {
			Task {
				let ok = await Day1BehaviorValidationModeSelfTest.run()
				print("[Day1BehaviorValidationModeSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_PHASE35_6_COMPLETION_SELFTEST"] == "1" {
			Task {
				let ok = await Phase35_6CompletionSelfTest.run()
				print("[Phase35_6CompletionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_HOOK_IO_CONTRACT_SELFTEST"] == "1" || env["CONTEXTUAL_RUN_HOOK_IO_VALIDATOR_SELFTEST"] == "1" || env["CONTEXTUAL_RUN_HOOK_CHAIN_REPAIR_SELFTEST"] == "1" {
			HookCapabilityRegistry.hookAuditEnabled = true
		}
		// Phase B / B.1 self-tests.
		if env["CONTEXTUAL_RUN_WORKFLOW_INFERENCE_SELFTEST"] == "1" {
			Task {
				let ok = await WorkflowInferenceSelfTest.run()
				print("[WorkflowInferenceSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_CONTEXT_EVENT_PRODUCER_SELFTEST"] == "1" {
			Task {
				let ok = await ContextEventProducerSelfTest.run()
				print("[ContextEventProducerSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 18C — generic ContextExecutionEngine self-test.
		if env["CONTEXTUAL_RUN_CONTEXT_EXECUTION_SELFTEST"] == "1" {
			Task {
				let ok = await ContextExecutionSelfTest.run()
				print("[ContextExecutionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 20D — Judgment Layer self-test.
		if env["CONTEXTUAL_RUN_JUDGMENT_LAYER_SELFTEST"] == "1" {
			Task {
				let ok = await JudgmentLayerSelfTest.run()
				print("[JudgmentLayerSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 20D — live browser AX probe.
		if env["CONTEXTUAL_RUN_BROWSER_AX_PROBE"] == "1" {
			BrowserAXProbe.run()
		}
		// Phase 20F — Active Context Refresh + Manual Invoke Jarvis.
		if env["CONTEXTUAL_RUN_ACTIVE_CONTEXT_REFRESH_SELFTEST"] == "1" {
			Task {
				let ok = await ActiveContextRefreshSelfTest.run()
				print("[ActiveContextRefreshSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 20G — Context epochs + deprecation gates.
		if env["CONTEXTUAL_RUN_CONTEXT_EPOCH_SELFTEST"] == "1" {
			Task {
				let ok = await ContextEpochSelfTest.run()
				print("[ContextEpochSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_CONTEXT_DEPRECATION_SELFTEST"] == "1" {
			Task {
				let ok = await ContextDeprecationSelfTest.run()
				print("[ContextDeprecationSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_ACTION_INTENT_SELFTEST"] == "1" {
			Task {
				let ok = await ActionIntentSelfTest.run()
				print("[ActionIntentSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_BROWSER_TAB_MEMORY_SELFTEST"] == "1" {
			Task {
				let ok = await BrowserTabMemorySelfTest.run()
				print("[BrowserTabMemorySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_FOCUS_EPOCH_SELFTEST"] == "1" {
			Task {
				let ok = await FocusEpochSelfTest.run()
				print("[FocusEpochSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_PERFORMANCE_BUDGET_SELFTEST"] == "1" {
			Task {
				let ok = await PerformanceBudgetSelfTest.run()
				print("[PerformanceBudgetSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
        
        // Phase 21 — Liquid Capabilities
        if env["CONTEXTUAL_RUN_CAPABILITY_REGISTRY_SELFTEST"] == "1" {
            let ok = CapabilityRegistrySelfTest.run()
            print("[CapabilityRegistrySelfTest] env selftest ok=\(ok)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        if env["CONTEXTUAL_RUN_CAPABILITY_SELECTOR_SELFTEST"] == "1" {
            let ok = CapabilitySelectorSelfTest.run()
            print("[CapabilitySelectorSelfTest] env selftest ok=\(ok)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        if env["CONTEXTUAL_RUN_CAPABILITY_EXECUTION_SELFTEST"] == "1" {
            Task {
                let ok = await CapabilityExecutionSelfTest.run()
                print("[CapabilityExecutionSelfTest] env selftest ok=\(ok)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
        
		if env["CONTEXTUAL_RUN_FOCUS_OVERRIDE_SELFTEST"] == "1" {
			Task {
				let ok = await FocusOverrideSelfTest.run()
				print("[FocusOverrideSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_AMBIENT_FLOATING_SUGGESTION_SELFTEST"] == "1" {
			Task {
				let ok = await AmbientFloatingSuggestionSelfTest.run()
				print("[AmbientFloatingSuggestionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 21.1 — DeterminerSignal: composite actionability signal.
		if env["CONTEXTUAL_RUN_DETERMINER_SIGNAL_SELFTEST"] == "1" {
			let ok = DeterminerSignalSelfTest.run()
			print("[DeterminerSignalSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
		}
		// Phase 21.2 — Domain classification + editor fallback + ActionCard regressions.
		if env["CONTEXTUAL_RUN_DOMAIN_CLASSIFIER_SELFTEST"] == "1" {
			let ok = DomainClassifierSelfTest.run()
			print("[DomainClassifierSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
		}
		// Phase 21.2 — ActionCard structural test (subset of DomainClassifier cases).
		if env["CONTEXTUAL_RUN_ACTION_CARD_SELFTEST"] == "1" {
			let ok = DomainClassifierSelfTest.run()
			print("[ActionCardSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
		}
		// Phase 21.4 — Activity state + dwell + active-unknown routing tests.
		if env["CONTEXTUAL_RUN_ACTIVITY_STATE_SELFTEST"] == "1" {
			let ok = ActivityStateSelfTest.run()
			print("[ActivityStateSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
		}
		// Phase 22 — OpportunityEngine: need inference, action-verb titles, observation rejection.
		if env["CONTEXTUAL_RUN_OPPORTUNITY_ENGINE_SELFTEST"] == "1" {
			Task {
				let ok = await OpportunityEngineSelfTest.run()
				print("[OpportunityEngineSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 22 — OpportunityExecution: click path → artifact generation → honest capability reporting.
		if env["CONTEXTUAL_RUN_OPPORTUNITY_EXECUTION_SELFTEST"] == "1" {
			Task {
				let ok = await OpportunityExecutionSelfTest.run()
				print("[OpportunityExecutionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 22 — CompartmentTransition: verify compartment boundaries hold after domain switch.
		if env["CONTEXTUAL_RUN_COMPARTMENT_TRANSITION_SELFTEST"] == "1" {
			Task {
				let ok = await CompartmentTransitionSelfTest.run()
				print("[CompartmentTransitionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		// Phase 20G dogfood regression: TES bypass + Scratch/Gemini classification.
		if env["CONTEXTUAL_RUN_AMBIENT_VISIBILITY_REGRESSION_SELFTEST"] == "1" {
			Task {
				let ok = await AmbientVisibilityRegressionSelfTest.run()
				print("[AmbientVisibilityRegressionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_MANUAL_INVOKE_JARVIS_SELFTEST"] == "1" {
			Task {
				let ok = await ManualInvokeJarvisSelfTest.run()
				print("[ManualInvokeJarvisSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_BEHAVIOR_INFERENCE_SELFTEST"] == "1" {
			Task {
				let ok = await BehaviorInferenceSelfTest.run()
				print("[BehaviorInferenceSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_PHASE_25_9_SELFTEST"] == "1" {
			Task {
				let ok = await Phase25_9SelfTest.run()
				print("[Phase25_9SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_PHASE_26_4_SELFTEST"] == "1" {
			Task {
				let ok = await Phase26_4SelfTest.run()
				print("[Phase26_4SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		if env["CONTEXTUAL_RUN_TASK_COMPARTMENT_SELFTEST"] == "1" {
			Task {
				await TaskCompartmentSelfTest.run()
				print("[TaskCompartmentSelfTest] env selftest ok=true")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
		}
		ModelManager.shared.noteAppLaunch()
		NSApp.setActivationPolicy(.accessory)
		// Emit startup execution-mode audit (silent; no hook-audit noise during dogfood).
		HookContractExecutionRouter.auditStartup()
		if Self.runTaskInferenceBakeoffOnLaunch {
			Task {
				let ok = await TaskInferenceBakeoff.runTwoStageProductionSimulation()
				print("[TaskInferenceBakeoff] launch run ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}
		if runPhase13SelfTestsIfRequested(environment: env) {
			return
		}

		// Hook-Based Action Composition self-tests (T18.5; async; metadata-only).
		// Run with `CONTEXTUAL_RUN_HOOK_COMPOSITION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_HOOK_TAXONOMY_SELFTEST"] == "1" {
			let ok = HookTaxonomySelfTest.run()
			print("[HookTaxonomySelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		if env["CONTEXTUAL_RUN_HOOK_PLAN_SELFTEST"] == "1" {
			Task {
				HookPlanSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_CAPABILITY_CONSTRAINED_PROPOSAL_SELFTEST"] == "1" {
			let ok = CapabilityConstrainedProposalSelfTest.run()
			print("[CapabilityConstrainedProposalSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		if env["CONTEXTUAL_RUN_STRONG_CONTEXT_ANCHOR_SELFTEST"] == "1" {
			let ok = StrongContextAnchorSelfTest.run()
			print("[StrongContextAnchorSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		if env["CONTEXTUAL_RUN_STRONG_CONTEXT_ROUTER_OVERRIDE_SELFTEST"] == "1" {
			let ok = StrongContextRouterOverrideSelfTest.run()
			print("[StrongContextRouterOverrideSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		if env["CONTEXTUAL_RUN_FAST_PROPOSAL_SHELL_SELFTEST"] == "1" {
			Task {
				let ok = await TaskInferenceSelfTest.runFastProposalShellSelfTest()
				print("[FastProposalShellSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_PROPOSAL_ACTION_INTENT_SELFTEST"] == "1" {
			Task {
				let ok = await ProposalActionIntentSelfTest.run()
				print("[ProposalActionIntentSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_ACTION_INTENT_RETRY_SELFTEST"] == "1" {
			Task {
				let ok = await ActionIntentRetrySelfTest.run()
				print("[ActionIntentRetrySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_ACTION_INTENT_PLANNER_BRIDGE_SELFTEST"] == "1" {
			Task {
				let ok = await ActionIntentPlannerBridgeSelfTest.run()
				print("[ActionIntentPlannerBridgeSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_PLANNER_REFINEMENT_ALIGNMENT_SELFTEST"] == "1" {
			let ok = PlannerRefinementAlignmentSelfTest.run()
			print("[PlannerRefinementAlignmentSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		if env["CONTEXTUAL_RUN_PLANNER_CANDIDATE_SELFTEST"] == "1" {
			Task.detached(priority: .userInitiated) {
				await PlannerCandidateSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_HOOK_SCRIPT_DISCOVERY_SELFTEST"] == "1" {
			Task {
				HookScriptDiscoverySelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Part H: Live chain self-test — real Ollama calls, three scenarios.
		// Run with: CONTEXTUAL_RUN_LIVE_CHAIN_SELFTEST=1 <debug binary path>
		// Expected: [LiveChainSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_LIVE_CHAIN_SELFTEST"] == "1" {
			Task.detached(priority: .userInitiated) {
				await LiveChainSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
			}
			return
		}

		// Panel visibility + domain filter self-test (Tasks 1 & 2) — pure logic, no LLM calls.
		// Run with: CONTEXTUAL_RUN_PANEL_DOMAIN_SELFTEST=1 <debug binary path>
		// Expected: [PanelVisibilityDomainSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_PANEL_DOMAIN_SELFTEST"] == "1" {
			Task {
				PanelVisibilityDomainSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_VISUAL_TARGETING_SELFTEST"] == "1" {
			Task {
				await VisualTargetingCorrectnessSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_REHYDRATION_SELFTEST"] == "1" {
			Task {
				await VisualContextRehydrationSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_AGENTIC_LLM_SELFTEST"] == "1" {
			Task {
				_ = await AgenticLLMDeciderSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_DIRECT_AGENT_SELFTEST"] == "1" {
			Task {
				DirectAgentClickSelfTest.runAll()
				DirectAgentDeciderSelfTest.runAll()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_PROPOSAL_PERSISTENCE_SELFTEST"] == "1" {
			Task {
				await PanelVisibilityDomainSelfTest.runPersistenceTests()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_PROPOSAL_REACTIVITY_SELFTEST"] == "1" {
			Task {
				let ok = await ProposalReactivitySelfTest.run()
				print("[ProposalReactivitySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Proposal preservation + final_status self-test.
		// Run with: CONTEXTUAL_RUN_PROPOSAL_PRESERVATION_SELFTEST=1 <debug binary path>
		// Expected: [GeneratedProposalPreservationSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_PROPOSAL_PRESERVATION_SELFTEST"] == "1" {
			Task {
				GeneratedProposalPreservationSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Proposal quality self-test (utility scoring + hook runtime).
		// Run with: CONTEXTUAL_RUN_PROPOSAL_QUALITY_SELFTEST=1 <debug binary path>
		// Expected: [ProposalQualitySelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_PROPOSAL_QUALITY_SELFTEST"] == "1" {
			Task {
				await ProposalQualitySelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		if env["CONTEXTUAL_RUN_HOOK_COMPOSITION_SELFTEST"] == "1" {
			Task {
				let ok = await HookCompositionSelfTests.run()
				print("[HookCompositionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Execution mode self-test: verifies taxonomy, inference, routing, and UI labels.
		// Run with: CONTEXTUAL_RUN_EXECUTION_MODE_SELFTEST=1 <debug binary path>
		// Expected: [HookExecutionModeSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_EXECUTION_MODE_SELFTEST"] == "1" {
			HookContractExecutionRouter.auditStartup()
			HookExecutionSandbox.auditCoverageOnStartup()
			let ok = HookExecutionModeSelfTest.run()
			print("[HookExecutionModeSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		// Observe-once execution self-test: verifies observe_once routing, pre-capture, snapshot merging, and execution.
		// Run with: CONTEXTUAL_RUN_OBSERVE_ONCE_SELFTEST=1 <debug binary path>
		// Expected: [ObserveOnceExecutionSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_OBSERVE_ONCE_SELFTEST"] == "1" {
			Task {
				let ok = await ObserveOnceExecutionSelfTest.run()
				print("[ObserveOnceExecutionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Hook IO Contract self-test: verifies hook IO metadata, registry audit, and taxonomy assertions.
		// Run with: CONTEXTUAL_RUN_HOOK_IO_CONTRACT_SELFTEST=1 <debug binary path>
		// Expected: [HookIOContractSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_HOOK_IO_CONTRACT_SELFTEST"] == "1" {
			let ok = HookIOContractSelfTest.run()
			print("[HookIOContractSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		// Hook IO Validator self-test: verifies hook chain IO validation, snapshot inputs mapping, and opportunistic rules.
		// Run with: CONTEXTUAL_RUN_HOOK_IO_VALIDATOR_SELFTEST=1 <debug binary path>
		// Expected: [HookIOValidatorSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_HOOK_IO_VALIDATOR_SELFTEST"] == "1" {
			HookIOValidatorSelfTest.run()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		// Hook Chain Repair self-test: verifies bounded symbolic hook repair, semantic bridge, and depth limits.
		// Run with: CONTEXTUAL_RUN_HOOK_CHAIN_REPAIR_SELFTEST=1 <debug binary path>
		// Expected: [HookChainRepairSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_HOOK_CHAIN_REPAIR_SELFTEST"] == "1" {
			HookChainRepairSelfTest.run()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		// Proposal Lifecycle self-test: verifies proposal/runtime synchronization, validity, and eviction safety.
		// Run with: CONTEXTUAL_RUN_PROPOSAL_LIFECYCLE_SELFTEST=1 <debug binary path>
		// Expected: [ProposalLifecycleSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_PROPOSAL_LIFECYCLE_SELFTEST"] == "1" {
			ProposalLifecycleSelfTest.run()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return
		}

		// Structured output self-test: verifies router + planner use Ollama schema-constrained
		// generation (format: {JSON Schema}) and produce valid, prose-free JSON every call.
		// Run with: CONTEXTUAL_RUN_STRUCTURED_OUTPUT_SELFTEST=1 <debug binary path>
		// Expected: [StructuredOutputSelfTest] ok=true failures=0
		if env["CONTEXTUAL_RUN_STRUCTURED_OUTPUT_SELFTEST"] == "1" {
			Task.detached(priority: .userInitiated) {
				await StructuredOutputSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
			}
			return
		}

		// Manual hook composition debug probe.
		// Run with `CONTEXTUAL_DEBUG_COMPOSE_ACTION="Compare products"` (or any goal string).
		// Prints [HookAudit], [HookDiscovery], [HookValidation], [GeneratedActionContract] logs and exits.
		if let debugGoal = env["CONTEXTUAL_DEBUG_COMPOSE_ACTION"], !debugGoal.isEmpty {
			Task {
				await HookCompositionSelfTests.runManualCompose(goal: debugGoal)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Router direct probe: tests both batch and streaming paths against qwen2.5:0.5b
		// using the exact production router prompt format and prints [RouterProbe] results, then exits.
		// Use to isolate whether latency is a cold-start, a streaming path bug, or Ollama config.
		//
		// Correct command (use debug binary, not /Applications):
		//   CONTEXTUAL_DEBUG_ROUTER_DIRECT_PROBE=1 \
		//     /path/to/DerivedData/.../Debug/Contextual.app/Contents/MacOS/Contextual
		//
		// Expected output (warm model):
		//   [RouterProbe] path=batch  success=yes total_ms=<400   raw="...json..."
		//   [RouterProbe] path=streaming success=yes total_ms=<250 raw="{...}"
		//   [RouterProbe] finished
		if env["CONTEXTUAL_DEBUG_ROUTER_DIRECT_PROBE"] == "1" {
			Task {
				// Use the exact production router prompt format (matches TwoStageRouterPromptBuilder output).
				// The previous "JSON only. {...}\n" format caused the model to describe the JSON
				// rather than reproduce it. The multi-line instruction format below works correctly.
				let probeRouterPrompt = """
JSON only. One object: {"decision":"enough_context","request":[],"reason":"brief","confidence":0.9}
request values: "ocr","visual_descriptor","ax_window_text". If decision=enough_context, request=[].
enough_context: app+title are clear, OR selected/ocr/visual/ax is present. need_more_context: browser/media/game with no text. Never request context already present.
ctx app=Probe title=router-direct-probe wf=unknown ocr=no visual=no ax=no sel=no clip=no
"""
				let model = "qwen2.5:0.5b"
				print("[RouterProbe] started model=\(model) prompt_bytes=\(probeRouterPrompt.utf8.count)")

				// Path A: batch (stream:false — verifies model loads, ignores streaming code path)
				print("[RouterProbe] path=batch starting")
				let batchStart = Date()
				do {
					let raw = try await LocalAIClient.shared.generate(
						prompt: probeRouterPrompt,
						model: model,
						numPredict: 48,
						temperature: 0.10,
						purpose: nil,
						schema: nil
					)
					let ms = Int(Date().timeIntervalSince(batchStart) * 1000)
					let preview = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: "↵")
					print("[RouterProbe] path=batch success=yes total_ms=\(ms) raw=\"\(preview)\"")
				} catch {
					let ms = Int(Date().timeIntervalSince(batchStart) * 1000)
					print("[RouterProbe] path=batch success=no total_ms=\(ms) error=\(error)")
				}

				// Path B: streaming (current production router path — emits [TwoStageRouterTiming] logs)
				print("[RouterProbe] path=streaming starting")
				let streamStart = Date()
				do {
					let raw = try await LocalAIClient.shared.generateStreamingJSON(
						prompt: probeRouterPrompt,
						model: model,
						numPredict: 48,
						temperature: 0.10,
						purpose: "task_inference_router",
						schema: nil
					)
					let ms = Int(Date().timeIntervalSince(streamStart) * 1000)
					let preview = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: "↵")
					print("[RouterProbe] path=streaming success=yes total_ms=\(ms) raw=\"\(preview)\"")
				} catch {
					let ms = Int(Date().timeIntervalSince(streamStart) * 1000)
					print("[RouterProbe] path=streaming success=no total_ms=\(ms) error=\(error)")
				}

				print("[RouterProbe] finished")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Phase 14: lightweight activity monitoring for proposal timing (metadata-only).
		TypingActivitySource.shared.startMonitoring()
		PointerActivitySource.shared.startMonitoring()

		syncLocalAIFromStorage()
		wireLocalAIHandlers()

		appState.onRevealAssistantPanel = { [weak self] in
			self?.menuBarController?.revealPopoverIfNeeded(source: .suggestion_auto)
		}
		appState.onAmbientJarvisFloatingSuggestionCandidate = { [weak self] proposal in
			Task { @MainActor in
				self?.maybeShowAmbientJarvisFloatingSuggestion(proposal: proposal)
			}
		}

		menuBarController?.onPopoverDidShow = { [weak self] in
            self?.appState.isPanelVisible = true
			self?.appState.dismissFloatingSuggestion(reason: .panelOpen)
			self?.appState.updateHighUsefulnessPanelVisibility()
		}
        menuBarController?.onPopoverDidClose = { [weak self] in
            self?.appState.isPanelVisible = false
			self?.appState.updateHighUsefulnessPanelVisibility()
        }

		appState.requestManualInvocation = { [weak self] in
			Task { @MainActor in
				self?.dispatchManualTriggerEvent()
				self?.menuBarController?.revealPopoverIfNeeded(source: .explicit_button)
			}
		}

		appState.onInvokeActionById = { [weak self] actionId in
			self?.invokeStoredAction(actionId: actionId)
		}

		appState.onInvokeGeneratedExecutionProposalById = { [weak self] candidateId in
			self?.invokeGeneratedExecutionProposal(candidateId: candidateId)
		}

		// T18.4: cancel wiring — routes UI cancel tap to actor-isolated runtime.
		appState.onCancelGeneratedExecution = { [weak self] in
			Task {
				await self?.activeGeneratedExecutionRuntime?.cancel()
			}
		}

		manualTriggerObserver = NotificationCenter.default.addObserver(
			forName: .contextualManualTrigger,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.dispatchManualTriggerEvent()
				self?.menuBarController?.revealPopoverIfNeeded(source: .shortcut)
			}
		}

		canonicalContextObserver = NotificationCenter.default.addObserver(
			forName: .contextualCanonicalContextUpdated,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.appState.refreshContextAwarenessSummary()
			}
		}

		openTaskPanelObserver = NotificationCenter.default.addObserver(
			forName: .contextualOpenTaskPanel,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.menuBarController?.revealPopoverIfNeeded(source: .explicit_button)
				self?.appState.isPanelVisible = true
			}
		}

		// Phase 41 — Suppress work-pair friction counting after monitor reconnects.
		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { _ in
			print("[MonitorRestore] screen_params_changed suppressing_friction=yes duration=10s")
			WorkPairMemory.shared.suppressForSystemRestore(seconds: 10)
		}

		let manager = SourceManager { event in
			self.processSourceEvent(event)
		}
		self.sourceManager = manager
		manager.start()
		processUpdatedContextAfterPipeline()

		if LocalAISettings.shared.localAIEnabled {
			scheduleLocalAIPrepare()
		}

		// T18.3.6: Seed built-in generated action templates and drain the prewarm queue.
		// Must run after manager/library init so the shared store is ready.
		// No LLM is called. This is fast and idempotent.
		Task {
			let manager = GeneratedActionPersistenceManager.shared
			let seeder = GeneratedActionTemplateSeeder.shared
			await seeder.seedIfNeeded(into: manager)
			await GeneratedActionTemplatePrewarmConsumer.shared.consume(
				from: GeneratedActionTemplatePrewarmQueue.shared,
				seeder: seeder,
				manager: manager
			)
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		if let manualTriggerObserver {
			NotificationCenter.default.removeObserver(manualTriggerObserver)
		}
		if let canonicalContextObserver {
			NotificationCenter.default.removeObserver(canonicalContextObserver)
		}
		if let openTaskPanelObserver {
			NotificationCenter.default.removeObserver(openTaskPanelObserver)
		}
		sourceManager?.stop()
	}

	private func syncLocalAIFromStorage() {
		let s = LocalAISettings.shared
		appState.localAIEnabled = s.localAIEnabled
		appState.autoStartOllama = s.autoStartOllama
		appState.twoStageTaskInferenceEnabled = s.twoStageTaskInferenceEnabled
		if s.localAIEnabled {
			appState.modelRuntimeState = .checking
		}
	}

	private func wireLocalAIHandlers() {
		appState.onEnableLocalAI = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.localAIEnabled = true
			self.appState.localAIEnabled = true
			self.appState.modelRuntimeState = .checking
			self.scheduleLocalAIPrepare()
		}

		appState.onDisableLocalAI = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.localAIEnabled = false
			self.appState.localAIEnabled = false
			self.appState.modelRuntimeState = .unavailable
			Task.detached(priority: .utility) {
				await ModelAuditManager.shared.stopPeriodicKeepalive()
			}
		}

		appState.onEnableAutoStartOllama = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.autoStartOllama = true
			self.appState.autoStartOllama = true
			let uiState = self.appState
			Task.detached(priority: .utility) {
				do {
					try await ModelManager.shared.startOllamaServer()
				} catch {
					await MainActor.run {
						uiState.modelRuntimeState = .unavailable
					}
					return
				}
				await ModelManager.shared.prepareLocalAIIfEnabled(
					settings: LocalAISettings.shared,
					allowModelPull: true,
					updateState: { runtimeState in
						DispatchQueue.main.async {
							uiState.modelRuntimeState = runtimeState
						}
					}
				)
			}
		}

		appState.onDisableAutoStartOllama = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.autoStartOllama = false
			self.appState.autoStartOllama = false
		}

		appState.onStartOllamaNow = { [weak self] in
			guard let self else { return }
			let uiState = self.appState
			Task.detached(priority: .utility) {
				do {
					try await ModelManager.shared.startOllamaServer()
				} catch {
					await MainActor.run {
						uiState.modelRuntimeState = .unavailable
					}
					return
				}
				await ModelManager.shared.prepareLocalAIIfEnabled(
					settings: LocalAISettings.shared,
					allowModelPull: true,
					updateState: { runtimeState in
						DispatchQueue.main.async {
							uiState.modelRuntimeState = runtimeState
						}
					}
				)
			}
		}

		appState.onOpenOllamaDownload = {
			if let url = URL(string: "https://ollama.com/download") {
				NSWorkspace.shared.open(url)
			}
		}

		appState.onPullLocalAIModel = { [weak self] in
			guard let self else { return }
			let uiState = self.appState
			Task.detached(priority: .utility) {
				await ModelManager.shared.pullConfiguredModel { runtimeState in
					DispatchQueue.main.async {
						uiState.modelRuntimeState = runtimeState
					}
				}
			}
		}
	}

	private func scheduleLocalAIPrepare() {
		let uiState = appState
		appState.modelRuntimeState = .checking
		Task.detached(priority: .utility) {
			let graceNanos = UInt64(4 * 1_000_000_000)
			try? await Task.sleep(nanoseconds: graceNanos)
			await ModelManager.shared.prepareLocalAIIfEnabled(
				settings: LocalAISettings.shared,
				allowModelPull: false,
				updateState: { runtimeState in
					DispatchQueue.main.async {
						uiState.modelRuntimeState = runtimeState
						// After model becomes ready: refresh persisted model status immediately,
						// then run audit and warmup in background.
						if case .ready = runtimeState {
							Task { await uiState.refreshModelStatus() }
							Task.detached(priority: .utility) {
								let base = LocalAISettings.shared.modelName
								// Run parser + composer self-test on startup (no live AI — fast).
								if ProcessInfo.processInfo.environment["CONTEXTUAL_RUN_TASK_INFERENCE_SELFTEST"] == "1" {
									let selfTestOk = await TaskInferenceSelfTest.run()
									if !selfTestOk {
										print("[TaskInferenceSelfTest] WARNING startup self-test failed — parser may reject model output")
									}
								} else {
									print("[SelfTest] skipped reason=env_not_set")
								}
								if LocalAISettings.shared.twoStageTaskInferenceEnabled {
									print("[TwoStageInference] bypassing old single-stage audit, warmup, and keepalive because two-stage mode is ON")
									// Warm up router and planner models for two-stage inference.
									// Cold-start for qwen2.5:0.5b is ~8-10s (GGUF load from disk).
									// A startup warmup ensures the first router call responds in ~100ms.
									// Sequential to respect OLLAMA_NUM_PARALLEL=1 — router first.
									let routerModel = TaskInferenceEngine.routerModelName
									let plannerModel = TaskInferenceEngine.plannerModelName
									print("[TwoStageWarmup] warming router=\(routerModel)")
									await ModelAuditManager.shared.runWarmupIfNeeded(model: routerModel)
									print("[TwoStageWarmup] warming planner=\(plannerModel)")
									await ModelAuditManager.shared.runWarmupIfNeeded(model: plannerModel)
									
									print("[TwoStageWarmup] ready_for_inference=yes")
									self.twoStageWarmupComplete = true
									if let pending = self.popPendingActionIntentIfReady(now: Date(), reason: "planner_became_ready") {
										Task { @MainActor [packet = pending.packet, context = pending.context, pending = pending] in
											// Re-run proposals using the latest pipeline generation so the retry
											// isn't discarded as stale. We intentionally reuse the stored strong
											// context even if the current active title is transient/weak.
											let generation = self.contextPipelineGeneration
											await self.updateDynamicOnlyProposals(
												from: packet,
												context: context,
												generation: generation,
												decision: ReasoningDecision(
													shouldSurface: true,
													primaryActionId: nil,
													rankedActionIds: [],
													reason: "pending_action_intent_retry",
													confidence: 1.0
												),
												pendingActionIntentRetry: pending
											)
										}
									}
									if let deferred = self.deferredWarmupTrigger {
										print("[GeneratedProposal] retrying_deferred_after_warmup trigger=\(deferred.packet.triggerType.rawValue)")
										self.deferredWarmupTrigger = nil
										Task {
											await self.updateDynamicOnlyProposals(
												from: deferred.packet,
												context: deferred.context,
												generation: deferred.generation,
												decision: ReasoningDecision(
													shouldSurface: true,
													primaryActionId: nil,
													rankedActionIds: [],
													reason: "deferred_retry",
													confidence: 1.0
												)
											)
										}
									}
									
									// Keep the router resident with a 4-minute keepalive ping loop.
									// Ollama's default idle unload TTL is 5 minutes; this prevents cold
									// re-loads during sustained dogfooding sessions.
									await ModelAuditManager.shared.startPeriodicKeepalive(model: routerModel)
									return
								}
								// Run model audit (discover + benchmark candidates).
								await ModelAuditManager.shared.runAuditIfNeeded(baseModel: base)
								await uiState.refreshModelAuditInfo()
								// Speculative warmup after audit selects the best model.
								let chosen = await ModelAuditManager.shared.selectedModel() ?? base
								await ModelAuditManager.shared.runWarmupIfNeeded(model: chosen)
								// Start keepalive loop to prevent Ollama from unloading the
								// model between inference bursts (default Ollama idle TTL = 5 min).
								await ModelAuditManager.shared.startPeriodicKeepalive(model: chosen)
							}
						}
					}
				}
			)
		}
	}

	private func dispatchManualTriggerEvent() {
		let now = Date()
		if let last = lastManualInvocationAt, now.timeIntervalSince(last) < 0.75 {
			if !didLogManualGuard {
				didLogManualGuard = true
				print("[ManualTrigger] ignored duplicate within guard window")
			}
			return
		}
		didLogManualGuard = false
		lastManualInvocationAt = now

		// Phase 20F — when Ambient MVP mode is on, manual invoke now routes
		// through the Ambient Jarvis pipeline instead of the legacy
		// analyze_screen / Moondream affordance. Visual descriptor is a
		// fallback (only when no other context exists), not the default.
		if AmbientMVPMode.isEnabled {
			print("[ManualInvocation] routing=ManualInvokeJarvis reason=ambient_mvp_enabled")
			let producer = appState.workflowEventProducer
			let coordinator = appState.workflowIntelligenceCoordinator
			let behavioral = appState.behavioralIntelligenceCoordinator
			let snapshot = appState.latestCanonicalSnapshot
			Task { @MainActor [weak self] in
				guard let self else { return }
				_ = await ManualInvokeJarvis.invoke(
					source: "menu_or_hotkey",
					producer: producer,
					coordinator: coordinator,
					behavioral: behavioral,
					currentSnapshot: snapshot,
					publishSuggestion: { suggestion in
						self.appState.publishAmbientJarvisSuggestion(suggestion)
					}
				)
			}
			return
		}

		print("[ManualInvocation] screen_capture_skipped reason=normal_manual")
		print("[ScreenCapture] skipped reason=not_explicit_analyze_screen")
		sourceManager?.refreshSelectionNow()
		processSourceEvent(.sourceChanged(.manualTriggerRequested))
	}

	// MARK: - Phase 4S — Pending action-intent retry (warmup handoff)

	func storePendingActionIntentIfNeeded(
		packet: TriggerPacket,
		context: ContextModel,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		generation: UInt64,
		fingerprint: String,
		title: String,
		classification: FastVisibilityTitleClassification
	) {
		let now = Date()
		// Warmup can take ~8–12s on cold start; keep a short but sufficient TTL
		// so a strong context doesn't evaporate before the planner is ready.
		let ttl: TimeInterval = 25.0
		let expiresAt = now.addingTimeInterval(ttl)

		if let existing = pendingActionIntentRequest {
			// Keep the newest pending request by fingerprint.
			if existing.fingerprint == fingerprint {
				// Refresh TTL on the same strong context.
				pendingActionIntentRequest = ActionIntentPendingRequest(
					packet: packet,
					context: context,
					snapshot: snapshot,
					situational: situational,
					generation: generation,
					fingerprint: fingerprint,
					title: title,
					classification: classification,
					storedAt: existing.storedAt,
					expiresAt: expiresAt
				)
				return
			}
		}

		pendingActionIntentRequest = ActionIntentPendingRequest(
			packet: packet,
			context: context,
			snapshot: snapshot,
			situational: situational,
			generation: generation,
			fingerprint: fingerprint,
			title: title,
			classification: classification,
			storedAt: now,
			expiresAt: expiresAt
		)
		print("[ActionIntentPending] stored reason=fast_visibility_needs_action_intent classification=\(classification.rawValue) fp=\(fingerprint) title=\"\(title.prefix(80))\" ttl_s=\(Int(ttl))")
	}

	func expirePendingActionIntentIfNeeded(now: Date) {
		guard let pending = pendingActionIntentRequest else { return }
		if now >= pending.expiresAt {
			print("[ActionIntentPending] expired reason=ttl_elapsed fp=\(pending.fingerprint)")
			pendingActionIntentRequest = nil
		}
	}

	func popPendingActionIntentIfReady(now: Date, reason: String) -> ActionIntentPendingRequest? {
		guard LocalAISettings.shared.twoStageTaskInferenceEnabled else { return nil }
		guard twoStageWarmupComplete else { return nil }
		expirePendingActionIntentIfNeeded(now: now)
		guard let pending = pendingActionIntentRequest else { return nil }

		// Do NOT expire simply because the context pipeline generation advanced.
		// During warmup, benign SourceEvents can bump `contextPipelineGeneration`
		// repeatedly before models are ready. Preserve the pending request across
		// those changes; expire only by TTL or a clear context family change.
		let currentBundle = contextBuilder.model.activeAppBundleIdentifier?.lowercased() ?? ""
		let pendingBundle = pending.context.activeAppBundleIdentifier?.lowercased() ?? ""
		if !currentBundle.isEmpty, !pendingBundle.isEmpty, currentBundle != pendingBundle {
			print("[ActionIntentPending] expired reason=app_bundle_changed fp=\(pending.fingerprint)")
			pendingActionIntentRequest = nil
			return nil
		}
		if pending.generation != contextPipelineGeneration {
			print("[ActionIntentPending] preserved reason=same_strong_context_family fp=\(pending.fingerprint)")
		}

		print("[ActionIntentPending] retrying reason=\(reason) fp=\(pending.fingerprint)")
		pendingActionIntentRequest = nil
		return pending
	}

	// Debug/self-test accessors used by deterministic self-tests.
	// These do not affect production behavior unless the env-gated self-tests are run.
	var debugHasPendingActionIntentRequest: Bool { pendingActionIntentRequest != nil }
	var debugPendingActionIntentFingerprint: String? { pendingActionIntentRequest?.fingerprint }

	func debugSetTwoStageWarmupComplete(_ value: Bool) { twoStageWarmupComplete = value }
	func debugSetContextPipelineGeneration(_ value: UInt64) { contextPipelineGeneration = value }
	func debugSetActiveAppForSelfTest(bundleIdentifier: String, appName: String, windowTitle: String) {
		contextBuilder.handle(.sourceChanged(.activeAppChanged(bundleIdentifier: bundleIdentifier, name: appName)))
		contextBuilder.handle(.sourceChanged(.windowTitleChanged(bundleIdentifier: bundleIdentifier, appName: appName, title: windowTitle)))
	}

	private func processSourceEvent(_ event: SourceEvent) {
		contextBuilder.handle(event)

		if case .sourceChanged(.selectedTextChanged(let text)) = event {
			let len = text?.count ?? 0
			if len > TriggerEngine.selectedTextMinCharacterCount {
				resetStaleInputSourceAfterNewSelection(context: contextBuilder.model)
			}
		}

		processUpdatedContextAfterPipeline()
		switch event {
		case .sourceChanged(.clipboardTextChanged(let text)):
			let length = text?.count ?? 0
			let exists = (text?.isEmpty == false)
			print("[SourceEvent] clipboardTextChanged exists=\(exists) length=\(length)")
		case .sourceChanged(.selectedTextChanged(let text)):
			let length = text?.count ?? 0
			let exists = (text?.isEmpty == false)
			print("[SourceEvent] selectedTextChanged exists=\(exists) length=\(length)")
		case .sourceChanged(.manualTriggerRequested):
			print("[SourceEvent] manualTriggerRequested")
		case .sourceChanged(.screenOCRCompleted(let text, let lineCount, _)):
			print("[SourceEvent] screenOCRCompleted chars=\(text.utf8.count) lines=\(lineCount)")
		case .screenCaptured:
			print("[SourceEvent] screenCaptured")
		default:
			print("[SourceEvent]", event)
		}
	}

	/// T12.10: After manual/OCR, user may leave “Screen text” selected — new real selection should resume automatic resolution.
	private func resetStaleInputSourceAfterNewSelection(context: ContextModel) {
		if appState.selectedInputSourceChoice == .screenOCR {
			appState.selectedInputSourceChoice = .automatic
			appState.floatingSuggestionLifecycle.clearAllForInputChannelReset()
			print("[InputSource] reset_stale_source reason=new_selection prev=screen_ocr")
		}
	}

	private func processUpdatedContextAfterPipeline() {
		appState.debugContext = contextBuilder.model
		appState.refreshContextAwarenessSummary()
		logContextModel(contextBuilder.model)

		let context = contextBuilder.model
		let bid = context.activeAppBundleIdentifier ?? ""
		if !bid.isEmpty {
			if let prev = lastPipelineActiveAppKey, prev != bid {
				appState.redundancyMemory.pruneEntriesOlderThan(seconds: 12 * 60)
				print("[ContextPipeline] redundancy_prune reason=active_app_change")
			}
			lastPipelineActiveAppKey = bid
		}

		// T15.1: lightweight workflow inference (metadata-only, in-memory).
		WorkflowInferenceEngine.shared.recordAppBundle(bid.isEmpty ? nil : bid)
		WorkflowInferenceEngine.shared.evaluate(referenceTime: Date())

		// Phase 18B Day 2 — feed the Ambient Jarvis producer on every context
		// update, NOT only when the trigger engine emits a packet (which is
		// what gates `updateAvailableActions` at line ~1018 below). Without
		// this feed, the Day 2 producer only sees snapshots on OCR-flavored
		// triggers; a shopping comparison driven by window-title changes
		// alone never reaches the workflow brain.
		//
		// Minimal snapshot — `activeApp` is required, everything else is
		// optional. The producer dedups against prior hashes, so repeated
		// identical contexts emit nothing.
		if AmbientMVPMode.isEnabled, let appName = context.activeAppName, !appName.isEmpty {
			let ambientSnapshot = CanonicalGeneratedExecutionContextSnapshot(
				activeApp: appName,
				windowTitle: context.activeWindowTitle ?? "",
				bundleIdentifier: context.activeAppBundleIdentifier
			)
			appState.updateLatestCanonicalSnapshot(ambientSnapshot)
		}

		// T15.2: session continuity (metadata-only, bounded, decaying).
		ContextualSessionTracker.shared.recordSample(
			inference: WorkflowInferenceEngine.shared.latestResult(),
			fused: CanonicalContextState.shared.current(),
			activeBundle: bid.isEmpty ? nil : bid,
			referenceTime: Date()
		)

		contextPipelineGeneration += 1
		let generation = contextPipelineGeneration
		let triggerPacket = triggerEngine.evaluate(context)

		// T15.3: structured intent concepts (non-executable, bounded, metadata-only).
		let synthesisText = ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .automatic) ?? ""
		let synthesisFeatures = FeatureExtractor.extract(from: synthesisText)
		var synthesisCandidateIds = triggerPacket?.candidateActions ?? []
		if synthesisCandidateIds.isEmpty, !appState.availableActions.isEmpty {
			synthesisCandidateIds = appState.availableActions.map { $0.id }
		}
		let intentRequest = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceEngine.shared.latestResult(),
			sessionState: ContextualSessionTracker.shared.currentState(),
			fused: CanonicalContextState.shared.current(),
			features: synthesisFeatures,
			candidateActionIds: synthesisCandidateIds,
			triggerType: triggerPacket?.triggerType,
			lastSourceTrigger: context.lastSourceTrigger?.rawValue
		)
		IntentSynthesisEngine.shared.record(intentRequest, referenceTime: Date())

		if let packet = triggerPacket {
			logTriggerPacket(packet, context: context)
			Task { await self.updateAvailableActions(from: packet, context: context, generation: generation) }
		} else {
			if DynamicOnlyProposalMode.isEnabled {
				GeneratedProposalActivationDiagnostics.logSkip(
					phase: "skipped_before_situational_synthesis",
					detail: "no_trigger_packet last=\(context.lastSourceTrigger?.rawValue ?? "none")"
				)
			}
			preserveOrClearAvailableActions(reason: "no trigger packet")
		}
	}

	private func updateAvailableActions(from packet: TriggerPacket, context: ContextModel, generation: UInt64) async {
		let decision = ReasoningEngine.shared.evaluate(context: context, triggerPacket: packet)
		let primary = decision.primaryActionId ?? "none"
		print("[ReasoningEngine] decision surface=\(decision.shouldSurface) primary=\(primary) confidence=\(decision.confidence) reason=\(decision.reason)")

		guard decision.shouldSurface else {
			GeneratedProposalActivationDiagnostics.logSkip(
				phase: "skipped_before_situational_synthesis",
				detail: "reasoning_shouldSurface=false trigger=\(packet.triggerType.rawValue)"
			)
			preserveOrClearAvailableActions(reason: "reasoning shouldSurface=false")
			return
		}

		if DynamicOnlyProposalMode.isEnabled {
			let attemptId = String(UUID().uuidString.prefix(6))
			print("[ProposalAttempt] id=\(attemptId) started app=\(context.activeAppBundleIdentifier ?? "none") title=\(String(context.activeWindowTitle?.prefix(40) ?? "none"))")
			await ProposalAttemptScope.$currentId.withValue(attemptId) {
				await updateDynamicOnlyProposals(
					from: packet,
					context: context,
					generation: generation,
					decision: decision
				)
			}
			
			let storedVisible = appState.activatedGeneratedProposals.count
			let uiVisible = appState.dynamicActionDisplaySummary.showsGeneratedPreview ? 1 : 0
			// Task B: final_status reflects what the user actually sees.
			// rendered   = UI currently displays a proposal (regardless of stored count)
			// stored_not_rendered = stored but not yet painted to screen
			// hidden     = neither stored nor visible in UI
			let status: String = {
				if uiVisible > 0 { return "rendered" }
				if storedVisible > 0 { return "stored_not_rendered" }
				return "hidden"
			}()
			print("[ProposalAttempt] id=\(attemptId) stored_visible=\(storedVisible) ui_visible=\(uiVisible) final_status=\(status)")
			return
		} else {

		}

		let proposalGateResult = ProposalGenerationGate.evaluate(context: context)
		let deterministicPanel = buildDeterministicPanelPublication(context: context)

		// Phase 43 — Proactively surface cognitive preparation action as a floating pill.
		if let cogAct = deterministicPanel.cognitiveFloatingAction {
			maybeShowCognitiveFloatingSuggestion(panelAction: cogAct, context: context)
		}

		// Compute features + type once for relevance scoring (no AI, metadata only).
		let sourceText = ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .automatic) ?? ""
		let features = FeatureExtractor.extract(from: sourceText)
		let contextType = ContextClassifier.classify(features: features, text: sourceText)

		let relevanceBase = ActionRelevanceScorer.scoreActions(
			candidateActionIds: decision.rankedActionIds,
			contextType: contextType,
			features: features
		)

		// Apply session-only redundancy tuning (T11.7) using the existing privacy-safe lifecycle key.
		let rawSimilarity = FloatingSimilarityText.material(
			for: context,
			triggerType: packet.triggerType,
			inputPreference: appState.effectiveInputSource(for: context)
		)
		let profile = ContentSimilarityProfile.make(from: rawSimilarity)
		let relevance = relevanceBase.map { r -> ActionRelevanceScore in
			let key = appState.floatingSuggestionLifecycle.exactKey(
				triggerType: packet.triggerType,
				primaryActionId: r.actionId,
				profile: profile
			)
			let adj = appState.redundancyMemory.adjustment(for: key, actionId: r.actionId)
			let adjusted = min(1.0, max(0.0, r.score + adj.scoreDelta))
			let reason = adj.scoreDelta == 0 ? r.reason : "\(r.reason)+mem(\(adj.reason))"
			return ActionRelevanceScore(actionId: r.actionId, score: adjusted, reason: reason)
		}

		let rankedIds = relevance.map(\.actionId)
		logActionRelevanceIfNeeded(ranked: relevance, topId: rankedIds.first)

		guard let ranking = ProposalRanker.rank(relevance: relevance, reasoningPrimary: decision.primaryActionId) else {
			if !deterministicPanel.actions.isEmpty {
				print("[AvailableActions] preserved_panel_actions reason=floating_ranking_unavailable panel_count=\(deterministicPanel.panelCount)")
				print("[AvailableActions] cleared_floating_only reason=proposal_ranking_unavailable")
				publishReasonedActions(
					ordered: deterministicPanel.actions,
					finalProposal: nil,
					finalProposalKey: nil,
					strength: nil,
					packet: packet,
					context: context,
					generation: generation,
					proposalGateAllows: false,
					generatedProposalActivation: .empty
				)
				return
			}
			preserveOrClearAvailableActions(reason: "proposal ranking unavailable")
			return
		}
		logProposalRankingIfNeeded(ranking)

		if ranking.tieResolved {
			print("[ProposalRanking] tie resolved primary=\(ranking.primaryActionId)")
		}

		let typingCtx = TypingActivitySource.shared.currentContext()
		let pointerCtx = PointerActivitySource.shared.currentContext()

		// Phase 14.4: rich context proposal selection (metadata-only; uses canonical fused context if present).
		let richAdj = RichContextProposalAdjuster.adjust(
			relevance: relevance,
			context: context,
			fused: CanonicalContextState.shared.current(),
			contextType: contextType,
			features: features,
			isManualInvocation: packet.triggerType == .manualInvocation
		)
		let richRelevance = richAdj.adjustedScores
		if richAdj.reasonCodes.contains("no_rich_context") {
			print("[RichProposal] kept reason=no_rich_context")
		} else if richAdj.reasonCodes.contains("rich_context_ignored_stale") {
			print("[RichProposal] ignored reason=rich_context_ignored_stale")
		} else if richAdj.shouldSuppressAutomaticProposal {
			print("[RichProposal] suppressed reason=form_context_suppress")
		} else if let r = richAdj.reasonCodes.first, r != "no_rich_adjustment" {
			print("[RichProposal] adjusted reason=\(r) primary=\(richAdj.adjustedPrimaryActionId ?? ranking.primaryActionId)")
		}

		let workflowRank = WorkflowAwareProposalRanker.adjust(
			baseRelevance: richRelevance,
			packet: packet,
			context: context,
			contextType: contextType,
			features: features,
			profile: profile,
			redundancyMemory: appState.redundancyMemory,
			lifecycle: appState.floatingSuggestionLifecycle,
			typing: typingCtx,
			pointer: pointerCtx,
			reasoningPrimary: decision.primaryActionId
		)

		guard let richRanking = ProposalRanker.rank(relevance: workflowRank.adjustedScores, reasoningPrimary: decision.primaryActionId) else {
			if !deterministicPanel.actions.isEmpty {
				print("[AvailableActions] preserved_panel_actions reason=floating_ranking_unavailable panel_count=\(deterministicPanel.panelCount)")
				print("[AvailableActions] cleared_floating_only reason=proposal_ranking_unavailable")
				publishReasonedActions(
					ordered: deterministicPanel.actions,
					finalProposal: nil,
					finalProposalKey: nil,
					strength: nil,
					packet: packet,
					context: context,
					generation: generation,
					proposalGateAllows: false,
					generatedProposalActivation: .empty
				)
				return
			}
			preserveOrClearAvailableActions(reason: "proposal ranking unavailable after rich adjust")
			return
		}

		// Phase 14: activity-aware proposal timing gate (Triggers layer; metadata-only).
		let canonical = CanonicalContextState.shared.current()
		
		let hasSelectionInfluence = AgenticPivot.isSelectedTextInfluenceEnabled && context.selectedTextAvailable
		let hasStrongSelectedText = hasSelectionInfluence && context.selectedTextLength >= TriggerEngine.selectedTextMinCharacterCount
		let isSelectedTextPrimary = hasSelectionInfluence && packet.triggerType == .selectedTextEligible
		
		let timing = ProposalTimingGate.evaluate(
			isManualInvocation: packet.triggerType == .manualInvocation,
			isActionExecuting: appState.isActionExecuting,
			hasStrongSelectedText: hasStrongSelectedText,
			isSelectedTextPrimary: isSelectedTextPrimary,
			canonicalFreshness: canonical?.freshnessScore,
			canonicalConfidence: canonical?.confidence,
			typing: typingCtx,
			pointer: pointerCtx,
			proposalStrengthHint: max(decision.confidence, richRanking.topScore)
		)
		logProposalTimingIfNeeded(decision: timing, typing: typingCtx, pointer: pointerCtx)

		// If everything is weak, avoid creating a proposal (Available Actions still show).
		let shouldGenerateProposalByRelevance = richRanking.topScore >= 0.50

		let proposalPromo = WorkflowAwareProposalRanker.proposalProminenceConfidenceDelta(
			primaryActionId: richRanking.primaryActionId,
			interruption01: workflowRank.interruptionCost
		)
		let proposalConfidence = min(0.95, decision.confidence + proposalPromo)

		let overriddenDecision = ReasoningDecision(
			shouldSurface: decision.shouldSurface,
			primaryActionId: richRanking.primaryActionId,
			rankedActionIds: rankedIds.isEmpty ? decision.rankedActionIds : [richRanking.primaryActionId] + richRanking.secondaryActionIds,
			reason: decision.reason,
			confidence: proposalConfidence
		)

		var proposal: ActionProposal?
		var strength: SuggestionStrengthResult?
		if (timing.outcome == .suppress || richAdj.shouldSuppressAutomaticProposal), packet.triggerType != .manualInvocation {
			proposal = nil
		} else if timing.outcome == .deferred, packet.triggerType != .manualInvocation {
			proposal = nil
			scheduleDeferredProposalRefreshIfNeeded(
				retryAfter: timing.suggestedRetryAfter ?? 1.2,
				originalGeneration: generation
			)
		} else if packet.triggerType == .manualInvocation {
			proposal = ProposalGenerator.shared.generate(
				context: context,
				triggerPacket: packet,
				decision: overriddenDecision,
				inputSourcePreference: appState.selectedInputSourceChoice
			)
		} else {
			logProposalGateIfNeeded(allowed: proposalGateResult.shouldGenerate, reason: proposalGateResult.reason)
			if proposalGateResult.shouldGenerate, shouldGenerateProposalByRelevance {
				proposal = ProposalGenerator.shared.generate(
					context: context,
					triggerPacket: packet,
					decision: overriddenDecision,
					inputSourcePreference: appState.selectedInputSourceChoice
				)
			}
		}

		if let p = proposal {
			let s = SuggestionStrengthEvaluator.evaluate(
				proposal: p,
				ranking: ranking,
				contextType: contextType,
				features: features
			)
			strength = s
			logSuggestionStrengthIfNeeded(s)
			if s.strength == .weak {
				proposal = nil
			}
		}

		var proposalKey: String?
		if let p = proposal {
			proposalKey = "\(packet.triggerType.rawValue)|\(p.primaryActionId)|\(Self.proposalContentStamp(profile))"
		}

		var evalContext = context
		evalContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		let mapped = actionRouter.matchingActions(for: packet).filter { $0.canExecute(context: evalContext) }
		let orderedIds = overriddenDecision.rankedActionIds.isEmpty ? decision.rankedActionIds : overriddenDecision.rankedActionIds
		let indexById = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) })
		var ordered = mapped.sorted { a, b in
			let ia = indexById[a.id] ?? Int.max
			let ib = indexById[b.id] ?? Int.max
			if ia != ib { return ia < ib }
			return a.id < b.id
		}

		// Phase 14.5: context-aware action eligibility (metadata-only; no new collection).
		let eligibility = ContextAwareActionEligibility.evaluate(
			currentCandidateActionIds: ordered.map(\.id),
			triggerType: packet.triggerType,
			context: context,
			contextType: contextType,
			features: features,
			fused: CanonicalContextState.shared.current()
		)
		if eligibility.reasonCodes.contains("no_rich_context") {
			print("[ActionEligibility] kept reason=no_rich_context")
		} else if eligibility.reasonCodes.contains("rich_context_ignored_stale") {
			print("[ActionEligibility] ignored reason=rich_context_ignored_stale")
		} else if eligibility.reasonCodes.contains("form_actions_limited") {
			print("[ActionEligibility] limited reason=form_actions_limited")
		} else if let r = eligibility.reasonCodes.first, r != "no_rich_adjustment" {
			let actionsLabel = eligibility.eligibleActionIds.joined(separator: ",")
			print("[ActionEligibility] adjusted reason=\(r) actions=\(actionsLabel)")
		}

		let eligibleSet = Set(eligibility.eligibleActionIds)
		ordered = ordered.filter { eligibleSet.contains($0.id) }
		let indexByEligible = Dictionary(uniqueKeysWithValues: eligibility.eligibleActionIds.enumerated().map { ($0.element, $0.offset) })
		ordered.sort { a, b in
			let ia = indexByEligible[a.id] ?? Int.max
			let ib = indexByEligible[b.id] ?? Int.max
			if ia != ib { return ia < ib }
			return a.id < b.id
		}
		ordered = mergeActions(primary: deterministicPanel.actions, secondary: ordered)

		let didHaveAnalyze = lastReasonedActions.contains(where: { $0.id == ScreenAnalyzeAction.analyzeScreenId })
		let hasAnalyzeNow = ordered.contains(where: { $0.id == ScreenAnalyzeAction.analyzeScreenId })
		if hasAnalyzeNow && !didHaveAnalyze {
			if packet.triggerType == .manualInvocation, context.lastSourceTrigger == .manualTriggerRequested {
				print("[AvailableActions] added analyze_screen reason=manual_affordance")
			} else {
				print("[AvailableActions] added analyze_screen from OCR")
			}
		}

		var finalProposal: ActionProposal? = proposal
		var finalProposalKey: String? = proposalKey

		if ordered.isEmpty {
			finalProposal = nil
			finalProposalKey = nil
		} else if let p = finalProposal {
			let primaryInActions = ordered.contains(where: { $0.id == p.primaryActionId })
			if !primaryInActions {
				finalProposal = nil
				finalProposalKey = nil
			} else if appState.isSuggestionOnCooldown(p, context: context) {
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		if ordered.isEmpty {
			finalProposal = nil
			finalProposalKey = nil
		} else if let p = finalProposal {
			let primaryInActions = ordered.contains(where: { $0.id == p.primaryActionId })
			if !primaryInActions {
				finalProposal = nil
				finalProposalKey = nil
			} else if appState.isSuggestionOnCooldown(p, context: context) {
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		if packet.triggerType != .manualInvocation, let key = finalProposalKey {
			if let dismissedAt = appState.lastDismissedProposalAt,
			   appState.lastDismissedProposalKey == key,
			   Date().timeIntervalSince(dismissedAt) < 120 {
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=dismissed")
				finalProposal = nil
				finalProposalKey = nil
			} else if let acceptedAt = appState.lastAcceptedProposalAt,
					  appState.lastAcceptedProposalKey == key,
					  Date().timeIntervalSince(acceptedAt) < 10 {
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=accepted")
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		guard generation == contextPipelineGeneration else { return }

		let proposalSnapshot = buildCanonicalSnapshotForProposalActivation(
			context: context,
			fused: canonical
		)
		// Feed latest snapshot to hook sandbox (debug only — no production side-effects).
		appState.updateLatestCanonicalSnapshot(proposalSnapshot)
		let activationHistory = GeneratedExecutionProposalActivationHistory.fromAppState(
			lastDismissedProposalActionId: appState.lastDismissedProposalActionId,
			lastDismissedProposalAt: appState.lastDismissedProposalAt
		)
		let proposalHistory = ProposalHistoryMetadata.fromActivationHistory(activationHistory)

		// Phase B.1.8 — Startup quiet period for heavy inference.
		if packet.triggerType != .manualInvocation, ModelManager.shared.isWithinStartupQuietPeriod() {
			let elapsed = ModelManager.shared.secondsSinceLaunch() ?? 0
			print("[StartupBudget] heavy_inference_deferred reason=startup_quiet_period elapsed_s=\(elapsed)")
			// Continue with no dynamic proposals during quiet period.
			return
		}

		let llmResult = await DynamicGeneratedProposalEngine.shared.generateProposals(
			snapshot: proposalSnapshot,
			existingStaticActions: ordered.map(\.id),
			reusableActions: [],
			budget: .conservative,
			history: proposalHistory,
			isActionExecuting: appState.isActionExecuting,
			isWarmupReady: twoStageWarmupComplete
		)
		// T18.3.6B: Explicit pipeline trace — log engine result and library record count before activator.
		print("[ProposalPipeline] engine_result status=\(llmResult.status.rawValue) library_records=\(llmResult.libraryRecords.count) should_chime=\(llmResult.shouldChimeIn) reason=\(llmResult.reason)")
		if !llmResult.libraryRecords.isEmpty {
			let titles = llmResult.libraryRecords.prefix(3).map(\.title).joined(separator: "|")
			print("[ProposalPipeline] library_records_detail count=\(llmResult.libraryRecords.count) top_titles=\(titles)")
		}
		// T18.3.10B: Preserve effective workflow through activation/ranking.
		do {
			let wfEngine = WorkflowInferenceEngine.shared.latestResult()
			let mappedEngine = wfEngine.map { WorkflowExecutionMapper.workflowType(from: $0.workflow) } ?? .unknown
			let engineConf = wfEngine?.confidence ?? 0
			let snapMapped = WorkflowExecutionMapper.workflowType(from: proposalSnapshot.inferredWorkflow)
			let snapConf = proposalSnapshot.workflowConfidence
			let libBest = llmResult.libraryRecords
				.filter { $0.workflowType != .unknown }
				.max(by: { $0.usefulnessScore < $1.usefulnessScore })
			let (effective, source): (WorkflowType, String) = {
				if mappedEngine != .unknown, engineConf >= 0.35 { return (mappedEngine, "workflow_engine") }
				if snapMapped != .unknown, snapConf >= 0.35 { return (snapMapped, "canonical") }
				if let libBest { return (libBest.workflowType, "template_library") }
				return (.unknown, "fallback")
			}()
			print("[ProposalPipeline] effective_workflow=\(effective.rawValue) source=\(source)")
		}

		let llmCandidates = DynamicGeneratedProposalCandidateMapper.candidates(
			from: llmResult,
			snapshot: proposalSnapshot,
			budget: .conservative
		)
		// Cache executable generated execution actions for user-click execution (non-reusable).
		appState.cacheGeneratedExecutionCandidateActions(llmCandidates)
		// Cache hook-composed contracts so Prepare Execution can run the real hook chain.
		appState.cacheHookContracts(llmResult.hookContracts)

		let reusableCandidatesForLog = GeneratedExecutionProposalCandidateBuilder.buildReusable(
			from: llmResult.libraryRecords,
			referenceTime: Date()
		)
		print("[ProposalPipeline] candidates_pre_activation llm=\(llmCandidates.count) reusable=\(reusableCandidatesForLog.count) total=\(llmCandidates.count + reusableCandidatesForLog.count)")
		if reusableCandidatesForLog.isEmpty && !llmResult.libraryRecords.isEmpty {
			print("[ProposalPipeline] WARNING reusable_candidates_empty despite library_records=\(llmResult.libraryRecords.count) — check eligibility/expiry filters in buildReusable")
		}

		let activation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: ordered.map(\.id),
				staticRelevanceScores: workflowRank.adjustedScores,
				generatedActions: [],
				generatedExecutionCandidates: llmCandidates,
				reusableRecords: llmResult.libraryRecords,
				snapshot: proposalSnapshot,
				history: activationHistory,
				workflow: WorkflowInferenceEngine.shared.latestResult(),
				session: ContextualSessionTracker.shared.currentState(),
				isManualInvocation: packet.triggerType == .manualInvocation,
				isActionExecuting: appState.isActionExecuting,
				useLLMGeneratedCandidatesOnly: true
			)
		)
		// T18.3.6B: Explicit activation trace.
		print("[ProposalPipeline] activation_result visible_generated=\(activation.visibleProposals.count) suppressed_generated=\(activation.suppressedGeneratedCount) timing=\(activation.timingDecision.outcome.rawValue) allows_panel=\(activation.timingDecision.allowsPanelGenerated)")

		let visibleStaticSet = Set(activation.visibleStaticActionIds)
		var panelStaticActions = ordered.filter { visibleStaticSet.contains($0.id) }
		if panelStaticActions.isEmpty {
			panelStaticActions = ordered
		}

		var publishedProposal = finalProposal
		var publishedProposalKey = finalProposalKey
		if publishedProposal == nil,
		   activation.timingDecision.allowsFloatingGenerated,
		   let floatingId = activation.floatingGeneratedProposalId,
		   let topGenerated = activation.visibleProposals.first
		{
			let question = topGenerated.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let headline: String
			if question.hasSuffix("?"), question.count <= 110 {
				headline = question
			} else {
				headline = "Try: \(topGenerated.title)?"
			}
			publishedProposal = ActionProposal(
				title: headline,
				sourceCaption: "Generated proposal",
				primaryActionId: floatingId,
				secondaryActionIds: [],
				confidence: topGenerated.confidence,
				reason: "generated_execution_proposal"
			)
			publishedProposalKey = "\(packet.triggerType.rawValue)|\(floatingId)|generated"
		}

		// T18.5: Apply chime-in policy before publishing (static-path).
		let chimeFilteredActivationStatic = applyChimeInPolicy(to: activation, packet: packet, snapshot: proposalSnapshot)
		if !chimeFilteredActivationStatic.timingDecision.allowsFloatingGenerated,
		   publishedProposal?.reason == "generated_execution_proposal"
		{
			publishedProposal = nil
			publishedProposalKey = nil
		}

		publishReasonedActions(
			ordered: panelStaticActions,
			finalProposal: publishedProposal,
			finalProposalKey: publishedProposalKey,
			strength: strength,
			packet: packet,
			context: context,
			generation: generation,
			proposalGateAllows: proposalGateResult.shouldGenerate,
			generatedProposalActivation: chimeFilteredActivationStatic
		)

		// T12.6 / T12.6.5: async refinement (cache → micro → LLM) must not block heuristic publish above.
		if let fp = finalProposal,
		   let st = strength,
		   st.strength == .medium || st.strength == .strong,
		   proposalGateResult.shouldGenerate,
		   !ordered.isEmpty,
		   generation == contextPipelineGeneration
		{
			let llmIds = Self.llmCandidateActionIds(from: ordered)
			// T18.3.5A: DynamicOnlyProposalMode replaces the Phase-12 IntelligenceProposalSelector
			// pipeline entirely. When enabled, skip applyIntelligenceRefinement — the new
			// DynamicGeneratedProposalEngine (decision → template library) handles all LLM work.
			if !llmIds.isEmpty && !DynamicOnlyProposalMode.isEnabled {
				let gen = generation
				let snapOrdered = ordered
				let snapProposalKey = finalProposalKey
				Task { @MainActor in
					await self.applyIntelligenceRefinement(
						generation: gen,
						packet: packet,
						context: context,
						sourceText: sourceText,
						contextType: contextType,
						features: features,
						strengthResult: st,
						overriddenDecision: overriddenDecision,
						proposalGateAllowed: proposalGateResult.shouldGenerate,
						orderedSnapshot: snapOrdered,
						heuristicProposal: fp,
						heuristicProposalKey: snapProposalKey,
						contentProfile: profile,
						llmIds: llmIds
					)
				}
			}
		}
	}

	private func buildCanonicalSnapshotForProposalActivation(
		context: ContextModel,
		fused: FusedContextPacket?
	) -> CanonicalGeneratedExecutionContextSnapshot {
		let selectedText = ActionInputCapture.primaryText(
			for: context,
			minimumLength: 0,
			preference: .selectedText
		)
		var clipboardText = ActionInputCapture.primaryText(
			for: context,
			minimumLength: 0,
			preference: .clipboard
		)
		var snapshot = CanonicalGeneratedExecutionContextSnapshotExporter.export(
			model: context,
			fused: fused,
			selectedText: selectedText,
			clipboardText: clipboardText,
			workflow: WorkflowInferenceEngine.shared.latestResult(),
			intent: IntentSynthesisEngine.shared.latestResult(),
			session: ContextualSessionTracker.shared.currentState(),
			permissionAvailability: [
				.screenRecording: WindowSnapshotSource.shared.hasScreenRecordingPermission(),
				.clipboard: true,
				.accessibility: true,
			]
		)
		let suppression = GeneratedExecutionClipboardFreshnessPolicy.evaluate(snapshot: snapshot)
		if !suppression.includeClipboard {
			clipboardText = nil
			snapshot = CanonicalGeneratedExecutionContextSnapshotExporter.export(
				model: context,
				fused: fused,
				selectedText: selectedText,
				clipboardText: nil,
				workflow: WorkflowInferenceEngine.shared.latestResult(),
				intent: IntentSynthesisEngine.shared.latestResult(),
				session: ContextualSessionTracker.shared.currentState(),
				permissionAvailability: [
					.screenRecording: WindowSnapshotSource.shared.hasScreenRecordingPermission(),
					.clipboard: true,
					.accessibility: true,
				]
			)
		}
		return snapshot
	}

	/// T18.3.2 — generated proposals only; no static summarize/explain/rewrite fallbacks.
	private func updateDynamicOnlyProposals(
		from packet: TriggerPacket,
		context: ContextModel,
		generation: UInt64,
		decision: ReasoningDecision,
		pendingActionIntentRetry: ActionIntentPendingRequest? = nil
	) async {
		if AmbientMVPMode.isEnabled {
			var isBlocked = false
			let isVisible = await MainActor.run { appState.isFloatingSuggestionVisible }
			let currentFloat = await MainActor.run { appState.floatingSuggestion }
			
			if isVisible, let currentFloat = currentFloat {
				let id = currentFloat.primaryActionId
				let lastShownAt = await MainActor.run { appState.lastAmbientJarvisShownAt }
				let age = Date().timeIntervalSince(lastShownAt ?? Date.distantPast)
				let isStale = age > 30.0
				let isHighConfidence = currentFloat.confidence >= 0.65
				let wasLogged = await MainActor.run {
					appState.wasSuggestionFeedbackLogged(id: id, event: "ignored") ||
					appState.wasSuggestionFeedbackLogged(id: id, event: "auto_dismissed") ||
					appState.wasSuggestionFeedbackLogged(id: id, event: "dismissed")
				}
				if !isStale && isHighConfidence && !wasLogged {
					isBlocked = true
				}
			}
			
			if isBlocked {
				print("[ProposalRouting] suppressed reason=active_high_value_card")
				await MainActor.run {
					appState.clearActivatedGeneratedProposals(reason: "ambient_mvp_mode_enabled")
				}
				return
			} else {
				print("[ProposalRouting] not_suppressed_by_ambient reason=ambient_low_value_or_stale")
			}
		}
		// Phase 4S — Expire pending action-intent retry request if TTL elapsed.
		expirePendingActionIntentIfNeeded(now: Date())

		if LocalAISettings.shared.twoStageTaskInferenceEnabled && !twoStageWarmupComplete {
			print("[GeneratedProposal] attempt_started_before_warmup reason=allowing_lightweight_shell")
			// We no longer return early; we let the engine attempt a lightweight model-free shell.
		}

		guard generation == contextPipelineGeneration else {
			GeneratedProposalActivationDiagnostics.logSkip(
				phase: "skipped_before_situational_synthesis",
				detail: "stale_generation"
			)
			return
		}

		let canonical = CanonicalContextState.shared.current()
		let proposalSnapshot: CanonicalGeneratedExecutionContextSnapshot = {
			if let pendingActionIntentRetry {
				// Phase 4S — Pending action-intent retries must reuse the strong snapshot
				// that was deemed action-worthy, rather than rebuilding from potentially
				// transient current context (e.g. profile/account titles, missing OCR).
				return pendingActionIntentRetry.snapshot
			}
			return buildCanonicalSnapshotForProposalActivation(
				context: context,
				fused: canonical
			)
		}()
		// Feed latest snapshot to hook sandbox (debug only — no production side-effects).
		appState.updateLatestCanonicalSnapshot(proposalSnapshot)

		GeneratedProposalActivationDiagnostics.logAttemptStarted(
			triggerType: packet.triggerType.rawValue,
			fusedPacket: canonical != nil
		)

		let prepared: GeneratedProposalActivationBoundary.Prepared = {
			if let pendingActionIntentRetry {
				return GeneratedProposalActivationBoundary.Prepared(
					snapshot: pendingActionIntentRetry.snapshot,
					situational: pendingActionIntentRetry.situational
				)
			}
			return GeneratedProposalActivationBoundary.prepare(snapshot: proposalSnapshot)
		}()

		// Phase 4S — If warmup is not ready, a strong title can be eligible for
		// fast visibility (entity detection), but we must enqueue a retry so a real
		// action intent is generated once the planner/router are ready.
		if LocalAISettings.shared.twoStageTaskInferenceEnabled, !twoStageWarmupComplete {
			let title = prepared.situational.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let d = FastVisibilityQualityGate.evaluate(
				title: title,
				appName: prepared.situational.activeAppName,
				bundleIdentifier: prepared.snapshot.bundleIdentifier
			)
			if d.eligible {
				let fp = TaskInferenceEngine.fingerprint(
					snapshot: prepared.snapshot,
					situational: prepared.situational,
					recentTitles: [title]
				)
				storePendingActionIntentIfNeeded(
					packet: packet,
					context: context,
					snapshot: prepared.snapshot,
					situational: prepared.situational,
					generation: generation,
					fingerprint: fp,
					title: title,
					classification: d.classification
				)
			}
		}

		let activationHistory = GeneratedExecutionProposalActivationHistory.fromAppState(
			lastDismissedProposalActionId: appState.lastDismissedProposalActionId,
			lastDismissedProposalAt: appState.lastDismissedProposalAt
		)
		let proposalHistory = ProposalHistoryMetadata.fromActivationHistory(activationHistory)

		// Phase 4S — Deterministic bridge: if we are running a pending action-intent retry
		// that was stored from a fast-visibility `action_worthy` classification, ensure the
		// router cannot terminate the pipeline early with quiet / selection requests.
		let forcePlannerPendingRetry: Bool = {
			guard let pendingActionIntentRetry else { return false }
			guard pendingActionIntentRetry.classification == .actionWorthy else {
				print("[RouterOverride] applied=no reason=pending_action_intent_not_action_worthy")
				return false
			}
			let bundleNow = prepared.snapshot.bundleIdentifier?.lowercased() ?? ""
			let bundlePending = pendingActionIntentRetry.context.activeAppBundleIdentifier?.lowercased() ?? ""
			guard !bundleNow.isEmpty, !bundlePending.isEmpty, bundleNow == bundlePending else {
				print("[RouterOverride] applied=no reason=pending_action_intent_bundle_mismatch")
				return false
			}
			// Re-check eligibility using the stored strong title to avoid applying this to browser chrome.
			let d = FastVisibilityQualityGate.evaluate(
				title: pendingActionIntentRetry.title,
				appName: prepared.situational.activeAppName,
				bundleIdentifier: prepared.snapshot.bundleIdentifier
			)
			guard d.eligible, d.classification == .actionWorthy else {
				print("[RouterOverride] applied=no reason=pending_action_intent_not_action_worthy")
				return false
			}
			return true
		}()

		// Phase B.1.8 — Startup quiet period for heavy inference.
		if packet.triggerType != .manualInvocation, ModelManager.shared.isWithinStartupQuietPeriod() {
			let elapsed = ModelManager.shared.secondsSinceLaunch() ?? 0
			print("[StartupBudget] heavy_inference_deferred reason=startup_quiet_period elapsed_s=\(elapsed)")
			return
		}

		let rawLLMResult = await DynamicGeneratedProposalEngine.shared.generateProposals(
			snapshot: prepared.snapshot,
			existingStaticActions: [],
			reusableActions: [],
			budget: .conservative,
			history: proposalHistory,
			situational: prepared.situational,
			isActionExecuting: appState.isActionExecuting,
			isWarmupReady: twoStageWarmupComplete,
			forcePlannerFromPendingActionIntentRetry: forcePlannerPendingRetry
		)
		let llmResult = gateDynamicGeneratedResult(
			rawLLMResult,
			evidenceContext: dynamicGeneratedEvidenceContext(
				context: context,
				snapshot: prepared.snapshot,
				situational: prepared.situational
			)
		)
		// T18.3.6B: Explicit pipeline trace — log engine result and library record count before activator.
		print("[ProposalPipeline] engine_result status=\(llmResult.status.rawValue) library_records=\(llmResult.libraryRecords.count) should_chime=\(llmResult.shouldChimeIn) reason=\(llmResult.reason)")
		if !llmResult.libraryRecords.isEmpty {
			let titles = llmResult.libraryRecords.prefix(3).map(\.title).joined(separator: "|")
			print("[ProposalPipeline] library_records_detail count=\(llmResult.libraryRecords.count) top_titles=\(titles)")
		}
		// T18.3.10B: Preserve effective workflow through activation/ranking.
		do {
			let situationalMapped = WorkflowExecutionMapper.workflowType(from: prepared.situational.inferredWorkflow)
			let situationalConf = prepared.situational.workflowConfidence
			let wfEngine = WorkflowInferenceEngine.shared.latestResult()
			let mappedEngine = wfEngine.map { WorkflowExecutionMapper.workflowType(from: $0.workflow) } ?? .unknown
			let engineConf = wfEngine?.confidence ?? 0
			let snapMapped = WorkflowExecutionMapper.workflowType(from: prepared.snapshot.inferredWorkflow)
			let snapConf = prepared.snapshot.workflowConfidence
			let libBest = llmResult.libraryRecords
				.filter { $0.workflowType != .unknown }
				.max(by: { $0.usefulnessScore < $1.usefulnessScore })
			let (effective, source): (WorkflowType, String) = {
				if situationalMapped != .unknown, situationalConf >= 0.35 { return (situationalMapped, "situational") }
				if mappedEngine != .unknown, engineConf >= 0.35 { return (mappedEngine, "workflow_engine") }
				if snapMapped != .unknown, snapConf >= 0.35 { return (snapMapped, "canonical") }
				if let libBest { return (libBest.workflowType, "template_library") }
				return (.unknown, "fallback")
			}()
			print("[ProposalPipeline] effective_workflow=\(effective.rawValue) source=\(source)")
		}

		let llmCandidates = DynamicGeneratedProposalCandidateMapper.candidates(
			from: llmResult,
			snapshot: prepared.snapshot,
			budget: .conservative
		)
		// Cache executable generated execution actions for user-click execution (non-reusable).
		appState.cacheGeneratedExecutionCandidateActions(llmCandidates)
		// Cache hook-composed contracts so Prepare Execution can run the real hook chain.
		appState.cacheHookContracts(llmResult.hookContracts)

		let reusableCandidatesForLog2 = GeneratedExecutionProposalCandidateBuilder.buildReusable(
			from: llmResult.libraryRecords,
			referenceTime: Date()
		)
		print("[ProposalPipeline] candidates_pre_activation llm=\(llmCandidates.count) reusable=\(reusableCandidatesForLog2.count) total=\(llmCandidates.count + reusableCandidatesForLog2.count)")
		if reusableCandidatesForLog2.isEmpty && !llmResult.libraryRecords.isEmpty {
			print("[ProposalPipeline] WARNING reusable_candidates_empty despite library_records=\(llmResult.libraryRecords.count) — check eligibility/expiry filters in buildReusable")
		}

		let activation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [],
				staticRelevanceScores: [],
				generatedActions: [],
				generatedExecutionCandidates: llmCandidates,
				reusableRecords: llmResult.libraryRecords,
				snapshot: prepared.snapshot,
				history: activationHistory,
				workflow: WorkflowInferenceEngine.shared.latestResult(),
				session: ContextualSessionTracker.shared.currentState(),
				isManualInvocation: packet.triggerType == .manualInvocation,
				isActionExecuting: appState.isActionExecuting,
				useLLMGeneratedCandidatesOnly: true,
				suppressStaticProposalFallback: true
			)
		)
		// T18.3.6B: Explicit activation trace.
		print("[ProposalPipeline] activation_result visible_generated=\(activation.visibleProposals.count) suppressed_generated=\(activation.suppressedGeneratedCount) timing=\(activation.timingDecision.outcome.rawValue) allows_panel=\(activation.timingDecision.allowsPanelGenerated)")

		let debugStatus = GeneratedProposalDebugStatusBuilder.build(
			llmResult: llmResult,
			llmCandidates: llmCandidates,
			activation: activation,
			situational: prepared.situational
		)
		print("[GeneratedProposal] \(debugStatus.logLine)")
		print(debugStatus.pipelineStatusLine)
		GeneratedProposalActivationDiagnostics.logOutcome(
			llmResult: llmResult,
			candidateCount: llmCandidates.count,
			visibleCount: activation.visibleProposals.count,
			situational: prepared.situational
		)

		var publishedProposal: ActionProposal?
		var publishedProposalKey: String?
		if activation.timingDecision.allowsFloatingGenerated,
		   let floatingId = activation.floatingGeneratedProposalId,
		   let topGenerated = activation.visibleProposals.first
		{
			let question = topGenerated.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let headline: String
			if question.hasSuffix("?"), question.count <= 110 {
				headline = question
			} else {
				headline = "Try: \(topGenerated.title)?"
			}
			publishedProposal = ActionProposal(
				title: headline,
				sourceCaption: "Generated proposal",
				primaryActionId: floatingId,
				secondaryActionIds: [],
				confidence: topGenerated.confidence,
				reason: "generated_execution_proposal"
			)
			publishedProposalKey = "\(packet.triggerType.rawValue)|\(floatingId)|generated"
			print("[FloatingSuggestionDebug] proposal_constructed title=\"\(topGenerated.title.prefix(60))\" floatingId=\(floatingId.prefix(40))")
		} else {
			// Log which condition blocked construction for diagnosis.
			let blockReason: String = {
				if !activation.timingDecision.allowsFloatingGenerated {
					return "timing_blocks_floating outcome=\(activation.timingDecision.outcome.rawValue)"
				}
				if activation.floatingGeneratedProposalId == nil {
					return "floating_id_nil visible_count=\(activation.visibleProposals.count)"
				}
				return "no_visible_proposals"
			}()
			print("[FloatingSuggestionDebug] proposal_not_constructed reason=\(blockReason) panel_proposals=\(activation.visibleProposals.count)")
		}

		if packet.triggerType != .manualInvocation, let key = publishedProposalKey {
			if let dismissedAt = appState.lastDismissedProposalAt,
			   appState.lastDismissedProposalKey == key,
			   Date().timeIntervalSince(dismissedAt) < 120
			{
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=dismissed")
				publishedProposal = nil
				publishedProposalKey = nil
			} else if let acceptedAt = appState.lastAcceptedProposalAt,
					  appState.lastAcceptedProposalKey == key,
					  Date().timeIntervalSince(acceptedAt) < 10
			{
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=accepted")
				publishedProposal = nil
				publishedProposalKey = nil
			}
		}

		// T18.5: Apply chime-in policy before publishing.
		let chimeFilteredActivation = applyChimeInPolicy(to: activation, packet: packet, snapshot: proposalSnapshot)
		var chimeFilteredProposal: ActionProposal?
		var chimeFilteredProposalKey: String?
		if chimeFilteredActivation.timingDecision.allowsFloatingGenerated {
			chimeFilteredProposal = publishedProposal
			chimeFilteredProposalKey = publishedProposalKey
		} else if publishedProposal?.reason == "generated_execution_proposal" {
			print("[FloatingSuggestionDebug] proposal_chime_nulled chime_allows_float=no proposal_was=\(publishedProposal != nil ? "set" : "nil")")
			chimeFilteredProposal = nil
			chimeFilteredProposalKey = nil
		} else {
			chimeFilteredProposal = publishedProposal
			chimeFilteredProposalKey = publishedProposalKey
		}

		// Part B — Chime-driven floating fallback (T16.X).
		// If chime policy says floatingSuggestion but the activator's old gate blocked floatingId,
		// construct the proposal directly from the top visible panel proposal.
		// This eliminates the double-gate problem: chime policy is the single authority for floating.
		if chimeFilteredActivation.timingDecision.allowsFloatingGenerated,
		   chimeFilteredProposal == nil,
		   let topPanel = activation.visibleProposals.first
		{
			let chimeDrivenId = GeneratedExecutionProposalActivator.generatedProposalActionId(for: topPanel.id)
			chimeFilteredProposal = ActionProposal(
				title: "Try: \(topPanel.title)?",
				sourceCaption: "Generated proposal",
				primaryActionId: chimeDrivenId,
				secondaryActionIds: [],
				confidence: topPanel.confidence,
				reason: "generated_execution_proposal"
			)
			chimeFilteredProposalKey = "\(packet.triggerType.rawValue)|\(chimeDrivenId)|generated"
			print("[FloatingSuggestionDebug] proposal_constructed reason=chime_policy_floating title=\"\(topPanel.title.prefix(60))\"")
		}

		print("[FloatingSuggestionDebug] chime_result allows_float=\(chimeFilteredActivation.timingDecision.allowsFloatingGenerated) proposal_survives=\(chimeFilteredProposal != nil)")

		let deterministicPanel = buildDeterministicPanelPublication(context: context)

		// Phase 43 — Proactively surface cognitive preparation action as a floating pill.
		if let cogAct = deterministicPanel.cognitiveFloatingAction {
			maybeShowCognitiveFloatingSuggestion(panelAction: cogAct, context: context)
		}

		let toolActions = registeredToolActions(for: packet, context: context)
		publishDynamicOnlyReasonedActions(
			panelActions: deterministicPanel.actions,
			toolActions: toolActions,
			finalProposal: chimeFilteredProposal,
			finalProposalKey: chimeFilteredProposalKey,
			packet: packet,
			context: context,
			generation: generation,
			generatedProposalActivation: chimeFilteredActivation,
			debugStatus: debugStatus,
			decision: decision
		)
	}

	// MARK: - T18.5 — Chime-in policy

	/// Applies `ContextualChimeInPolicy` to the activation result (T18.5 + T18.6 + T18.6A).
	///
	/// T18.6A: Proposal novelty is now keyed on the full context fingerprint —
	/// bundle ID + window title prefix + workflow + OCR/text availability.
	/// This means the same template on different Reddit/YouTube pages has fully independent
	/// novelty entries (fresh on each page), while the same page+template decays normally.
	///
	/// Context changes are detected by comparing fingerprint components and logged explicitly.
	/// The interruption cost is derived from context-staleness so same-page repeats stay
	/// panel-only (no floating) while different-page proposals can float again.
	private func applyChimeInPolicy(
		to activation: GeneratedExecutionProposalActivationResult,
		packet: TriggerPacket,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> GeneratedExecutionProposalActivationResult {
		guard !activation.visibleProposals.isEmpty else {
			// Nothing to filter — still publish empty visibility state.
			let emptyState = ProposalVisibilityState(
				generatedCount: 0,
				visibleCount: 0,
				suppressedCount: activation.suppressedGeneratedCount,
				suppressionReasons: ["no_candidates"],
				lastDecision: "suppress",
				lastNoveltyScore: nil,
				updatedAt: Date()
			)
			appState.applyProposalVisibilityState(emptyState)
			return activation
		}

		let now = Date()
		let workflow = WorkflowInferenceEngine.shared.latestResult()
		let wfType = workflow.map { WorkflowExecutionMapper.workflowType(from: $0.workflow) } ?? .unknown
		let wfConf = workflow.map { min(1.0, max(0.0, $0.confidence)) } ?? 0

		let hasSelectedText = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasOCR = !(snapshot.recentOCRExcerpt ?? "").isEmpty
		let hasRichContext = hasSelectedText || hasOCR
		let topScore = activation.visibleProposals.first?.rankScore ?? 0
		let isManual = packet.triggerType == .manualInvocation

		// T18.6A — Full context fingerprint.
		// Uses bundle ID (stable across page loads), window title prefix (changes with page),
		// workflow, and source-availability flags. Same template → different page = different key.
		let bundle = snapshot.bundleIdentifier ?? String(snapshot.activeApp.lowercased().prefix(20))
		let titlePrefix = String(snapshot.windowTitle.prefix(40))
		let currentCtx = ChimeInContextSnapshot(
			bundle: bundle,
			titlePrefix: titlePrefix,
			workflow: wfType.rawValue,
			hasOCR: hasOCR,
			hasSelectedText: hasSelectedText
		)

		// Detect and log meaningful context changes.
		let contextChanged: Bool
		if let prev = lastChimeInContext, prev != currentCtx {
			contextChanged = true
			var changeReasons: [String] = []
			if prev.titlePrefix != currentCtx.titlePrefix { changeReasons.append("title_changed") }
			if prev.bundle != currentCtx.bundle       { changeReasons.append("app_changed") }
			if prev.workflow != currentCtx.workflow   { changeReasons.append("workflow_changed") }
			if prev.hasOCR != currentCtx.hasOCR       { changeReasons.append("ocr_changed") }
			if prev.hasSelectedText != currentCtx.hasSelectedText { changeReasons.append("selection_changed") }
			print("[ChimeInPolicy] context_changed=yes novelty_reset=yes reason=\(changeReasons.joined(separator: "|"))")
		} else {
			contextChanged = lastChimeInContext == nil // first call ever is not a "change"
		}
		lastChimeInContext = currentCtx

		// Build context-aware novelty key.
		// Format: "<templateId>|<bundle>|<titlePrefix>|<workflow>|<ocrFlag><textFlag>"
		// Same template, same page → same key (decays with repetition).
		// Same template, different page → different key (fresh novelty).
		let topId = activation.visibleProposals.first?.id ?? ""
		let ocrTextFlags = "\(hasOCR ? "1" : "0")\(hasSelectedText ? "1" : "0")"
		let contextualNoveltyKey = "\(topId)|\(bundle)|\(titlePrefix)|\(wfType.rawValue)|\(ocrTextFlags)"
		let novelty = ProposalNoveltyTracker.shared.noveltyScore(for: contextualNoveltyKey)

		// T18.6A — Derive interruption cost from context-staleness.
		// Same page + degraded novelty → higher cost (forces panel-only, no floating).
		// Context changed / fresh novelty → low cost (floating eligible).
		let derivedInterruptionCost: Double
		if !contextChanged && novelty < 0.60 {
			// Same page, already seen — calm: panel-only only, no floating interruption.
			derivedInterruptionCost = 0.55
		} else if contextChanged && novelty >= 0.70 {
			// Fresh context — low interruption cost, floating eligible.
			derivedInterruptionCost = 0.20
		} else {
			derivedInterruptionCost = 0.30
		}

		// Recent dismissal / accept intervals.
		let dismissalAge = appState.lastDismissedProposalAt.map { now.timeIntervalSince($0) }
		let acceptAge = appState.lastAcceptedProposalAt.map { now.timeIntervalSince($0) }

		let factors = ContextualChimeInFactors(
			isManualInvocation: isManual,
			workflowType: wfType,
			workflowConfidence: wfConf,
			hasRichContext: hasRichContext,
			proposalCount: activation.visibleProposals.count,
			topProposalScore: topScore,
			topInterruptionCost: derivedInterruptionCost,
			recentDismissalInSeconds: dismissalAge,
			recentAcceptInSeconds: acceptAge,
			noveltyScore: novelty,
			isActionExecuting: appState.isActionExecuting,
			isContextStale: snapshot.packetIsStale,
			visualContextWasRecentlyEnriched: false
		)

		var decision = ContextualChimeInPolicy.evaluate(factors: factors)

		// Decision quality log — explains utility, novelty, and interruption cost together.
		print("[ChimeInPolicy] decision_quality score=\(String(format: "%.2f", decision.score)) utility=\(String(format: "%.2f", topScore)) novelty=\(String(format: "%.2f", novelty)) interruption=\(String(format: "%.2f", derivedInterruptionCost)) context=\(contextChanged ? "changed" : "same") mode=\(decision.mode.rawValue)")

		// Executable hook-contract override (Task 1 dogfood visibility):
		// When ChimeInPolicy suppresses a proposal that is an executable hook-composer contract
		// with confidence ≥ 0.70, force panel-only display. Floating remains gated normally.
		// This allows generated hook proposals to appear in the dogfood panel even when the
		// unified ranking score is in the 0.35–0.45 range.
		if !decision.shouldSurface && !factors.isActionExecuting {
			let hasHookContract = activation.visibleProposals.contains {
				$0.source == .hookComposer &&
				$0.isExecutableGeneratedProposal &&
				$0.confidence >= GeneratedExecutionProposalActivator.executableHookContractPanelMinConfidence
			}
			if hasHookContract {
				print("[ChimeInPolicy] panel_override reason=executable_hook_contract score=\(String(format: "%.2f", topScore))")
				decision = ContextualChimeInDecision(
					mode: .panelOnly,
					score: max(decision.score, 0.50),
					reasons: ["executable_hook_contract"],
					cooldownRecommendation: nil
				)
			}
		}

		// Executable float bypass: first-time appearance of an executable hook contract with
		// full novelty (1.0) gets a floating suggestion regardless of the score gate.
		// Dismissal hard-suppresses are already applied upstream (factors.recentDismissalInSeconds
		// triggers suppress < 60s, which cascades into the panel override above).
		// We only promote to floating here — never demote an already-floating decision.
		if decision.mode != .floatingSuggestion,
		   !factors.isActionExecuting,
		   factors.noveltyScore >= 1.0,
		   factors.recentDismissalInSeconds.map({ $0 >= 60 }) ?? true,
		   let topItem = activation.visibleProposals.first,
		   topItem.isExecutableGeneratedProposal,
		   topItem.confidence >= 0.55
		{
			print("[ChimeInPolicy] executable_float_override confidence=\(String(format: "%.2f", topItem.confidence)) novelty=\(String(format: "%.2f", factors.noveltyScore))")
			decision = ContextualChimeInDecision(
				mode: .floatingSuggestion,
				score: max(decision.score, topItem.confidence),
				reasons: decision.reasons + ["executable_float_override"],
				cooldownRecommendation: nil
			)
		}

		// Resurfacing guarantee (T18.6): if silent ≥3 min and score is passable, allow panel-only.
		let wasFullySuppressed = !decision.shouldSurface
		if wasFullySuppressed && !factors.isActionExecuting {
			let lastVisible = appState.lastVisibleProposalAt ?? .distantPast
			let silenceDuration = now.timeIntervalSince(lastVisible)
			if silenceDuration >= 180 && topScore >= 0.38 {
				print("[ChimeInPolicy] resurfacing_guarantee triggered silence=\(Int(silenceDuration))s score=\(String(format: "%.2f", topScore)) original_reason=\(decision.reasons.first ?? "unknown")")
				decision = ContextualChimeInDecision(
					mode: .panelOnly,
					score: topScore,
					reasons: ["resurfacing_guarantee"],
					cooldownRecommendation: nil
				)
			} else {
				print("[ChimeInPolicy] suppressed helpful proposal silence=\(Int(silenceDuration))s reason=\(decision.reasons.first ?? "policy") novelty=\(String(format: "%.2f", novelty))")
			}
		}

		// Build visibility state for debug UI and pipeline log.
		let totalGenerated = activation.visibleProposals.count + activation.suppressedGeneratedCount
		let visibleAfterPolicy = decision.shouldSurface ? activation.visibleProposals.count : 0
		let suppressedByPolicy = decision.shouldSurface ? 0 : activation.visibleProposals.count
		let visibilityState = ProposalVisibilityState(
			generatedCount: totalGenerated,
			visibleCount: visibleAfterPolicy,
			suppressedCount: activation.suppressedGeneratedCount + suppressedByPolicy,
			suppressionReasons: decision.reasons,
			lastDecision: decision.mode.rawValue,
			lastNoveltyScore: novelty,
			updatedAt: now
		)
		appState.applyProposalVisibilityState(visibilityState)
		print("[ProposalPipeline] \(visibilityState.pipelineLogLine)")

		if !decision.shouldSurface {
			return GeneratedExecutionProposalActivationResult(
				visibleProposals: activation.visibleProposals,
				visibleStaticActionIds: activation.visibleStaticActionIds,
				suppressedGeneratedCount: activation.suppressedGeneratedCount + activation.visibleProposals.count,
				suppressedStaticCount: activation.suppressedStaticCount,
				topSourceType: activation.topSourceType,
				rankingSummary: "chime_suppressed:\(decision.reasons.first ?? "policy")",
				timingDecision: .suppressAll,
				warnings: activation.warnings + ["chime_policy_suppressed"],
				createdAt: activation.createdAt,
				floatingGeneratedProposalId: nil,
				isPolicySuppressed: true
			)
		}

		// Record visible proposals in novelty tracker using full context-aware key.
		for item in activation.visibleProposals.prefix(3) {
			let itemKey = "\(item.id)|\(bundle)|\(titlePrefix)|\(wfType.rawValue)|\(ocrTextFlags)"
			ProposalNoveltyTracker.shared.record(signature: itemKey)
		}

		// Task 3 — GeneratedProposalFloat eligibility log.
		// Computed after all policy gates so it reflects the final surfacing decision.
		let floatEligible = decision.mode == .floatingSuggestion
		let topConfidence = activation.visibleProposals.first?.confidence ?? 0
		let isExecutable   = activation.visibleProposals.first?.isExecutableGeneratedProposal ?? false
		
		let finalTiming: GeneratedExecutionProposalTimingDecision = {
			if decision.mode == .floatingSuggestion {
				return GeneratedExecutionProposalTimingDecision(
					outcome: .allowFloating,
					reason: "chime_floating",
					allowsFloatingGenerated: true,
					allowsPanelGenerated: true
				)
			} else if decision.mode == .panelOnly {
				return GeneratedExecutionProposalTimingDecision(
					outcome: .allowPanel,
					reason: "chime_panel_only",
					allowsFloatingGenerated: false,
					allowsPanelGenerated: true
				)
			} else {
				return activation.timingDecision
			}
		}()

		let floatReason: String = {
			if finalTiming.allowsFloatingGenerated { return "passed_all_gates" }
			if factors.isActionExecuting   { return "action_executing" }
			if novelty < 0.60              { return "novelty_too_low" }
			if derivedInterruptionCost > 0.45 { return "interruption_cost_high" }
			if !hasRichContext             { return "insufficient_context" }
			return decision.reasons.first ?? "policy_suppressed"
		}()
		
		// 1. Fix contradictory logs: make floatEligible match finalTiming.allowsFloatingGenerated
		let finalFloatEligible = finalTiming.allowsFloatingGenerated
		print("[GeneratedProposalFloat] eligible=\(finalFloatEligible ? "yes" : "no") reason=\(floatReason) novelty=\(String(format: "%.2f", novelty)) utility=\(String(format: "%.2f", topScore)) confidence=\(String(format: "%.2f", topConfidence)) executable=\(isExecutable ? "yes" : "no")")

		// 2. Add deterministic [FloatingProposalGate] log
		let topItem = activation.visibleProposals.first
		let hasContract = topId.hasPrefix("hook:") ? (appState.cachedHookContract(candidateId: topId) != nil) : true
		let executableStatus = topItem?.isExecutableGeneratedProposal ?? false
		let allowsFloat = finalTiming.allowsFloatingGenerated
		let finalDecision = allowsFloat && topItem != nil
		print("[FloatingProposalGate] id=\(topId) contract=\(topId) exists=\(hasContract) executable=\(executableStatus) eligible=\(finalFloatEligible) allows_float=\(allowsFloat) final_decision=\(finalDecision)")

		// If panelOnly (policy decision or resurfacing guarantee), strip floating.
		if decision.mode == .panelOnly {
			return GeneratedExecutionProposalActivationResult(
				visibleProposals: activation.visibleProposals,
				visibleStaticActionIds: activation.visibleStaticActionIds,
				suppressedGeneratedCount: activation.suppressedGeneratedCount,
				suppressedStaticCount: activation.suppressedStaticCount,
				topSourceType: activation.topSourceType,
				rankingSummary: activation.rankingSummary,
				timingDecision: finalTiming,
				warnings: activation.warnings,
				createdAt: activation.createdAt,
				floatingGeneratedProposalId: nil,
				isPolicySuppressed: false
			)
		}

		return GeneratedExecutionProposalActivationResult(
			visibleProposals: activation.visibleProposals,
			visibleStaticActionIds: activation.visibleStaticActionIds,
			suppressedGeneratedCount: activation.suppressedGeneratedCount,
			suppressedStaticCount: activation.suppressedStaticCount,
			topSourceType: activation.topSourceType,
			rankingSummary: activation.rankingSummary,
			timingDecision: finalTiming,
			warnings: activation.warnings,
			createdAt: activation.createdAt,
			floatingGeneratedProposalId: activation.floatingGeneratedProposalId,
			isPolicySuppressed: false
		)
	}

	private func registeredToolActions(for packet: TriggerPacket, context: ContextModel) -> [any ActionProtocol] {
		var evalContext = context
		evalContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		return actionRouter.matchingActions(for: packet).filter { action in
			!DynamicOnlyProposalMode.isGenericStaticAction(action.id) && action.canExecute(context: evalContext)
		}
	}

	// MARK: - Phase 4S: stronger-context replacement signal

	/// Emit `[GeneratedProposalState] replacing reason=stronger_context_arrived`
	/// when a weak/generic proposal is being replaced by an action-worthy one.
	/// Quiet otherwise — the regular `[AvailableActions]` log already covers
	/// normal-quality replacements.
	private func emitProposalReplacementLogIfStrongerContextArrived(
		previous: ActionProposal?,
		next: ActionProposal?,
		appName: String
	) {
		guard let prev = previous, let nxt = next else { return }
		// Strip leading "Try: " / "?" wrappers used by the floating shell so the
		// gate sees the underlying proposal title.
		let prevTitle = Self.unwrapProposalTitle(prev.title)
		let nextTitle = Self.unwrapProposalTitle(nxt.title)
		guard prevTitle != nextTitle else { return }
		let prevWeak = FastVisibilityQualityGate.isWeakOrGeneric(title: prevTitle, appName: appName)
		let nextStrong = FastVisibilityQualityGate.isActionWorthy(title: nextTitle, appName: appName)
		guard prevWeak && nextStrong else { return }
		print("[GeneratedProposalState] replacing reason=stronger_context_arrived previous=\"\(prevTitle.prefix(60))\" next=\"\(nextTitle.prefix(60))\"")
	}

	private static func unwrapProposalTitle(_ raw: String) -> String {
		var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.hasPrefix("Try: ") { t = String(t.dropFirst("Try: ".count)) }
		if t.hasSuffix("?") { t = String(t.dropLast()) }
		return t.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// True when two strings share at least one substantive token (length ≥ 3,
	/// alphanumeric, not a stopword). Used by the execution-time stale-goal
	/// repair to skip repair when the cached goal already references the
	/// current page entity.
	private static func shareSignificantTokens(_ a: String, _ b: String) -> Bool {
		let stopwords: Set<String> = [
			"the", "and", "for", "with", "from", "your", "this", "that",
			"have", "are", "amazon", "page", "home", "low", "fast", "free",
			"shipping", "prices", "items", "millions", "deals",
		]
		func tokens(_ s: String) -> Set<String> {
			let lower = s.lowercased()
			let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
				.filter { $0.count >= 3 && !stopwords.contains($0) }
			return Set(parts)
		}
		return !tokens(a).intersection(tokens(b)).isEmpty
	}

	private struct DeterministicPanelPublication {
		let actions: [any ActionProtocol]
		let floatingCandidate: PortfolioCandidate?
		let panelCount: Int
		let suppressedCount: Int
		/// Phase 43 — The panel action for the cognitive floating candidate (if any).
		/// Set when a cognitive action is eligible to float and has a real executor.
		/// The action is also included in `actions` so clicking the floating pill can resolve it.
		let cognitiveFloatingAction: DeterministicCapabilityPanelAction?
	}

	private struct DynamicGeneratedEvidenceContext {
		let evidenceQuality: String
		let browserAssessment: BrowserContextAssessment?
	}

	private func buildDeterministicPanelPublication(context: ContextModel) -> DeterministicPanelPublication {
		let frontmost = NSWorkspace.shared.frontmostApplication
		let activeAppName = context.activeAppName ?? frontmost?.localizedName ?? ""
		let browserContext = BrowserContextExtractor.extract(
			appName: activeAppName,
			activeAppPID: frontmost?.processIdentifier
		)
		let currentURL = browserContext?.selectedURL?.absoluteString ?? browserContext?.currentURL?.absoluteString
		let tabTitles = Array(
			NSOrderedSet(
				array: ([browserContext?.selectedTitle].compactMap { $0 } + (browserContext?.recentTabTitles ?? []))
					.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			)
		) as? [String] ?? []
		let runtime = WorkspaceRuntimeInventoryProvider.snapshot()
		let visibleApps = Array(
			Set(
				([runtime.frontmostAppName] + runtime.visibleWindows.map(\.appName))
					.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			)
		).sorted()
		let workflow = WorkflowInferenceEngine.shared.latestResult()?.workflow.rawValue ?? "unknown"
		let hasDurablePattern = DurableMemory.shared.bestDurableWorkspacePattern(
			workflow: workflow,
			compartment: workflow,
			currentApps: Set(runtime.runningApps.map(\.appName))
		) != nil
		let browserAssessment = BrowserContextStrategy.assess(
			title: browserContext?.selectedTitle ?? context.activeWindowTitle,
			url: currentURL.flatMap(URL.init(string:)),
			tabTitles: tabTitles,
			hasAXText: false,
			hasOCR: false
		)
		let evidenceProfile = EvidenceQualityModel.evaluate(
			title: browserContext?.selectedTitle ?? context.activeWindowTitle,
			url: currentURL.flatMap(URL.init(string:)),
			tabTitles: tabTitles,
			hasAXText: false,
			hasOCR: false,
			hasSelectedText: false,
			semanticGrounding: false,
			durableCompartment: hasDurablePattern,
			browserAssessment: browserAssessment
		)
		let frictionSignals = FrictionEngine.shared.detectFriction()
		let plannerResult = DeterministicPanelActionPlanner.evaluate(
			DeterministicPanelPlannerInput(
				activeAppName: activeAppName,
				windowTitle: context.activeWindowTitle,
				browserAppName: browserContext?.appName,
				currentURL: currentURL,
				tabTitles: tabTitles,
				visibleApps: visibleApps,
				workflow: workflow,
				compartmentLabel: workflow,
				compartment: nil,
				evidenceLevel: evidenceProfile.level,
				browserAssessment: browserAssessment,
				hasDurablePattern: hasDurablePattern,
				frictionSignals: frictionSignals
			)
		)

		let mediaState = MediaStateSource.currentSnapshot()
		let isUserTyping = TypingActivitySource.shared.currentContext().isTypingActive
		let hasActiveSwitching = frictionSignals.contains {
			$0.type == .repeated_app_switching || $0.type == .repeated_tab_switching
		}
		let pattern = DurableMemory.shared.bestDurableWorkspacePattern(
			workflow: workflow,
			compartment: workflow,
			currentApps: Set(runtime.runningApps.map(\.appName))
		)
		let missing = pattern.map {
			DurableMemory.shared.missingCheck(pattern: $0, currentApps: Set(runtime.runningApps.map(\.appName)), currentURLs: runtime.currentURLs)
		}

		var panelActions: [any ActionProtocol] = []
		var floatingCandidates: [PortfolioCandidate] = []
		var suppressedCount = plannerResult.suppressedCount
		// Phase 43 — Track panel actions for cognitive floating candidates by capabilityId.
		// These are used to build the floating pill's primaryActionId so click → execute works.
		var cognitiveFloatingPanelActions: [String: DeterministicCapabilityPanelAction] = [:]
		// Phase 43 — Cognitive capabilities that can float proactively.
		let cognitiveCapabilityIDs: Set<String> = [
			"explicit_visible_capture_summary", "extract_action_items", "create_checklist",
			"summarize_visible_content", "rewrite_text", "improve_text", "draft_reply", "explain_context"
		]

		for candidate in plannerResult.validCandidates {
			let recentFeedback: String? = {
				if appState.wasSuggestionFeedbackLogged(id: candidate.candidate.capabilityId, event: "dismissed") { return "dismissed" }
				if appState.wasSuggestionFeedbackLogged(id: candidate.candidate.capabilityId, event: "ignored") { return "ignored" }
				if appState.wasSuggestionFeedbackLogged(id: candidate.candidate.capabilityId, event: "accepted") { return "accepted" }
				return nil
			}()
			let evaluation = SuggestionSurfacePolicy.evaluate(
				capabilityId: candidate.candidate.capabilityId,
				context: context,
				isMusicPlaying: mediaState.isMusicPlaying,
				isMusicSuppressed: mediaState.isMusicPlaying,
				isUserTyping: isUserTyping,
				missing: missing,
				recentFeedback: recentFeedback,
				frictionSignals: frictionSignals,
				hasDurablePattern: hasDurablePattern,
				involvedURLs: candidate.involvedURLs,
				userAcceptedMusicBefore: DurableMemory.shared.hasAcceptedMusicPreference(),
				isLayoutAlreadyGood: !hasActiveSwitching
			)
			let capId = candidate.candidate.capabilityId
			let family = candidate.candidate.family.rawValue
			print("[PanelBridge] input capability=\(capId) family=\(family) surface=\(evaluation.surface.rawValue) allowed=\(evaluation.surface != .suppressed ? "yes" : "no")")
			switch evaluation.surface {
			case .suppressed:
				suppressedCount += 1
				print("[PanelBridge] dropped capability=\(capId) reason=\(evaluation.reason)")
				print("[SurfaceResult] capability=\(capId) requested=panel_only actual=suppressed reason=\(evaluation.reason)")
			case .panelOnly:
				// Phase 42 — Executor availability gate: never surface actions that will fail.
				let registeredCapability = CognitiveCapabilityRegistry.shared.get(capId)
				let executorAvailable = registeredCapability != nil && registeredCapability?.executionMode == .local_action
				print("[ExecutorAvailability] capability=\(capId) available=\(executorAvailable ? "yes" : "no") executor=\(registeredCapability != nil ? "registered" : "missing") reason=\(executorAvailable ? "local_action_executor" : registeredCapability == nil ? "not_in_registry" : "preview_only_not_real")")
				guard executorAvailable else {
					suppressedCount += 1
					print("[PanelAction] hidden capability=\(capId) reason=executor_unavailable")
					print("[PanelBridge] dropped capability=\(capId) reason=executor_unavailable")
					break
				}
				let seed = DeterministicCapabilityActionSeed(
					candidateID: candidate.candidate.candidateID,
					proposalID: "panel:\(candidate.candidate.candidateID)",
					capabilityId: capId,
					title: candidate.candidate.title,
					involvedApps: candidate.involvedApps,
					involvedURLs: candidate.involvedURLs,
					browserTabTitles: candidate.browserTabTitles,
					browserAppName: candidate.browserAppName,
					workflow: candidate.workflow,
					compartmentLabel: candidate.compartmentLabel,
					windowTitle: candidate.windowTitle,
					entity: candidate.entity,
					compartment: candidate.compartment,
					targetContract: candidate.targetContract
				)
				let panelAction = DeterministicCapabilityPanelAction(seed: seed)
				panelActions.append(panelAction)
				print("[PanelBridge] kept capability=\(capId) reason=panel_eligible")
				print("[PanelFallback] stored proposal_id=\(panelAction.proposalID) candidate_id=\(panelAction.candidateID) contract_id=\(panelAction.contractID ?? "missing")")
				print("[SurfaceResult] capability=\(capId) requested=panel_only actual=panel_added reason=\(evaluation.reason)")
				print("[PanelAction] added capability=\(capId) reason=\(evaluation.reason)")
			case .floatingInterrupt:
				floatingCandidates.append(candidate.candidate)
				// Phase 43 — Cognitive actions go to BOTH panel (for click resolution) and floating (for popup).
				// Non-cognitive floating (e.g. arrange_side_by_side) does NOT go to panel from this path.
				if cognitiveCapabilityIDs.contains(capId) {
					let floatSeed = DeterministicCapabilityActionSeed(
						candidateID: candidate.candidate.candidateID,
						proposalID: "cognitive:\(candidate.candidate.candidateID)",
						capabilityId: capId,
						title: candidate.candidate.title,
						involvedApps: candidate.involvedApps,
						involvedURLs: candidate.involvedURLs,
						browserTabTitles: candidate.browserTabTitles,
						browserAppName: candidate.browserAppName,
						workflow: candidate.workflow,
						compartmentLabel: candidate.compartmentLabel,
						windowTitle: candidate.windowTitle,
						entity: candidate.entity,
						compartment: candidate.compartment,
						targetContract: nil  // cognitive actions have no layout contract
					)
					let cognitiveAction = DeterministicCapabilityPanelAction(seed: floatSeed)
					panelActions.append(cognitiveAction)
					cognitiveFloatingPanelActions[capId] = cognitiveAction
					print("[PanelBridge] kept capability=\(capId) reason=cognitive_float_also_in_panel")
					print("[SurfaceResult] capability=\(capId) requested=floating actual=shown_and_in_panel reason=\(evaluation.reason)")
				} else {
					print("[PanelBridge] dropped capability=\(capId) reason=routed_to_floating")
					print("[SurfaceResult] capability=\(capId) requested=floating actual=shown reason=\(evaluation.reason)")
				}
			}
		}

		// Phase 40 — Add music candidate to the panel when not already playing.
		// The planner does not generate music (it has no media state); we inject it here
		// where MediaStateSource is already available, then let SuggestionSurfacePolicy
		// decide the surface (panelOnly vs floatingInterrupt vs suppressed).
		if !mediaState.isMusicPlaying && !isUserTyping {
			let musicRecentFeedback: String? = {
				if appState.wasSuggestionFeedbackLogged(id: "play_focus_media", event: "dismissed") { return "dismissed" }
				if appState.wasSuggestionFeedbackLogged(id: "play_focus_media", event: "ignored") { return "ignored" }
				if appState.wasSuggestionFeedbackLogged(id: "play_focus_media", event: "accepted") { return "accepted" }
				return nil
			}()
			let musicMemCtx = DurableMemoryContext.build(
				workflow: workflow,
				compartment: nil,
				app: activeAppName,
				activity: "active",
				browserType: browserContext?.appName
			)
			let musicSuppressed = DurableMemory.shared.shouldSuppressMusicSuggestion(
				context: musicMemCtx,
				isPlaying: false
			) != nil
			let musicEval = SuggestionSurfacePolicy.evaluate(
				capabilityId: "play_focus_media",
				context: context,
				isMusicPlaying: false,
				isMusicSuppressed: musicSuppressed,
				isUserTyping: isUserTyping,
				missing: missing,
				recentFeedback: musicRecentFeedback,
				frictionSignals: frictionSignals,
				hasDurablePattern: hasDurablePattern,
				involvedURLs: [],
				userAcceptedMusicBefore: DurableMemory.shared.hasAcceptedMusicPreference(),
				isLayoutAlreadyGood: !hasActiveSwitching
			)
			switch musicEval.surface {
			case .suppressed:
				suppressedCount += 1
				print("[SurfaceResult] capability=play_focus_media requested=panel actual=suppressed reason=\(musicEval.reason)")
			case .panelOnly:
				let musicSeed = DeterministicCapabilityActionSeed(
					candidateID: "play_focus_media|panel|music",
					proposalID: "panel:play_focus_media:music",
					capabilityId: "play_focus_media",
					title: "Start your focus music?",
					involvedApps: [],
					involvedURLs: [],
					browserTabTitles: [],
					browserAppName: nil,
					workflow: workflow,
					compartmentLabel: nil,
					windowTitle: context.activeWindowTitle,
					entity: nil,
					compartment: nil,
					targetContract: nil
				)
				let musicAction = DeterministicCapabilityPanelAction(seed: musicSeed)
				panelActions.append(musicAction)
				print("[MusicSuggestion] generated capability=play_focus_media reason=stable_work_context")
				print("[SurfaceResult] capability=play_focus_media requested=panel actual=panel_added reason=\(musicEval.reason)")
				print("[PanelAction] added capability=play_focus_media family=media reason=\(musicEval.reason)")
			case .floatingInterrupt:
				let musicCandidate = PortfolioCandidate(
					lane: .music,
					title: "Start your focus music?",
					capabilityId: "play_focus_media",
					executionMode: .local_action,
					confidence: 0.70,
					usefulness: 0.52,
					executability: 0.90,
					novelty: 1.0,
					reason: "music_idle_context_match",
					requiredEvidence: "metadata_rich",
					requiresConfirmation: false,
					involvedApps: [],
					frictionOpportunity: nil,
					musicIntent: nil,
					generatedAction: nil,
					sourcePath: "deterministic_panel",
					targetContract: nil
				)
				floatingCandidates.append(musicCandidate)
				print("[MusicSuggestion] generated capability=play_focus_media reason=floating_interrupt")
				print("[SurfaceResult] capability=play_focus_media requested=floating actual=shown reason=\(musicEval.reason)")
			}
		}

		// Phase 41 — Selected text writing candidates
		if context.selectedTextAvailable && context.selectedTextLength >= 5 {
			let writingCaps: [(String, String)] = [
				("rewrite_text", "Rewrite selected text"),
				("explain_context", "Explain this"),
				("draft_reply", "Draft a reply")
			]
			for (capId, title) in writingCaps {
				let seed = DeterministicCapabilityActionSeed(
					candidateID: "\(capId)|panel|selected_text",
					proposalID: "panel:\(capId):selected_text",
					capabilityId: capId,
					title: title,
					involvedApps: [],
					involvedURLs: [],
					browserTabTitles: [],
					browserAppName: nil,
					workflow: workflow,
					compartmentLabel: nil,
					windowTitle: context.activeWindowTitle,
					entity: nil,
					compartment: nil,
					targetContract: nil
				)
				let panelAction = DeterministicCapabilityPanelAction(seed: seed)
				panelActions.append(panelAction)
				print("[SelectedTextLane] generated capability=\(capId) length=\(context.selectedTextLength)")
				print("[PanelAction] added capability=\(capId) family=writing reason=selected_text")
				print("[PanelBridge] kept capability=\(capId) reason=panel_eligible")
			}
		}

		let mergedActions = dedupeActions(panelActions)
		let floatingCandidate = floatingCandidates.sorted { $0.score > $1.score }.first

		// Phase 43 — Find the panel action for the winning cognitive floating candidate.
		let cognitiveFloatingAction: DeterministicCapabilityPanelAction? = {
			guard let fc = floatingCandidate, cognitiveCapabilityIDs.contains(fc.capabilityId) else { return nil }
			return cognitiveFloatingPanelActions[fc.capabilityId]
		}()

		// Phase 40 — Panel inventory log: per-family count for observability.
		let familyBuckets: [(String, [String])] = [
			("research", ["explicit_visible_capture_summary", "extract_action_items", "create_checklist", "summarize_visible_content"]),
			("friction",  ["arrange_side_by_side", "split_research_setup", "switch_to_paired_app"]),
			("media",     ["play_focus_media", "pause_media", "resume_focus_media"]),
			("metadata",  ["copy_current_url", "collect_references", "remember_workspace", "open_current_task_panel"]),
			("workspace", ["restore_workspace", "restore_research_tabs"]),
		]
		let panelCapabilityIDs: [String] = mergedActions.compactMap { ($0 as? DeterministicCapabilityPanelAction)?.capabilityId }
		for (family, caps) in familyBuckets {
			let count = panelCapabilityIDs.filter { caps.contains($0) }.count
			if count > 0 {
				print("[PanelInventory] family=\(family) count=\(count)")
			}
		}
		print("[PanelInventory] shown_total=\(mergedActions.count) suppressed_total=\(suppressedCount)")
		let panelCapabilityList = panelCapabilityIDs.joined(separator: ",")

		// Phase 43 — Floating eligibility log reflects actual decision.
		if let cogAct = cognitiveFloatingAction {
			let capId = cogAct.capabilityId
			print("[FloatingEligibility] capability=\(capId) allowed=yes reason=safe_cognitive_preparation_no_better_action surface=floating_card")
			print("[SuggestionSurfaceContract] capability=\(capId) suggestion_surface=floating_card accept_behavior=run_and_show_floating_result")
			print("[ActionPortfolioResult] floating=\(capId) panel_count=\(mergedActions.count)")
		} else if let fc = floatingCandidate {
			print("[FloatingEligibility] capability=\(fc.capabilityId) allowed=yes reason=highest_eligible_floating surface=floating_card")
		} else {
			// No cognitive float; log for any acquisition action in panel
			let acquisitionInPanel = panelCapabilityIDs.first(where: { ["explicit_visible_capture_summary","extract_action_items","create_checklist"].contains($0) })
			if let acqCap = acquisitionInPanel {
				print("[FloatingEligibility] capability=\(acqCap) allowed=no reason=no_higher_priority_action_chose_panel surface=panel")
				print("[SuggestionSurfaceContract] capability=\(acqCap) suggestion_surface=panel accept_behavior=run_and_show_floating_result")
			}
		}

		print("[PanelModel] received actions=\(mergedActions.count) floating=\(cognitiveFloatingAction?.capabilityId ?? floatingCandidate?.capabilityId ?? "none") capabilities=[\(panelCapabilityList)]")
		print("[PanelComposition] total=\(mergedActions.count) capabilities=[\(panelCapabilityList)]")
		print("[PanelRender] action_count=\(mergedActions.count) capabilities=[\(panelCapabilityList)]")

		return DeterministicPanelPublication(
			actions: mergedActions,
			floatingCandidate: floatingCandidate,
			panelCount: mergedActions.count,
			suppressedCount: suppressedCount,
			cognitiveFloatingAction: cognitiveFloatingAction
		)
	}

	// Phase 43 — Show a deterministic cognitive action as a floating pill.
	// Bypasses TES (no text analysis needed for cognitive preparation).
	// Day1 gate does not apply — these are safe, executor-backed deterministic actions.
	@MainActor
	private func maybeShowCognitiveFloatingSuggestion(
		panelAction: DeterministicCapabilityPanelAction,
		context: ContextModel
	) {
		let capId = panelAction.capabilityId

		// Do not show while another action is executing.
		guard !appState.isActionExecuting else { return }
		// Do not show while assistant is paused.
		guard !appState.isPaused else { return }

		let cogKey = "cognitive_float|\(capId)|\(context.activeWindowTitle?.prefix(40) ?? "")"

		if appState.isPanelVisible {
			// Panel is open: highlight the cognitive action in the panel instead of floating.
			print("[SuggestionWhilePanelOpen] capability=\(capId) behavior=highlight_panel_card reason=panel_open")
			print("[PanelResultCard] shown capability=\(capId) output_chars=0")
			// Phase 43: cognitive capability is in highUsefulnessPanelCapabilities, so
			// updateHighUsefulnessPanelVisibility() will find and highlight it automatically.
			appState.updateHighUsefulnessPanelVisibility()
			return
		}

		// Do not show if a floating suggestion is already visible.
		guard !appState.isFloatingSuggestionVisible else { return }

		// Simple per-capability cooldown: do not re-show the same cognitive action within 90 seconds.
		let now = Date()
		if let lastAt = lastCognitiveFloatShownAt[capId], now.timeIntervalSince(lastAt) < 90 {
			print("[CognitiveAutoRun] capability=\(capId) allowed=no reason=cooldown_active")
			return
		}

		// Build the floating proposal. primaryActionId = panelAction.id so click → resolveStoredAction finds it.
		let productTitle = SuggestionTitleRewriter.cognitiveProductTitle(for: capId) ?? panelAction.name
		let proposal = ActionProposal(
			title: productTitle,
			sourceCaption: "Prepared for this page",
			primaryActionId: panelAction.id,
			secondaryActionIds: [],
			confidence: 0.70,
			reason: "cognitive_preparation_proactive"
		)

		let profile = ContentSimilarityProfile.make(from: cogKey)
		let bind = ActiveFloatingLifecycleBinding(
			exactKey: cogKey,
			safeKey: "cognitive|\(capId)",
			profile: profile,
			primaryActionId: panelAction.id
		)

		print("[Day1Gate] target=deterministic_cognitive_floating allowed=yes reason=safe_executor_backed")
		print("[ProposalRouting] deterministic_cognitive_exempt=yes")
		print("[CognitiveAutoRun] capability=\(capId) allowed=yes reason=idle_reading acquisition=metadata")
		print("[ResearchResultCard] shown capability=\(capId) trigger=suggestion_accept output_chars=0")

		lastCognitiveFloatShownAt[capId] = now
		appState.showFloatingSuggestion(proposal, lifecycle: bind)
	}

	private func dynamicGeneratedEvidenceContext(
		context: ContextModel,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> DynamicGeneratedEvidenceContext {
		let frontmost = NSWorkspace.shared.frontmostApplication
		let activeAppName = snapshot.activeApp.isEmpty
			? (context.activeAppName ?? frontmost?.localizedName ?? situational.activeAppName)
			: snapshot.activeApp
		let browserContext = BrowserContextExtractor.extract(
			appName: activeAppName,
			activeAppPID: frontmost?.processIdentifier
		)
		let currentURL = browserContext?.selectedURL ?? browserContext?.currentURL
		let selectedTitle = browserContext?.selectedTitle
		let tabTitles = browserContext?.recentTabTitles ?? []
		let hasOCRText = !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasSelectedText = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let browserAssessment = (currentURL != nil || !tabTitles.isEmpty || !(selectedTitle ?? "").isEmpty)
			? BrowserContextStrategy.assess(
				title: selectedTitle ?? context.activeWindowTitle ?? snapshot.windowTitle,
				url: currentURL,
				tabTitles: tabTitles,
				hasAXText: false,
				hasOCR: hasOCRText
			)
			: nil
		let evidenceProfile = EvidenceQualityModel.evaluate(
			title: selectedTitle ?? context.activeWindowTitle ?? snapshot.windowTitle,
			url: currentURL,
			tabTitles: tabTitles,
			hasAXText: false,
			hasOCR: hasOCRText,
			hasSelectedText: hasSelectedText,
			semanticGrounding: false,
			durableCompartment: false,
			browserAssessment: browserAssessment
		)
		return DynamicGeneratedEvidenceContext(
			evidenceQuality: evidenceProfile.level.legacyQuality,
			browserAssessment: browserAssessment
		)
	}

	private func gateDynamicGeneratedResult(
		_ result: DynamicGeneratedProposalResult,
		evidenceContext: DynamicGeneratedEvidenceContext
	) -> DynamicGeneratedProposalResult {
		var blockedForEvidence = 0
		let allowedProposals = result.proposals.filter { proposal in
			let gate = GeneratedActionEvidenceGate.evaluate(
				proposal: proposal,
				evidenceQuality: evidenceContext.evidenceQuality,
				browserAssessment: evidenceContext.browserAssessment,
				emitAllowedLog: false,
				emitRejectedLog: true
			)
			if !gate.allowed { blockedForEvidence += 1 }
			return gate.allowed
		}
		let allowedProposalIds = Set(allowedProposals.map(\.id))
		let allowedLibraryRecords = result.libraryRecords.filter { record in
			let gate = GeneratedActionEvidenceGate.evaluate(
				reusableRecord: record,
				evidenceQuality: evidenceContext.evidenceQuality,
				browserAssessment: evidenceContext.browserAssessment,
				emitAllowedLog: false,
				emitRejectedLog: true
			)
			if !gate.allowed { blockedForEvidence += 1 }
			return gate.allowed
		}
		let allowedHookContracts = result.hookContracts.filter { allowedProposalIds.contains($0.id) }
		if blockedForEvidence > 0 && allowedProposals.isEmpty && allowedLibraryRecords.isEmpty {
			print("[ProposalFunnelAudit] not_generated capability=generated_action reason=content_primitive_requires_visible_content")
			print("[OpportunityEngine] suppressed capability=generated_action reason=content_unavailable_metadata_only")
		}
		return DynamicGeneratedProposalResult(
			status: result.status,
			shouldChimeIn: result.shouldChimeIn,
			reason: result.reason,
			workflowAssessment: result.workflowAssessment,
			proposalConfidence: result.proposalConfidence,
			requiresVisualContext: result.requiresVisualContext,
			proposals: allowedProposals,
			warnings: result.warnings,
			llmDiagnosticCause: result.llmDiagnosticCause,
			createdAt: result.createdAt,
			contextSnapshot: result.contextSnapshot,
			libraryRecords: allowedLibraryRecords,
			hookContracts: allowedHookContracts
		)
	}

	private func mergeActions(primary: [any ActionProtocol], secondary: [any ActionProtocol]) -> [any ActionProtocol] {
		dedupeActions(primary + secondary)
	}

	private func dedupeActions(_ actions: [any ActionProtocol]) -> [any ActionProtocol] {
		var seen = Set<String>()
		var deduped: [any ActionProtocol] = []
		for action in actions {
			if seen.insert(action.id).inserted {
				deduped.append(action)
			}
		}
		return deduped
	}

	private func publishDynamicOnlyReasonedActions(
		panelActions: [any ActionProtocol],
		toolActions: [any ActionProtocol],
		finalProposal: ActionProposal?,
		finalProposalKey: String?,
		packet: TriggerPacket,
		context: ContextModel,
		generation: UInt64,
		generatedProposalActivation: GeneratedExecutionProposalActivationResult,
		debugStatus: GeneratedProposalDebugStatus,
		decision: ReasoningDecision
	) {
		guard generation == contextPipelineGeneration else { return }

		appState.applyGeneratedProposalActivation(generatedProposalActivation, debugStatus: debugStatus)
		let publishedActions = mergeActions(primary: panelActions, secondary: toolActions)
		// Phase 42 — Defer panel availableActions update when panel is open to avoid AppKit layout recursion.
		if appState.isPanelVisible {
			print("[PanelLayout] deferred_layout=yes reason=avoid_layout_recursion")
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.appState.availableActions = publishedActions
			}
		} else {
			appState.availableActions = publishedActions
		}
		appState.registeredToolActions = toolActions
		// Phase 4S — replace stale weak proposal when stronger context arrives.
		// Detected by comparing the previous proposal's title to the new one
		// through the FastVisibilityQualityGate. Emits a dedicated state log so
		// dogfood can see WHY a weak shell was swapped out.
		emitProposalReplacementLogIfStrongerContextArrived(
			previous: appState.currentProposal,
			next: finalProposal,
			appName: context.activeAppBundleIdentifier ?? ""
		)
		appState.currentProposal = finalProposal
		appState.currentProposalKey = finalProposalKey
		appState.refreshProposalContext(for: finalProposal)
		appState.updateHighUsefulnessPanelVisibility()
		lastReasonedActions = publishedActions
		lastReasonedActionsAt = Date()
		lastReasonedTriggerType = packet.triggerType
		lastReasonedProposal = finalProposal
		lastReasonedProposalKey = finalProposalKey
		if publishedActions.contains(where: { $0 is DeterministicCapabilityPanelAction }) {
			print("[AvailableActions] panel_count=\(publishedActions.count) floating_count=\(finalProposal == nil ? 0 : 1) source=deterministic_panel_actions")
		}
		print("[AvailableActions] dynamic_only visible_generated=\(generatedProposalActivation.visibleProposals.count) tools=\(toolActions.count) trigger=\(packet.triggerType.rawValue) reason=\(decision.reason)")

		if let p = finalProposal {
			maybeShowFloatingSuggestion(
				proposal: p,
				suggestionStrength: .strong,
				context: context,
				packet: packet,
				proposalGateAllows: true
			)
		}
	}

	private func publishReasonedActions(
		ordered: [any ActionProtocol],
		finalProposal: ActionProposal?,
		finalProposalKey: String?,
		strength: SuggestionStrengthResult?,
		packet: TriggerPacket,
		context: ContextModel,
		generation: UInt64,
		proposalGateAllows: Bool,
		generatedProposalActivation: GeneratedExecutionProposalActivationResult
	) {
		guard generation == contextPipelineGeneration else { return }

		appState.applyGeneratedProposalActivation(generatedProposalActivation)
		// Phase 43 (Part I) — Defer panel availableActions update when panel is open
		// to avoid AppKit layout recursion (same fix as publishDynamicOnlyReasonedActions).
		if appState.isPanelVisible {
			print("[PanelLayout] recursion_warning_fixed=yes deferred_layout=yes reason=avoid_layout_recursion")
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.appState.availableActions = ordered
			}
		} else {
			appState.availableActions = ordered
		}
		// Phase 4S — replacement signal (same rule as the dynamic-only path).
		emitProposalReplacementLogIfStrongerContextArrived(
			previous: appState.currentProposal,
			next: finalProposal,
			appName: context.activeAppBundleIdentifier ?? ""
		)
		appState.currentProposal = finalProposal
		appState.currentProposalKey = finalProposalKey
		appState.refreshProposalContext(for: finalProposal)
		appState.updateHighUsefulnessPanelVisibility()
		lastReasonedActions = ordered
		lastReasonedActionsAt = Date()
		lastReasonedTriggerType = packet.triggerType
		lastReasonedProposal = finalProposal
		lastReasonedProposalKey = finalProposalKey
		if ordered.contains(where: { $0 is DeterministicCapabilityPanelAction }) {
			print("[AvailableActions] panel_count=\(ordered.count) floating_count=\(finalProposal == nil ? 0 : 1) source=deterministic_panel_actions")
		}
		print("[AvailableActions] cached actions count=\(ordered.count) trigger=\(packet.triggerType.rawValue)")

		if let p = finalProposal, let s = strength, s.strength == .strong {
			maybeShowFloatingSuggestion(
				proposal: p,
				suggestionStrength: s.strength,
				context: context,
				packet: packet,
				proposalGateAllows: proposalGateAllows
			)
		}
	}

	private func scheduleDeferredProposalRefreshIfNeeded(retryAfter: TimeInterval, originalGeneration: UInt64) {
		guard retryAfter > 0 else { return }
		proposalTimingDeferredWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			guard originalGeneration == self.contextPipelineGeneration else {
				print("[ProposalTiming] deferred_cancelled reason=context_changed")
				return
			}
			guard !self.appState.isActionExecuting else { return }

			let ctx = self.contextBuilder.model
			let stillHasSelection = ctx.selectedTextAvailable && ctx.selectedTextLength >= TriggerEngine.selectedTextMinCharacterCount
			if !stillHasSelection {
				print("[ProposalTiming] deferred_cancelled reason=context_changed")
				return
			}

			self.processUpdatedContextAfterPipeline()
			print("[ProposalTiming] deferred_shown reason=idle_after_burst")
		}
		proposalTimingDeferredWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + retryAfter, execute: work)
		print("[ProposalTiming] deferred_scheduled after=\(String(format: "%.1f", retryAfter))s")
	}

	private func logProposalTimingIfNeededCore(decision: ProposalTimingDecision, typing: TypingActivityContext, pointer: PointerActivityContext) {
		let now = Date()
		let sig = [
			decision.outcome.rawValue,
			decision.reason,
			typing.typingState.rawValue,
			typing.burstIntensity.rawValue,
			pointer.pointerState.rawValue,
			pointer.movementBurstIntensity.rawValue,
			pointer.clickBurstIntensity.rawValue
		].joined(separator: "|")

		if sig == lastProposalTimingSignature, let lastProposalTimingLogAt, now.timeIntervalSince(lastProposalTimingLogAt) < 1.5 {
			return
		}
		lastProposalTimingSignature = sig
		lastProposalTimingLogAt = now

		switch decision.outcome {
		case .allow:
			print("[ProposalTiming] allow reason=\(decision.reason) typing=\(typing.typingState.rawValue) pointer=\(pointer.pointerState.rawValue)")
		case .deferred:
			print("[ProposalTiming] defer reason=\(decision.reason) typing=\(typing.typingState.rawValue) pointer=\(pointer.pointerState.rawValue)")
		case .suppress:
			print("[ProposalTiming] suppress reason=\(decision.reason) typing=\(typing.typingState.rawValue) pointer=\(pointer.pointerState.rawValue)")
		}
	}

	private func logProposalTimingIfNeeded(decision: ProposalTimingDecision, typing: TypingActivityContext?, pointer: PointerActivityContext?) {
		guard let typing, let pointer else {
			// If monitoring is not running yet, avoid noisy logs.
			return
		}
		logProposalTimingIfNeededCore(decision: decision, typing: typing, pointer: pointer)
	}

	private func applyIntelligenceRefinement(
		generation: UInt64,
		packet: TriggerPacket,
		context: ContextModel,
		sourceText: String,
		contextType: ContextType,
		features: ContextFeatures,
		strengthResult: SuggestionStrengthResult,
		overriddenDecision: ReasoningDecision,
		proposalGateAllowed: Bool,
		orderedSnapshot: [any ActionProtocol],
		heuristicProposal: ActionProposal,
		heuristicProposalKey: String?,
		contentProfile: ContentSimilarityProfile,
		llmIds: [String]
	) async {
		guard proposalGateAllowed else { return }
		guard generation == contextPipelineGeneration else {
			print("[IntelligenceSelection] stale_result_discarded")
			print("[IntelligenceFallback] reason=stale_context layer=selector")
			IntelligenceDebugLogger.log(
				stage: .selection,
				event: "stale_discarded",
				meta: IntelligenceDebugMeta(reason: "stale_context", layer: "selector")
			)
			return
		}

		let primaryBefore = heuristicProposal.primaryActionId
		let intel = await intelligenceProposalSelector.run(
			context: context,
			triggerPacket: packet,
			sourceText: sourceText,
			contextType: contextType,
			features: features,
			suggestionStrength: strengthResult.strength,
			candidateLLMActionIds: llmIds,
			heuristicPrimaryActionId: primaryBefore,
			inputPreference: appState.selectedInputSourceChoice,
			isActionExecuting: appState.isActionExecuting
		)

		guard generation == contextPipelineGeneration else {
			print("[IntelligenceSelection] stale_result_discarded")
			print("[IntelligenceFallback] reason=stale_context layer=selector")
			IntelligenceDebugLogger.log(
				stage: .selection,
				event: "stale_discarded",
				meta: IntelligenceDebugMeta(reason: "stale_context", layer: "selector")
			)
			return
		}

		if case .unchanged = intel.outcome, intel.intelligenceTitle == nil {
			return
		}

		var ordered = orderedSnapshot
		var finalProposal: ActionProposal? = heuristicProposal
		var finalProposalKey: String? = heuristicProposalKey

		switch intel.outcome {
		case .unchanged:
			if let t = intel.intelligenceTitle {
				finalProposal = ProposalGenerator.shared.generate(
					context: context,
					triggerPacket: packet,
					decision: overriddenDecision,
					inputSourcePreference: appState.selectedInputSourceChoice,
					intelligenceTitleOverride: t
				)
				if let p = finalProposal {
					finalProposalKey = "\(packet.triggerType.rawValue)|\(p.primaryActionId)|\(Self.proposalContentStamp(contentProfile))"
				} else {
					finalProposalKey = nil
				}
			}
		case .suppressProposal:
			finalProposal = nil
			finalProposalKey = nil
		case .overridePrimary(let newId):
			let fullRanked = Self.rankedIdsPlacingPrimary(newId, orderedIds: ordered.map(\.id), textPool: llmIds)
			let regenDecision = ReasoningDecision(
				shouldSurface: overriddenDecision.shouldSurface,
				primaryActionId: newId,
				rankedActionIds: fullRanked,
				reason: overriddenDecision.reason,
				confidence: overriddenDecision.confidence
			)
			finalProposal = ProposalGenerator.shared.generate(
				context: context,
				triggerPacket: packet,
				decision: regenDecision,
				inputSourcePreference: appState.selectedInputSourceChoice,
				intelligenceTitleOverride: intel.intelligenceTitle
			)
			if let p = finalProposal {
				finalProposalKey = "\(packet.triggerType.rawValue)|\(p.primaryActionId)|\(Self.proposalContentStamp(contentProfile))"
			} else {
				finalProposalKey = nil
			}
			ordered = Self.resortActions(ordered, rankedIds: fullRanked)
			print("[IntelligenceSelection] proposal overridden primary=\(newId)")
		}

		if ordered.isEmpty {
			finalProposal = nil
			finalProposalKey = nil
		} else if let p = finalProposal {
			let primaryInActions = ordered.contains(where: { $0.id == p.primaryActionId })
			if !primaryInActions {
				finalProposal = nil
				finalProposalKey = nil
			} else if appState.isSuggestionOnCooldown(p, context: context) {
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		if packet.triggerType != .manualInvocation, let key = finalProposalKey {
			if let dismissedAt = appState.lastDismissedProposalAt,
			   appState.lastDismissedProposalKey == key,
			   Date().timeIntervalSince(dismissedAt) < 120 {
				finalProposal = nil
				finalProposalKey = nil
			} else if let acceptedAt = appState.lastAcceptedProposalAt,
					  appState.lastAcceptedProposalKey == key,
					  Date().timeIntervalSince(acceptedAt) < 10 {
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		guard generation == contextPipelineGeneration else {
			print("[IntelligenceSelection] stale_result_discarded")
			print("[IntelligenceFallback] reason=stale_context layer=selector")
			IntelligenceDebugLogger.log(
				stage: .selection,
				event: "stale_discarded",
				meta: IntelligenceDebugMeta(reason: "stale_context", layer: "selector")
			)
			return
		}

		publishReasonedActions(
			ordered: ordered,
			finalProposal: finalProposal,
			finalProposalKey: finalProposalKey,
			strength: strengthResult,
			packet: packet,
			context: context,
			generation: generation,
			proposalGateAllows: proposalGateAllowed,
			generatedProposalActivation: appState.generatedProposalActivationResult
		)
	}

	private static let intelligenceTextActionIds: Set<String> = ["summarize_text", "explain_text", "rewrite_text"]

	private static func llmCandidateActionIds(from ordered: [any ActionProtocol]) -> [String] {
		ordered.map(\.id).filter { intelligenceTextActionIds.contains($0) }
	}

	private static func resortActions(_ actions: [any ActionProtocol], rankedIds: [String]) -> [any ActionProtocol] {
		let indexById = Dictionary(uniqueKeysWithValues: rankedIds.enumerated().map { ($0.element, $0.offset) })
		return actions.sorted { a, b in
			let ia = indexById[a.id] ?? Int.max
			let ib = indexById[b.id] ?? Int.max
			if ia != ib { return ia < ib }
			return a.id < b.id
		}
	}

	private static func proposalContentStamp(_ profile: ContentSimilarityProfile) -> String {
		let ph = String(profile.prefixHash, radix: 16)
		let sh = String(profile.suffixHash, radix: 16)
		return "\(profile.lengthBucket)|\(ph)|\(sh)"
	}

	private static func rankedIdsPlacingPrimary(_ primary: String, orderedIds: [String], textPool: [String]) -> [String] {
		var reordered: [String] = []
		if textPool.contains(primary) {
			reordered.append(primary)
			reordered.append(contentsOf: textPool.filter { $0 != primary })
		} else {
			reordered.append(primary)
			reordered.append(contentsOf: textPool.filter { $0 != primary })
		}
		let extras = orderedIds.filter { !intelligenceTextActionIds.contains($0) }
		return reordered + extras
	}

	private func logProposalGateIfNeeded(allowed: Bool, reason: String) {
		let sig = "\(allowed)|\(reason)"
		let now = Date()
		if let prev = lastProposalGateLogSignature, prev == sig, let t = lastProposalGateLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastProposalGateLogSignature = sig
		lastProposalGateLogAt = now
		if allowed {
			print("[ProposalGate] allowed reason=\(reason)")
		} else {
			print("[ProposalGate] blocked reason=\(reason)")
		}
	}

	private func logActionRelevanceIfNeeded(ranked: [ActionRelevanceScore], topId: String?) {
		guard !ranked.isEmpty else { return }
		let parts = ranked.prefix(6).map { r in
			let s = String(format: "%.2f", r.score)
			return "\(r.actionId)=\(s)"
		}
		let top = topId ?? "none"
		let sig = parts.joined(separator: "|") + "|top=\(top)"
		let now = Date()
		if let prev = lastActionRelevanceLogSignature, prev == sig, let t = lastActionRelevanceLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastActionRelevanceLogSignature = sig
		lastActionRelevanceLogAt = now
		print("[ActionRelevance] ranked \(parts.joined(separator: " ")) top=\(top)")
	}

	private func logProposalRankingIfNeeded(_ ranking: RankedProposalDecision) {
		let top = String(format: "%.2f", ranking.topScore)
		let secondary = ranking.secondaryActionIds.prefix(4).joined(separator: ",")
		let sig = "\(ranking.primaryActionId)|\(secondary)|\(top)|\(ranking.reason)"
		let now = Date()
		if let prev = lastProposalRankingLogSignature, prev == sig, let t = lastProposalRankingLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastProposalRankingLogSignature = sig
		lastProposalRankingLogAt = now
		print("[ProposalRanking] primary=\(ranking.primaryActionId) secondary=[\(secondary)] topScore=\(top) reason=\(ranking.reason)")
	}

	private func logSuggestionStrengthIfNeeded(_ s: SuggestionStrengthResult) {
		let score = String(format: "%.2f", s.score)
		let sig = "\(s.strength.rawValue)|\(score)|\(s.reason)"
		let now = Date()
		if let prev = lastSuggestionStrengthLogSignature, prev == sig, let t = lastSuggestionStrengthLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastSuggestionStrengthLogSignature = sig
		lastSuggestionStrengthLogAt = now
		print("[SuggestionStrength] strength=\(s.strength.rawValue) score=\(score) reason=\(s.reason)")
	}

	private func maybeShowFloatingSuggestion(
		proposal: ActionProposal,
		suggestionStrength: SuggestionStrength,
		context: ContextModel,
		packet: TriggerPacket,
		proposalGateAllows: Bool
	) {
		let resolvedInput = appState.effectiveInputSource(for: context)
		let rawSimilarity = FloatingSimilarityText.material(
			for: context,
			triggerType: packet.triggerType,
			inputPreference: resolvedInput
		)
		let profile = ContentSimilarityProfile.make(from: rawSimilarity)
		let life = appState.floatingSuggestionLifecycle.shouldSuppressNewFloating(
			triggerType: packet.triggerType,
			primaryActionId: proposal.primaryActionId,
			profile: profile
		)
		if life.suppressed, let r = life.reason {
			appState.floatingSuggestionLifecycle.logSuppressedIfNeeded(state: r, safeKey: life.safeKey)
			return
		}

		let tes = TriggerEligibilityEvaluator.evaluate(
			proposal: proposal,
			suggestionStrength: suggestionStrength,
			context: context,
			triggerType: packet.triggerType,
			isPaused: appState.isPaused,
			isPopoverOpen: menuBarController?.isPopoverShown ?? false,
			isFloatingVisible: appState.isFloatingSuggestionVisible,
			isActionExecuting: appState.isActionExecuting,
			inputSourceChoice: resolvedInput,
			proposalGateAllows: proposalGateAllows
		)

		let scoreLabel = String(format: "%.2f", tes.score)
		let sig = "\(tes.shouldShow)|\(tes.reason)|\(scoreLabel)|\(packet.triggerType.rawValue)|\(proposal.primaryActionId)"
		let now = Date()
		let shouldLogTES: Bool
		if let prev = lastTESLogSignature, prev == sig, let t = lastTESLogAt, now.timeIntervalSince(t) < 2.5 {
			shouldLogTES = false
		} else {
			shouldLogTES = true
			lastTESLogSignature = sig
			lastTESLogAt = now
		}

		if tes.shouldShow {
			if shouldLogTES {
				print("[TES] allow reason=\(tes.reason) score=\(scoreLabel)")
			}
			if let existing = appState.floatingSuggestion, existing == proposal, appState.isFloatingSuggestionVisible {
				return
			}
			let exactKey = appState.floatingSuggestionLifecycle.exactKey(
				triggerType: packet.triggerType,
				primaryActionId: proposal.primaryActionId,
				profile: profile
			)
			let safeKey = appState.floatingSuggestionLifecycle.safeLogKey(
				triggerType: packet.triggerType,
				primaryActionId: proposal.primaryActionId,
				profile: profile
			)
			let bind = ActiveFloatingLifecycleBinding(
				exactKey: exactKey,
				safeKey: safeKey,
				profile: profile,
				primaryActionId: proposal.primaryActionId
			)
			appState.showFloatingSuggestion(proposal, lifecycle: bind)
		} else if shouldLogTES {
			print("[TES] suppressed reason=\(tes.reason) score=\(scoreLabel)")
		}
	}

	// MARK: - Phase 20G.4 Ambient Jarvis → floating surface

	@MainActor
	private func maybeShowAmbientJarvisFloatingSuggestion(proposal: ActionProposal) {
		// Ambient Jarvis proposals are context-grounded (workflow/behavior/epoch),
		// NOT text-input-grounded. The standard TES path requires selected text or
		// clipboard — ambient tabs like Scratch / Gemini / course pages have neither,
		// so routing through TES always produces `no_meaningful_input` and the
		// floating window never appears.
		//
		// Fix: after ambient-appropriate gate checks (panel, cooldown, paused,
		// executing), go directly to the lifecycle dedup check and show. Skip TES.
		let ctx = contextBuilder.model

		// 1. Panel-open: attach inline instead of floating.
		if appState.isPanelVisible {
			print("[AmbientSuggestionSurface] attached_to_panel=yes")
			print("[AmbientFloatingSuggestion] skipped reason=panel_open_attached_inline")
			return
		}
		// 2. Ambient cooldown / dismissed / accepted.
		if appState.isSuggestionOnCooldown(proposal, context: ctx) {
			print("[AmbientFloatingSuggestion] skipped reason=cooldown|dismissed|accepted")
			return
		}
		// 3. Floating already visible.
		if appState.isFloatingSuggestionVisible {
			print("[AmbientFloatingSuggestion] skipped reason=already_visible")
			return
		}
		// 4. Assistant paused.
		if appState.isPaused {
			print("[AmbientFloatingSuggestion] skipped reason=assistant_paused")
			return
		}
		// 5. Another action is currently executing.
		if appState.isActionExecuting {
			print("[AmbientFloatingSuggestion] skipped reason=executing_action")
			return
		}

		let activeSuggestion = appState.activeAmbientJarvisSuggestion
		let capabilityId = activeSuggestion.map { appState.ambientCapabilityId(for: $0) } ?? proposal.primaryActionId

		// Phase 35.4: Final gate — restore_research_tabs blocked if tabs are already open
		if capabilityId == "restore_research_tabs" {
			let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
			let browser = BrowserContextExtractor.extract(appName: frontApp, activeAppPID: nil)
			let tabsOpen = (browser?.recentTabTitles.count ?? 0) > 0
			if tabsOpen {
				print("[ProposalFunnelAudit] not_generated capability=restore_research_tabs reason=tabs_already_open final_gate=yes")
				print("[SurfaceResult] capability=restore_research_tabs requested=floating actual=suppressed reason=tabs_already_open")
				return
			}
		}

		let isMusicPlaying = MediaStateSource.currentSnapshot().isMusicPlaying
		let isMusicSuppressed = isMusicPlaying
		let isUserTyping = TypingActivitySource.shared.currentContext().isTypingActive
		
		let inventory = WorkspaceRuntimeInventoryProvider.snapshot()
		let currentApps = Set(inventory.runningApps.map(\.appName))
		let workflowRaw = WorkflowInferenceEngine.shared.latestResult()?.workflow.rawValue ?? "unknown"
		
		let pattern = DurableMemory.shared.bestDurableWorkspacePattern(
			workflow: workflowRaw,
			compartment: activeSuggestion?.contextPayload?.taskCompartmentSnapshot?.label,
			currentApps: currentApps
		)
		let missing = pattern.map { DurableMemory.shared.missingCheck(pattern: $0, currentApps: currentApps, currentURLs: inventory.currentURLs) }
		
		let recentFeedback: String? = {
			if appState.wasSuggestionFeedbackLogged(id: capabilityId, event: "dismissed") { return "dismissed" }
			if appState.wasSuggestionFeedbackLogged(id: capabilityId, event: "ignored") { return "ignored" }
			if appState.wasSuggestionFeedbackLogged(id: capabilityId, event: "accepted") { return "accepted" }
			return nil
		}()
		
		let frictionSignals = FrictionEngine.shared.detectFriction()
		let hasDurablePattern = pattern != nil
		let involvedURLs: [String] = {
			var list: [String] = []
			if let s = activeSuggestion {
				let browsers = ["Safari", "Google Chrome", "Firefox", "Arc"]
				for browser in browsers {
					if let context = BrowserContextExtractor.extract(appName: browser, activeAppPID: nil),
					   let u = context.selectedURL?.absoluteString ?? context.currentURL?.absoluteString {
						if !u.isEmpty {
							list.append(u)
							break
						}
					}
				}
			}
			return list
		}()
		let userAcceptedMusicBefore = DurableMemory.shared.hasAcceptedMusicPreference()
		
		let isLayoutAlreadyGood = !frictionSignals.contains { $0.type == .repeated_app_switching || $0.type == .repeated_tab_switching }
		let finalSurfaceAuthoritativeCapabilities: Set<String> = [
			"arrange_side_by_side",
			"switch_to_paired_app",
			"restore_workspace",
			"split_research_setup"
		]
		if finalSurfaceAuthoritativeCapabilities.contains(capabilityId),
		   activeSuggestion?.whyNow.contains("Cheap always-on portfolio selected") == true {
			print("[SurfacePolicyBypass] capability=\(capabilityId) reason=final_surface_arbiter_authoritative")
		} else {
		
			let evaluation = SuggestionSurfacePolicy.evaluate(
				capabilityId: capabilityId,
				context: ctx,
				isMusicPlaying: isMusicPlaying,
				isMusicSuppressed: isMusicSuppressed,
				isUserTyping: isUserTyping,
				missing: missing,
				recentFeedback: recentFeedback,
				frictionSignals: frictionSignals,
				hasDurablePattern: hasDurablePattern,
				involvedURLs: involvedURLs,
				userAcceptedMusicBefore: userAcceptedMusicBefore,
				isLayoutAlreadyGood: isLayoutAlreadyGood
			)
			
			if evaluation.surface == SurfaceClassification.suppressed {
				print("[SurfaceResult] capability=\(capabilityId) requested=floating actual=suppressed reason=\(evaluation.reason)")
				print("[AmbientFloatingSuggestion] suppressed capability=\(capabilityId) reason=\(evaluation.reason)")
				return
			}
			if evaluation.surface == SurfaceClassification.panelOnly {
				print("[SurfaceResult] capability=\(capabilityId) requested=floating actual=panel_added reason=\(evaluation.reason)")
				print("[PanelAction] added capability=\(capabilityId) reason=surface_policy_panel_only")
				print("[AmbientFloatingSuggestion] suppressed capability=\(capabilityId) reason=panel_only")
				return
			}
		}

		print("[SurfaceResult] capability=\(capabilityId) requested=floating actual=shown reason=surface_policy_allowed")
		print("[AmbientFloatingSuggestion] eligible=yes id=\(proposal.primaryActionId)")

		// 6. Lifecycle dedup — prevent the same ambient suggestion from re-surfacing
		// on every tick. Use the ambient trigger type so lifecycle state is isolated
		// from regular floating suggestions.
		let packet = TriggerPacket(
			triggerType: .contextMetadataEligible,
			reason: "ambient_jarvis",
			candidateActions: [],
			createdAt: Date()
		)
		let resolvedInput = appState.effectiveInputSource(for: ctx)
		let rawSimilarity = FloatingSimilarityText.material(
			for: ctx,
			triggerType: packet.triggerType,
			inputPreference: resolvedInput
		)
		let profile = ContentSimilarityProfile.make(from: rawSimilarity)
		let life = appState.floatingSuggestionLifecycle.shouldSuppressNewFloating(
			triggerType: packet.triggerType,
			primaryActionId: proposal.primaryActionId,
			profile: profile
		)
		if life.suppressed, let r = life.reason {
			appState.floatingSuggestionLifecycle.logSuppressedIfNeeded(state: r, safeKey: life.safeKey)
			print("[AmbientFloatingSuggestion] skipped reason=lifecycle_suppressed")
			return
		}

		// 7. Show — bypasses TES (no selection/clipboard required for ambient context).
		print("[AmbientFloatingSuggestion] tes_bypassed reason=context_grounded_no_text_input_needed")
		let exactKey = appState.floatingSuggestionLifecycle.exactKey(
			triggerType: packet.triggerType,
			primaryActionId: proposal.primaryActionId,
			profile: profile
		)
		let safeKey = appState.floatingSuggestionLifecycle.safeLogKey(
			triggerType: packet.triggerType,
			primaryActionId: proposal.primaryActionId,
			profile: profile
		)
		let bind = ActiveFloatingLifecycleBinding(
			exactKey: exactKey,
			safeKey: safeKey,
			profile: profile,
			primaryActionId: proposal.primaryActionId
		)
		appState.showFloatingSuggestion(proposal, lifecycle: bind)
		print("[AmbientFloatingSuggestion] attached=yes")
		print("[AmbientFloatingSuggestion] shown=yes reason=ambient_jarvis")
	}

	private func preserveOrClearAvailableActions(reason: String) {
		if appState.isActionExecuting {
			print("[AvailableActions] preserving actions during execution")
			return
		}

		if reason.contains("proposal ranking unavailable"), !appState.availableActions.isEmpty {
			print("[AvailableActions] preserved_panel_actions reason=floating_ranking_unavailable panel_count=\(appState.availableActions.count)")
			print("[AvailableActions] cleared_floating_only reason=proposal_ranking_unavailable")
			appState.currentProposal = nil
			appState.currentProposalKey = nil
			appState.refreshProposalContext(for: nil)
			appState.updateHighUsefulnessPanelVisibility()
			lastReasonedProposal = nil
			lastReasonedProposalKey = nil
			return
		}

		let hasActiveGenerated = !appState.activatedGeneratedProposals.isEmpty

		guard let cachedAt = lastReasonedActionsAt else {
			if hasActiveGenerated {
				print("[AvailableActions] preserving generated actions reason=active_generated_proposal count=\(appState.activatedGeneratedProposals.count)")
				return
			}
			if !appState.availableActions.isEmpty {
				let countBefore = appState.availableActions.count
				appState.availableActions = []
				appState.currentProposal = nil
				appState.currentProposalKey = nil
				appState.refreshProposalContext(for: nil)
				appState.updateHighUsefulnessPanelVisibility()
				print("[AvailableActions] cleared cached actions reason=\(reason) count_before=\(countBefore)")
			}
			return
		}

		let age = Date().timeIntervalSince(cachedAt)
		let liveContext = contextBuilder.model
		
		// T18.6B — If idle ("no trigger packet") but same app/window, preserve for full TTL.
		let isSameContext: Bool = {
			guard let lastApp = lastPipelineActiveAppKey else { return false }
			return lastApp == liveContext.activeAppBundleIdentifier
		}()

		if age < availableActionsCacheTTLSeconds, !lastReasonedActions.isEmpty {
			if reason == "no trigger packet" && !isSameContext {
				// Different app and no trigger? Clear early, unless generated proposals exist.
				if hasActiveGenerated {
					print("[AvailableActions] preserving generated actions reason=active_generated_proposal count=\(appState.activatedGeneratedProposals.count)")
					return
				}
			} else {
				appState.availableActions = lastReasonedActions.filter { $0.canExecute(context: liveContext) }
				if let p = lastReasonedProposal,
				   lastReasonedActions.contains(where: { $0.id == p.primaryActionId }),
				   !appState.isSuggestionOnCooldown(p, context: appState.debugContext) {
					appState.currentProposal = p
					appState.currentProposalKey = lastReasonedProposalKey
					appState.refreshProposalContext(for: p)
				} else {
					appState.currentProposal = nil
					appState.currentProposalKey = nil
					appState.refreshProposalContext(for: nil)
				}
				appState.updateHighUsefulnessPanelVisibility()
				let now = Date()
				if lastPreserveLogAt == nil || now.timeIntervalSince(lastPreserveLogAt!) > 2 {
					lastPreserveLogAt = now
					let rounded = String(format: "%.1f", age)
					print("[AvailableActions] preserving cached actions age=\(rounded)s reason=\(reason)")
				}
				return
			}
		}

		if hasActiveGenerated {
			print("[AvailableActions] preserving generated actions reason=active_generated_proposal count=\(appState.activatedGeneratedProposals.count)")
			return
		}

		let countBefore = appState.availableActions.count
		appState.availableActions = []
		appState.currentProposal = nil
		appState.currentProposalKey = nil
		appState.refreshProposalContext(for: nil)
		appState.updateHighUsefulnessPanelVisibility()
		lastReasonedActions = []
		lastReasonedActionsAt = nil
		lastReasonedTriggerType = nil
		lastReasonedProposal = nil
		lastReasonedProposalKey = nil
		print("[AvailableActions] cleared cached actions reason=\(reason) count_before=\(countBefore)")
	}

	private func invokeGeneratedExecutionProposal(candidateId: String) {
		// T18.4: Execution-scoped generated execution — user-approved only, no auto-execution.
		if appState.isActionExecuting {
			print("[GeneratedProposalExecution] invoke_ignored reason=already_executing id=\(candidateId.prefix(12))")
			return
		}

		// Verify proposal validity before prep
		if candidateId.hasPrefix("hook:") {
			let isValid = appState.isProposalValid(candidateId: candidateId)
			if !isValid {
				print("[GeneratedProposalExecution] invoke_ignored reason=hook_contract_evicted id=\(candidateId.prefix(12))")
				appState.validateAndPruneProposals()
				return
			}
		}

		let actionId = GeneratedExecutionProposalActivator.generatedProposalActionId(for: candidateId)
		let cachedHookContract = appState.cachedHookContract(candidateId: candidateId)
		appState.isActionExecuting = true
		appState.executingActionId = actionId
		appState.executingActionTitle = cachedHookContract?.title ?? "Generated execution"
		appState.latestActionResult = nil
		appState.latestGeneratedExecutionPresentation = nil
		appState.latestActionId = actionId
		appState.latestActionTimestamp = Date()
		appState.generatedExecutionPhaseLabel = "Preparing context…"
		print("[GeneratedProposalExecution] runtime_prepare id=\(candidateId.prefix(12))")

		Task { @MainActor in
			defer {
				self.appState.isActionExecuting = false
				self.appState.executingActionId = nil
				self.appState.executingActionTitle = nil
				self.appState.generatedExecutionPhaseLabel = nil
				self.activeGeneratedExecutionRuntime = nil
				print("[GeneratedProposalExecution] runtime_finished id=\(candidateId.prefix(12))")
			}

			let now = Date()
			let canonical = CanonicalContextState.shared.current()
			let snapshot = self.buildCanonicalSnapshotForProposalActivation(context: self.contextBuilder.model, fused: canonical)

			// Verify the contract we are about to run matches what is currently visible in the panel.
			// A mismatch means the panel was updated after the user clicked (stale contract in cache).
			let visibleProposal = appState.activatedGeneratedProposals.first(where: { $0.id == candidateId })
			let isProposalStillVisible = visibleProposal != nil
			if let contract = cachedHookContract {
				let runtimeHooks = contract.hookPlanIds
				// The visible proposal doesn't carry hookPlanIds directly, so we report what the
				// runtime will actually execute and flag if the proposal is no longer in the active list.
				let mismatch = !isProposalStillVisible
				print("[ContractMismatch] candidate_id=\(candidateId.prefix(20)) proposal_visible=\(isProposalStillVisible ? "yes" : "no") visible_contract_hooks=[\(runtimeHooks.joined(separator: ","))] runtime_hooks=[\(runtimeHooks.joined(separator: ","))] mismatch=\(mismatch ? "yes" : "no")")
			} else if candidateId.hasPrefix("hook:") {
				// Hook candidate with no cached contract → cannot execute the right chain.
				print("[ContractMismatch] candidate_id=\(candidateId.prefix(20)) proposal_visible=\(isProposalStillVisible ? "yes" : "no") visible_contract_hooks=[] runtime_hooks=[] mismatch=yes reason=contract_evicted")
			}

			// Hook-composed contracts run through the deterministic execution router,
			// then the quarantined hook runtime sandbox (no templates, no LLM).
			if let contract = cachedHookContract, candidateId.hasPrefix("hook:") {
				print("[GeneratedProposalExecution] using_contract=yes title=\"\(contract.title)\"")

				// Route deterministically from hook metadata — blocks unsupported modes.
				let routingDecision = HookContractExecutionRouter.route(contract: contract)

				switch routingDecision {
				case .unsupportedForRuntime(let mode, let reason):
					print("[GeneratedProposalExecution] routing_blocked mode=\(mode.rawValue) reason=\(reason)")
					let failResult = ExecutionResult(
						actionId: UUID(), status: .failed, startedAt: now, completedAt: Date(),
						generatedContent: nil, generatedSections: [],
						warnings: ["execution_mode_unsupported:\(mode.rawValue)", reason],
						executionMetadata: ["routingPhase": "blocked", "mode": mode.rawValue, "reason": reason],
						confidence: 0, followUpSuggestions: []
					)
					self.appState.latestGeneratedExecutionPresentation = GeneratedExecutionResultPresenter.makePresentation(from: failResult, action: nil)
					print("[GeneratedExecutionResult] presented status=failed reason=unsupported_mode mode=\(mode.rawValue)")
					return

				case .requiresConfirmation(_, let mode):
					// Confirmation gate not yet wired — surface as unsupported.
					print("[GeneratedProposalExecution] routing_blocked mode=\(mode.rawValue) reason=confirmation_gate_not_wired")
					let failResult = ExecutionResult(
						actionId: UUID(), status: .failed, startedAt: now, completedAt: Date(),
						generatedContent: nil, generatedSections: [],
						warnings: ["confirmation_required_not_yet_wired"],
						executionMetadata: ["routingPhase": "blocked", "mode": mode.rawValue, "reason": "confirmation_gate_not_wired"],
						confidence: 0, followUpSuggestions: []
					)
					self.appState.latestGeneratedExecutionPresentation = GeneratedExecutionResultPresenter.makePresentation(from: failResult, action: nil)
					print("[GeneratedExecutionResult] presented status=failed reason=confirmation_gate_not_wired")
					return

				case .execute(let chain, let mode):
					print("[GeneratedProposalExecution] runtime_start id=\(candidateId.prefix(12)) source=generated_contract mode=\(mode.rawValue)")
					self.appState.generatedExecutionPhaseLabel = "Running hook chain…"

					let provider = ScreenCaptureBoundedVisualContextProvider()
					let scheduler = VisualContextScheduler(provider: provider)
					let budgetSnapshot = GeneratedExecutionBudgetSnapshot(
						activeExecutionCount: 1,
						runtimeState: .executing,
						permissionAvailability: snapshot.permissionAvailability,
						activeSamplingRequested: chain.contains("run_ocr_once")
							|| chain.contains("gather_visible_context_once")
					)

					var enrichedSnapshot = snapshot
					if mode == .observe_once {
						let res = await ObserveOnceExecutor.executePreObservation(
							snapshot: snapshot,
							scheduler: scheduler,
							budgetSnapshot: budgetSnapshot
						)
						enrichedSnapshot = res.snapshot
					}

					let sandboxResult = await HookExecutionSandbox.shared.execute(
						chain: chain,
						snapshot: enrichedSnapshot,
						mode: .live,
						source: .generatedContract,
						allowBoundedCapture: true,
						visualScheduler: scheduler,
						budgetSnapshot: budgetSnapshot
					)

					let status: ExecutionResultStatus = sandboxResult.status == .success ? .success : .failed
					let chainBody = chain.joined(separator: " → ")
					let outputBody = sandboxResult.finalOutput ?? ""
					let sections: [ExecutionResultSection] = [
						ExecutionResultSection(title: "Hook chain", body: chainBody, order: 0),
						ExecutionResultSection(title: "Output", body: outputBody.isEmpty ? "(no output)" : outputBody, order: 1),
					]
					var metadata = sandboxResult.executionMetadata ?? [:]
					metadata["hook_runtime_source"] = "generated_contract"
					metadata["hook_runtime_status"] = sandboxResult.status.rawValue
					metadata["hook_execution_mode"] = mode.rawValue

					let result = ExecutionResult(
						actionId: UUID(),
						status: status,
						startedAt: now,
						completedAt: Date(),
						generatedContent: nil,
						generatedSections: sections,
						warnings: sandboxResult.status == .success ? [] : [sandboxResult.failureReason ?? "hook_runtime_failed"],
						executionMetadata: metadata,
						confidence: contract.confidence,
						followUpSuggestions: []
					)
					let presentation = GeneratedExecutionResultPresenter.makePresentation(from: result, action: nil)
					self.appState.latestGeneratedExecutionPresentation = presentation
					print("[GeneratedProposalExecution] runtime_completed id=\(candidateId.prefix(12)) status=\(status.rawValue)")
					print("[GeneratedExecutionResult] presented status=\(status.rawValue) sections=\(presentation.sections.count)")
					return
				}
			}

			// A hook: candidate whose contract was evicted cannot fall back to the generic
			// execution path — the generic path would run a different plan (or none).
			// Surface a structured failure instead.
			if candidateId.hasPrefix("hook:") && cachedHookContract == nil {
				print("[GeneratedProposalExecution] runtime_unavailable id=\(candidateId.prefix(12)) reason=hook_contract_evicted")
				let failResult = ExecutionResult(
					actionId: UUID(),
					status: .failed,
					startedAt: now,
					completedAt: Date(),
					generatedContent: nil,
					generatedSections: [],
					warnings: ["hook_contract_evicted"],
					executionMetadata: ["runtimePhase": "unavailable", "reason": "hook_contract_evicted"],
					confidence: 0,
					followUpSuggestions: []
				)
				self.appState.latestGeneratedExecutionPresentation = GeneratedExecutionResultPresenter.makePresentation(from: failResult, action: nil)
				print("[GeneratedExecutionResult] presented status=failed reason=hook_contract_evicted")
				return
			}

			let action: GeneratedExecutionAction?
			var resolvedTemplateId: String?
			if candidateId.hasPrefix("reuse:") {
				let templateId = String(candidateId.dropFirst("reuse:".count))
				resolvedTemplateId = templateId
				let manager = GeneratedActionPersistenceManager.shared
				let record = await manager.record(templateId: templateId)
				if let record {
					let candidate = GeneratedExecutionProposalCandidateBuilder.buildReusable(from: [record], referenceTime: now).first
					action = candidate?.executionAction
					self.appState.executingActionTitle = candidate?.title ?? "Generated execution"
				} else {
					action = nil
				}
			} else {
				// Non-reusable synthesized candidates resolve via the ephemeral action cache populated
				// during proposal activation (hook composer / non-library candidates).
				action = self.appState.cachedGeneratedExecutionAction(candidateId: candidateId)
				if let action {
					self.appState.executingActionTitle = action.title
				}
			}

			guard let action else {
				print("[GeneratedProposalExecution] runtime_unavailable id=\(candidateId.prefix(12)) reason=missing_execution_action")
				// Surface a structured failure card rather than raw text.
				let failResult = ExecutionResult(
					actionId: UUID(),
					status: .failed,
					startedAt: now,
					completedAt: Date(),
					generatedContent: nil,
					generatedSections: [],
					warnings: ["missing_execution_action"],
					executionMetadata: ["runtimePhase": "unavailable"],
					confidence: 0,
					followUpSuggestions: []
				)
				self.appState.latestGeneratedExecutionPresentation = GeneratedExecutionResultPresenter.makePresentation(from: failResult, action: nil)
				print("[GeneratedExecutionResult] presented status=failed sections=0 reason=unavailable")
				return
			}

			// --- Phase V0: Direct Agent Runtime Boundary Override ---
			// Unavoidable boundary check before any legacy lookups.
			let actionIdFull = GeneratedExecutionProposalActivator.generatedProposalActionId(for: candidateId)
			let useDirectSetting = AgenticPivot.useDirectAgentRuntime
			print("[DirectAgentRuntime] boundary_check action_id=\(actionIdFull) source=\(action.generationSource.rawValue) use_direct=\(useDirectSetting)")

			let isAgenticForce = candidateId.hasPrefix("agentic:") || action.generationSource == .hookComposer
			if isAgenticForce || useDirectSetting {
				print("[DirectAgentRuntime] boundary_override=yes visible_goal=\"\(action.title)\" cached_goal_skipped=yes")
				print("[DirectAgentRuntime] enabled=yes source=generated_proposal")
				print("[DirectAgentRuntime] accepted_goal=\"\(action.title)\"")
				print("[DirectAgentLoop] starting goal=\"\(action.title)\"")
				self.appState.generatedExecutionPhaseLabel = "Preparing agentic execution…"

				let directPlan = AgenticTaskPlan(
					id: UUID().uuidString,
					goal: action.title, // Verbatim visible title exactly equals the runtime goal
					workflow: action.workflowType.rawValue,
					sourceProposalId: candidateId,
					allowedActionFamilies: [.observe, .read_screen, .find_on_page, .scroll, .click, .type, .present, .stop],
					requiredObservations: [],
					successCriteria: [action.title],
					stopConditions: [.success_criteria_met],
					maxSteps: 8,
					maxLLMCalls: 5,
					maxOCRCalls: 8,
					maxRuntimeSeconds: 60,
					requiresPermission: false,
					safetyLevel: .preview_only,
					createdAt: Date()
				)

				let agenticRuntime = AgenticRuntime()
				if let anchor = action.targetAnchor {
					print("[TargetAnchorTrace] stage=generated_execution_handoff anchor_nil=no")
					print("[TargetAnchorTrace] bundle=\(anchor.bundleIdentifier)")
					print("[TargetAnchorTrace] title=\"\(anchor.windowTitle.prefix(80))\"")
				} else {
					print("[TargetAnchorTrace] stage=generated_execution_handoff anchor_nil=yes")
				}
				let agenticResult = await agenticRuntime.execute(
					plan: directPlan,
					action: action,
					snapshot: snapshot,
					targetAnchor: action.targetAnchor,
					referenceTime: now,
					forceDirectRuntime: true
				)

				let execResult = agenticResult.toExecutionResult(
					actionId: action.id,
					confidence: action.confidence,
					startedAt: now
				)
				let presentation = GeneratedExecutionResultPresenter.makePresentation(from: execResult, action: action)
				self.appState.latestGeneratedExecutionPresentation = presentation
				self.appState.latestActionId = actionId
				self.appState.latestActionTimestamp = Date()
				self.appState.latestActionResult = nil
				print("[AgenticRuntimeRouting] complete id=\(candidateId.prefix(12)) direct=yes status=\(agenticResult.status.rawValue) phase=\(agenticResult.runtimePhase) goal=\"\(action.title)\"")
				return
			}

			let visualRequired = action.executionPlan.requiresVision || action.executionPlan.requiresOCR
			print(
				"[GeneratedProposalExecution] selected id=\(candidateId.prefix(12)) template=\(resolvedTemplateId ?? "unknown") visual_required=\(visualRequired ? "yes" : "no")"
			)

			// MARK: Agentic routing invariant (Legacy fallback or if direct mode disabled)
			let cachedPlan = self.appState.cachedAgenticPlan(candidateId: candidateId)
			let isAgenticByIdPrefix = candidateId.hasPrefix("agentic:")
			let isAgenticRoute = cachedPlan != nil || isAgenticByIdPrefix

			if isAgenticRoute {
				print("[AgenticRuntimeRouting] route=agentic_runtime reason=legacy_fallback id=\(candidateId.prefix(12)) goal=\(cachedPlan?.goal.prefix(60) ?? "unknown")")
				self.appState.generatedExecutionPhaseLabel = "Preparing agentic execution…"

				// Phase 4S — Execution-time stale-goal validation.
				var effectivePlan = cachedPlan
				if let plan = cachedPlan {
					let currentTitle = snapshot.windowTitle
					let currentDecision = FastVisibilityQualityGate.evaluate(title: currentTitle, appName: snapshot.activeApp)
					let cachedDecision = FastVisibilityQualityGate.evaluate(title: plan.goal, appName: snapshot.activeApp)
					if cachedDecision.eligible == false,
					   currentDecision.eligible == true,
					   !Self.shareSignificantTokens(plan.goal, currentTitle) {
						print("[ExecutionContextValidation] stale_goal=yes current_stronger=yes action=repair_or_block cached_class=\(cachedDecision.classification.rawValue) current_class=\(currentDecision.classification.rawValue)")
						print("[ExecutionContextValidation] repaired_goal=\"\(currentTitle.prefix(80))\"")
						effectivePlan = AgenticTaskPlan(
							id: plan.id,
							goal: currentTitle,
							workflow: plan.workflow,
							sourceProposalId: plan.sourceProposalId,
							allowedActionFamilies: plan.allowedActionFamilies,
							requiredObservations: plan.requiredObservations,
							successCriteria: plan.successCriteria,
							stopConditions: plan.stopConditions,
							maxSteps: plan.maxSteps,
							maxLLMCalls: plan.maxLLMCalls,
							maxOCRCalls: plan.maxOCRCalls,
							maxRuntimeSeconds: plan.maxRuntimeSeconds,
							requiresPermission: plan.requiresPermission,
							safetyLevel: plan.safetyLevel,
							createdAt: plan.createdAt
						)
					}
				}

				let agenticRuntime = AgenticRuntime()
				let agenticResult = await agenticRuntime.execute(
					plan: effectivePlan,
					action: action,
					snapshot: snapshot,
					referenceTime: now
				)
				let execResult = agenticResult.toExecutionResult(
					actionId: action.id,
					confidence: action.confidence,
					startedAt: now
				)
				let presentation = GeneratedExecutionResultPresenter.makePresentation(from: execResult, action: action)
				self.appState.latestGeneratedExecutionPresentation = presentation
				self.appState.latestActionId = actionId
				self.appState.latestActionTimestamp = Date()
				self.appState.latestActionResult = nil
				print("[AgenticRuntimeRouting] complete id=\(candidateId.prefix(12)) status=\(agenticResult.status.rawValue) phase=\(agenticResult.runtimePhase) sections=\(presentation.sections.count)")
				return
			}

			// MARK: Legacy fixed-chain routing
			print("[AgenticRuntimeRouting] route=legacy_generated_runtime reason=fixed_plan id=\(candidateId.prefix(12)) primitives=\(action.executionPlan.primitives.count)")

			// Visual enrichment is execution-scoped and optional: scheduler is injected only here.
			let provider = ScreenCaptureBoundedVisualContextProvider()
			let scheduler = VisualContextScheduler(provider: provider)
			let runtime = GeneratedExecutionRuntime(
				persistenceManager: GeneratedActionPersistenceManager.shared,
				visualContextScheduler: scheduler,
				canonicalSnapshot: snapshot
			)
			self.activeGeneratedExecutionRuntime = runtime

			self.appState.generatedExecutionPhaseLabel = visualRequired ? "Gathering visual context…" : "Gathering context…"
			print("[GeneratedExecutionRuntime] live_start id=\(candidateId.prefix(12)) workflow=\(action.workflowType.rawValue) primitives=\(action.executionPlan.primitives.count)")

			let outcome = await runtime.start(action: action)
			switch outcome {
			case .completed(let result):
				let status = result.status.rawValue
				let visual = result.executionMetadata["visual_enrichment_performed"] == "1" ? "yes" : "no"
				let visualDecision = result.executionMetadata["visual_enrichment_decision"] ?? "unknown"
				print("[GeneratedExecutionRuntime] live_completed id=\(candidateId.prefix(12)) status=\(status) visual=\(visual) decision=\(visualDecision)")
				let presentation = GeneratedExecutionResultPresenter.makePresentation(from: result, action: action)
				self.appState.latestGeneratedExecutionPresentation = presentation
				self.appState.latestActionId = actionId
				self.appState.latestActionTimestamp = Date()
				self.appState.latestActionResult = nil
				print("[GeneratedExecutionResult] presented status=\(status) sections=\(presentation.sections.count) followUps=\(presentation.followUpSuggestions.count)")
				// Cache hook-composed actions only after a successful execution (accelerator, not source of truth).
				if result.status == .success || result.status == .partialSuccess {
					await DynamicGeneratedProposalEngine.shared.recordSuccessfulDynamicActionExecution(
						candidateId: candidateId,
						action: action,
						referenceTime: Date()
					)
				}

			case .rejected(let reason):
				print("[GeneratedExecutionRuntime] live_completed id=\(candidateId.prefix(12)) status=rejected reason=\(reason.rawValue)")
				let failResult = ExecutionResult(
					actionId: action.id,
					status: .failed,
					startedAt: now,
					completedAt: Date(),
					generatedContent: nil,
					generatedSections: [],
					warnings: [reason.rawValue],
					executionMetadata: ["runtimePhase": "rejected"],
					confidence: action.confidence,
					followUpSuggestions: []
				)
				self.appState.latestGeneratedExecutionPresentation = GeneratedExecutionResultPresenter.makePresentation(from: failResult, action: action)
				self.appState.latestActionResult = nil
				print("[GeneratedExecutionResult] presented status=rejected sections=0")
			}
		}
	}

	private func invokeStoredAction(actionId: String) {
		if actionId == ScreenAnalyzeAction.analyzeScreenId {
			invokeAnalyzeScreenStoredAction()
			return
		}
		let panelCapabilityID = (appState.availableActions.first { $0.id == actionId } as? DeterministicCapabilityPanelAction)?.capabilityId
		if actionId == "open_current_task_panel" || panelCapabilityID == "open_current_task_panel" {
			if let click = appState.pendingClickContext(for: actionId) {
				print("[ActionPreflight] capability=\(click.capabilityID) contract_id=\(click.contractID ?? "missing") status=ok")
				print("[CapabilityExecution] started id=\(click.capabilityID) source_surface=\(click.sourceSurface.rawValue)")
				print("[ActionVerification] capability=\(click.capabilityID) status=success")
				appState.finalizeActionFeedback(actionID: actionId, status: .success)
			}
			menuBarController?.revealPopoverIfNeeded(source: .explicit_button)
			appState.isPanelVisible = true
			appState.updateHighUsefulnessPanelVisibility()
			print("[CapabilityExecution] completed status=success id=open_current_task_panel reason=panel_requested")
			return
		}

		var execContext = contextBuilder.model
		execContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		let resolution = appState.resolveStoredAction(id: actionId, context: execContext)
		print("[ActionClickResolution] proposal_id=\(resolution.proposalID) candidate_id=\(resolution.candidateID) resolved=\(resolution.resolved ? "yes" : "no") reason=\(resolution.reason) contract_id=\(resolution.contractID ?? "missing")")
		if resolution.preservedRecentCandidate {
			print("[ActionClickResolution] preserved_recent_candidate=yes contract_valid=\(resolution.contractValid ? "yes" : "no")")
		}
		guard let action = resolution.action else {
			appState.finalizeActionFeedback(actionID: actionId, status: .unavailable, reason: resolution.reason)
			return
		}
		guard action.canExecute(context: execContext) else {
			print("[ActionResult] No valid actions")
			appState.finalizeActionFeedback(actionID: actionId, status: .blocked, reason: "payload_invalid")
			return
		}
		print("[ActionPreflight] capability=\(resolution.capabilityID) contract_id=\(resolution.contractID ?? "missing") status=\(resolution.contractValid ? "ok" : "blocked")")
		if !resolution.contractValid {
			appState.finalizeActionFeedback(actionID: actionId, status: .unavailable, reason: "missing_contract")
			return
		}

		if appState.isActionExecuting {
			print("[ActionExecution] Ignored duplicate action while execution is in progress")
			return
		}

		let inputFingerprint = Self.stableInputFingerprint(for: execContext)
		let invocationKey = "\(actionId)|\(inputFingerprint)"
		if let finishedAt = lastFinishedAt,
		   lastFinishedActionKey == invocationKey,
		   Date().timeIntervalSince(finishedAt) < 2 {
			print("[ActionExecution] Ignored duplicate action invocation within cooldown")
			return
		}

		appState.isActionExecuting = true
		appState.executingActionId = actionId
		appState.executingActionTitle = action.name
		appState.latestActionResult = nil
		appState.latestActionId = actionId
		appState.latestActionTimestamp = Date()
		if let click = appState.pendingClickContext(for: actionId) {
			print("[CapabilityExecution] started id=\(resolution.capabilityID) source_surface=\(click.sourceSurface.rawValue)")
		}
		print("[AppState] executing action=\(actionId)")
		print("[ActionExecution] Starting action \(actionId)")
		Task { @MainActor in
			defer {
				appState.isActionExecuting = false
				appState.executingActionId = nil
				appState.executingActionTitle = nil
				print("[AppState] execution finished action=\(actionId)")
				self.lastFinishedActionKey = invocationKey
				self.lastFinishedAt = Date()
				print("[ActionExecution] Cleared in-flight state")
			}
			let outcome = await Self.runActionWithSecondsTimeout(seconds: 45) {
				if let panelAction = action as? DeterministicCapabilityPanelAction,
				   let click = self.appState.pendingClickContext(for: actionId) {
					return await panelAction.execute(context: execContext, sourceSurface: click.sourceSurface.rawValue)
				}
				return await action.execute(context: execContext)
			}
			switch outcome {
			case .completed(let result):
				print("[ActionResult]", result.outputText)
				appState.latestActionResult = result.outputText
				appState.latestActionTimestamp = Date()
				print("[ActionExecution] Finished action \(actionId)")
				
				let cleanActionId = actionId.replacingOccurrences(of: "ambient_jarvis:", with: "")
				let acquisitionActions: Set<String> = [
					"explicit_visible_capture_summary", "extract_action_items", "create_checklist"
				]
				let writingActions: Set<String> = [
					"summarize_visible_content", "rewrite_text", "improve_text", "explain_context", "draft_reply", "diagnose_error"
				]
				let researchActions = acquisitionActions.union(writingActions)
				if researchActions.contains(cleanActionId) {
					let isRealSuccess = result.executionStatus == .success
					let isClipboardAction = acquisitionActions.contains(cleanActionId) || writingActions.contains(cleanActionId)
					// Phase 42 executors write result to clipboard — read it back as the canonical output.
					let clipboardText = isClipboardAction && isRealSuccess
						? (NSPasteboard.general.string(forType: .string) ?? "")
						: result.outputText
					let outputText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
					let chars = outputText.count
					if isRealSuccess && chars > 0 {
						appState.activeResearchResultCard = ResearchResultCardState(
							capabilityID: cleanActionId,
							title: acquisitionActions.contains(cleanActionId) ? "Page Summary" : "Result",
							text: outputText,
							outputChars: chars
						)
						print("[ResearchResultCard] shown capability=\(cleanActionId) output_chars=\(chars) dismissible=yes open_panel_option=yes")
						print("[ActionResultUI] shown=yes type=floating_result_card capability=\(cleanActionId) chars=\(chars)")
					} else {
						let statusStr = result.executionStatus?.rawValue ?? "unknown"
						print("[ResearchResultCard] suppressed capability=\(cleanActionId) reason=\(isRealSuccess ? "empty_output" : "execution_failed") status=\(statusStr)")
						print("[ActionResultUI] shown=no type=error_card capability=\(cleanActionId) reason=\(statusStr)")
					}
				} else if result.executionStatus == .success {
					print("[ActionResultUI] shown=yes type=toast capability=\(cleanActionId)")
				} else if result.executionStatus == .unavailable {
					print("[ActionResultUI] shown=no type=error_card capability=\(cleanActionId) reason=executor_unavailable")
				}

				appState.finalizeActionFeedback(actionID: actionId, status: result.executionStatus)
			case .timedOut:
				print("[ActionExecution] Action timed out")
				print("[ActionExecution] Failed action \(actionId): timed out")
				appState.latestActionResult = "This action timed out. Try again with less text or check that local AI is responding."
				appState.latestActionTimestamp = Date()
				appState.finalizeActionFeedback(actionID: actionId, status: .cancelled, reason: "timed_out")
			}
		}
	}

	/// Screen capture + OCR only for explicit Analyze Screen (not normal manual assistant open).
	@MainActor
	private func runExplicitAnalyzeScreenCaptureAndOCR() async {
		print("[AnalyzeScreenRich] explicit_screen_analysis=true")
		print("[Phase14Tuning] fixed reason=manual_ocr_gate")
		sourceManager?.captureScreenNow()
		guard let image = contextBuilder.model.screenCaptureImage else {
			print("[ScreenCapture] post_capture_no_image reason=explicit_analyze_screen")
			return
		}
		let result = await OCRProcessor.shared.recognizeText(from: image)
		processSourceEvent(
			.sourceChanged(.screenOCRCompleted(text: result.text, lineCount: result.lineCount, capturedAt: result.timestamp))
		)
	}

	private func invokeAnalyzeScreenStoredAction() {
		let actionId = ScreenAnalyzeAction.analyzeScreenId
		var execContext = contextBuilder.model
		execContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		guard appState.availableActions.contains(where: { $0.id == actionId }) else { return }
		guard ScreenAnalyzeAction().canExecute(context: execContext) else {
			print("[ActionResult] No valid actions")
			return
		}

		if appState.isActionExecuting {
			print("[ActionExecution] Ignored duplicate action while execution is in progress")
			return
		}

		appState.isActionExecuting = true
		appState.executingActionId = actionId
		appState.executingActionTitle = "Analyze Screen"
		appState.latestActionResult = nil
		appState.latestActionId = actionId
		appState.latestActionTimestamp = Date()
		print("[AppState] executing action=\(actionId)")
		print("[ActionExecution] Starting action \(actionId)")
		Task { @MainActor in
			defer {
				appState.isActionExecuting = false
				appState.executingActionId = nil
				appState.executingActionTitle = nil
				print("[AppState] execution finished action=\(actionId)")
				print("[ActionExecution] Cleared in-flight state")
			}

			await self.runExplicitAnalyzeScreenCaptureAndOCR()

			var freshContext = self.contextBuilder.model
			freshContext.actionInputSourcePreference = self.appState.selectedInputSourceChoice
			guard ScreenAnalyzeAction().canExecute(context: freshContext) else {
				print("[ActionResult] Analyze Screen unavailable after capture (permissions or empty capture)")
				self.appState.latestActionResult = "Could not capture the screen for analysis. Check Screen Recording permission and try again."
				self.appState.latestActionTimestamp = Date()
				return
			}

			let inputFingerprint = Self.stableInputFingerprint(for: freshContext)
			let invocationKey = "\(actionId)|\(inputFingerprint)"
			if let finishedAt = self.lastFinishedAt,
			   self.lastFinishedActionKey == invocationKey,
			   Date().timeIntervalSince(finishedAt) < 2 {
				print("[ActionExecution] Ignored duplicate action invocation within cooldown")
				return
			}

			let outcome = await Self.runActionWithSecondsTimeout(seconds: 45) {
				await ScreenAnalyzeAction().execute(context: freshContext)
			}
			switch outcome {
			case .completed(let result):
				print("[ActionResult]", result.outputText)
				self.appState.latestActionResult = result.outputText
				self.appState.latestActionTimestamp = Date()
				self.lastFinishedActionKey = invocationKey
				self.lastFinishedAt = Date()
				print("[ActionExecution] Finished action \(actionId)")
			case .timedOut:
				print("[ActionExecution] Action timed out")
				print("[ActionExecution] Failed action \(actionId): timed out")
				self.appState.latestActionResult = "This action timed out. Try again with less text or check that local AI is responding."
				self.appState.latestActionTimestamp = Date()
				self.lastFinishedActionKey = invocationKey
				self.lastFinishedAt = Date()
			}
		}
	}

	private enum ActionTimedOutcome<T> {
		case completed(T)
		case timedOut
	}

	private static func runActionWithSecondsTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> ActionTimedOutcome<T> {
		await withTaskGroup(of: ActionTimedOutcome<T>.self) { group in
			group.addTask {
				let value = await operation()
				return .completed(value)
			}
			group.addTask {
				let nanos = UInt64(seconds * 1_000_000_000)
				try? await Task.sleep(nanoseconds: nanos)
				return .timedOut
			}
			let first = await group.next()!
			group.cancelAll()
			return first
		}
	}

	private static func stableInputFingerprint(for context: ContextModel) -> UInt64 {
		if let text = ActionInputCapture.primaryText(for: context, minimumLength: 30, preference: context.actionInputSourcePreference) {
			var hash: UInt64 = 14_695_981_039_346_656_037
			for byte in text.utf8 {
				hash ^= UInt64(byte)
				hash &*= 1_099_511_628_211
			}
			return hash
		}
		return UInt64(context.clipboardTextLength)
			^ (UInt64(context.selectedTextLength) &<< 32)
			^ (UInt64(context.screenOCRTextLength) &<< 48)
	}

	private func logContextModel(_ model: ContextModel) {
		let sig = [
			model.activeAppName ?? "nil",
			model.activeAppBundleIdentifier ?? "nil",
			model.activeWindowTitle ?? "nil",
			"c:\(model.clipboardTextAvailable):\(model.clipboardTextLength)",
			"s:\(model.selectedTextAvailable):\(model.selectedTextLength)",
			model.lastSourceTrigger?.rawValue ?? "nil"
		].joined(separator: "|")

		if sig == lastContextLogSignature { return }
		lastContextLogSignature = sig

		print(
			"[ContextModel]",
			"app=\(model.activeAppName ?? "nil")",
			"bundle=\(model.activeAppBundleIdentifier ?? "nil")",
			"windowTitle=\(model.activeWindowTitle != nil)",
			"clipboard=(available:\(model.clipboardTextAvailable) length:\(model.clipboardTextLength))",
			"selection=(available:\(model.selectedTextAvailable) length:\(model.selectedTextLength))",
			"lastTrigger=\(model.lastSourceTrigger?.rawValue ?? "nil")"
		)
	}

	private func logTriggerPacket(_ packet: TriggerPacket, context: ContextModel) {
		print(
			"[TriggerPacket]",
			"type=\(packet.triggerType.rawValue)",
			"reason=\(packet.reason)",
			"actions=\(packet.candidateActions)",
			"clipboardLength=\(context.clipboardTextLength)",
			"selectionLength=\(context.selectedTextLength)",
			"createdAt=\(packet.createdAt)"
		)
	}

	@discardableResult
	private func runPhase13SelfTestsIfRequested(environment env: [String: String]) -> Bool {
		// Phase 13 env-var self-tests should run once and exit without wiring the normal app pipeline.
		// This keeps verification runs clean and avoids incidental startup logs/side-effects.

		// Phase 14 tuning pass regression self-test (synthetic; no capture/OCR).
		// Run with `CONTEXTUAL_RUN_PHASE14_TUNING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PHASE14_TUNING_SELFTEST"] == "1" {
			let ok = Phase14TuningSelfTest.run()
			print("[Phase14Tuning] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 15 tuning pass (synthetic; preview-only generated actions; metadata-only).
		// Run with `CONTEXTUAL_RUN_PHASE15_TUNING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PHASE15_TUNING_SELFTEST"] == "1" {
			let ok = Phase15TuningSelfTest.run()
			print("[Phase15Tuning] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Visible generated actions panel rules (T16.1; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_VISIBLE_GENERATED_ACTIONS_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_VISIBLE_GENERATED_ACTIONS_SELFTEST"] == "1" {
			let ok = VisibleGeneratedActionPanelAdapter.runSelfTest()
			print("[VisibleGeneratedAction] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Inline assistance foundations (T16.6 + T18.6; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_INLINE_ASSISTANCE_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_INLINE_ASSISTANCE_SELFTEST"] == "1" {
			let builderOk = InlineAssistanceCandidateBuilder.runSelfTest()
			let policyOk  = InlineAssistanceEligibilityPolicy.runSelfTest()
			let ok = builderOk && policyOk
			print("[InlineAssistance] env selftest ok=\(ok) builder=\(builderOk) policy=\(policyOk)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action interaction tracking (T16.9; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_GENERATED_ACTION_INTERACTION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_GENERATED_ACTION_INTERACTION_SELFTEST"] == "1" {
			let ok = GeneratedActionInteractionTracker.runSelfTest()
			print("[GeneratedActionInteraction] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich assistance unified ranking (T16.10; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_RICH_ASSISTANCE_RANKING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_RICH_ASSISTANCE_RANKING_SELFTEST"] == "1" {
			let ok = RichAssistanceRanker.runSelfTest()
			print("[RichAssistanceRank] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Visible intelligence debug summary (T16.11; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_VISIBLE_INTELLIGENCE_DEBUG_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_VISIBLE_INTELLIGENCE_DEBUG_SELFTEST"] == "1" {
			let ok = VisibleIntelligenceDebugSummaryBuilder.runSelfTest()
			print("[VisibleIntelligenceDebug] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated assistance categories (T16.5; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_ASSISTANCE_CATEGORY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_ASSISTANCE_CATEGORY_SELFTEST"] == "1" {
			let ok = GeneratedAssistanceCategoryMapper.runSelfTest()
			print("[AssistanceCategory] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow inference engine self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_WORKFLOW_INFERENCE_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_INFERENCE_SELFTEST"] == "1" {
			let ok = WorkflowInferenceEngine.runSelfTest()
			print("[WorkflowInference] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Contextual session tracking self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_SESSION_TRACKING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_SESSION_TRACKING_SELFTEST"] == "1" {
			let ok = ContextualSessionTracker.runSelfTest()
			print("[SessionTracking] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Intent synthesis engine self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_INTENT_SYNTHESIS_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_INTENT_SYNTHESIS_SELFTEST"] == "1" {
			let ok = IntentSynthesisEngine.runSelfTest()
			print("[IntentSynthesis] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Dynamic intent suppression self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_INTENT_SUPPRESSION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_INTENT_SUPPRESSION_SELFTEST"] == "1" {
			let ok = DynamicIntentSuppressionEngine.runSelfTest()
			print("[IntentSuppression] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action model self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_GENERATED_ACTION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_GENERATED_ACTION_SELFTEST"] == "1" {
			let ok = GeneratedActionEngine.runSelfTest()
			print("[GeneratedAction] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		if env["CONTEXTUAL_RUN_PHASE23_GENERATED_ACTION_SELFTEST"] == "1" {
			let ok = GeneratedActionSelfTest.run()
			print("[GeneratedActionSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		if env["CONTEXTUAL_RUN_PASSIVE_PLAYLIST_SELFTEST"] == "1" {
			let ok = PassivePlaylistObserverSelfTest.run()
			print("[PassivePlaylistObserverSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		if env["CONTEXTUAL_RUN_ACTION_VALIDATION_SELFTEST"] == "1" {
			let ok = ActionValidationSelfTest.run()
			print("[ActionValidationSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		if env["CONTEXTUAL_RUN_PRIMITIVE_COMPOSER_SELFTEST"] == "1" {
			let ok = PrimitiveComposerSelfTest.run()
			print("[PrimitiveComposerSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		if env["CONTEXTUAL_RUN_PROBLEM_INFERENCE_SELFTEST"] == "1" {
			let ok = ProblemInferenceSelfTest.run()
			print("[ProblemInferenceSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		if env["CONTEXTUAL_RUN_ACTION_CANDIDATE_GENERATOR_SELFTEST"] == "1" {
			Task {
				let ok = await ActionCandidateGeneratorSelfTest.run()
				print("[ActionCandidateGeneratorSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_ACTION_VALIDATION_V24_SELFTEST"] == "1" {
			let ok = ActionValidationSelfTestV24.run()
			print("[ActionValidationSelfTestV24] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		if env["CONTEXTUAL_RUN_ENVIRONMENT_ACTION_SELFTEST"] == "1" {
			Task {
				let ok = await EnvironmentActionSelfTest.run()
				print("[EnvironmentActionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 32 — AX permission probe at startup
		AXPermissionProbe.check(reason: "startup")

		// Phase 33 — Debug action trigger
		if env["CONTEXTUAL_DEBUG_ACTION"] != nil {
			Task {
				// Wait a moment for the app to settle
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				await DebugActionTrigger.runIfTriggered()
			}
		}

		if env["CONTEXTUAL_RUN_PHASE35_4_SELFTEST"] == "1" {
			Task {
				let ok = await Phase35_4SelfTest.run()
				print("[Phase35_4SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_PHASE34_SELFTEST"] == "1" || env["CONTEXTUAL_RUN_WINDOW_DISCOVERY_SELFTEST"] == "1" {
			Task {
				let ok = await WindowDiscoverySelfTest.run()
				print("[WindowDiscoverySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_PHASE35_SELFTEST"] == "1" {
			Task {
				let ok = await Phase35SelfTest.run()
				print("[Phase35SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_PHASE33_SELFTEST"] == "1" {
			Task {
				let ok = await Phase33SelfTest.run()
				print("[Phase33SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_PHASE32_SELFTEST"] == "1" {
			Task {
				let ok = await Phase32SelfTest.run()
				print("[Phase32SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_PHASE31_SELFTEST"] == "1" {
			Task {
				let ok = await Phase31SelfTest.run()
				print("[Phase31SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_PHASE36_SELFTEST"] == "1" {
			Task { @MainActor in
				let phase36 = await Phase36SelfTest.run()
				let livePath = LivePathEnforcementSelfTest.run()
				let phase361 = await Phase361LivePathSelfTest.run()
				let runtimeFriction = RuntimeWorkspaceFrictionSelfTest.run()
				let phase362 = await Phase362SelfTest.run()
				let phase363 = await Phase363SelfTest.run()
				let phase365 = await Phase365SelfTest.run()
				let phase37 = await Phase37SelfTest.run()
				let phase38 = await Phase38SelfTest.run()
				
				var phase39 = false
				if let mbc = self.menuBarController {
					phase39 = await Phase39ProductResetSelfTest.run(appState: appState, menuBarController: mbc)
				} else {
					print("[Phase39SelfTest] FAIL: menuBarController is nil")
				}
				
				let phase40 = await Phase40SelfTest.run()
				let phase41 = await Phase41SelfTest.run()
				let phase42 = await Phase42SelfTest.run()
				let phase43 = await Phase43SelfTest.run()

				let ok = phase36 && livePath && phase361 && runtimeFriction && phase362 && phase363 && phase365 && phase37 && phase38 && phase39 && phase40 && phase41 && phase42 && phase43
				print("[Phase36SelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_SEMANTIC_GROUNDING_SELFTEST"] == "1" {
			Task {
				let ok = await SemanticGroundingSelfTest.run()
				print("[SemanticGroundingSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_MEDIA_SUITABILITY_SELFTEST"] == "1" {
			Task {
				let ok = await MediaSuitabilitySelfTest.run()
				print("[MediaSuitabilitySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_WORKSPACE_MEMORY_SELFTEST"] == "1" {
			Task {
				let ok = await WorkspaceMemorySelfTest.run()
				print("[WorkspaceMemorySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		if env["CONTEXTUAL_RUN_ACTION_ROUTER_SELFTEST"] == "1" {
			Task {
				let ok = await ActionRouterSelfTest.run()
				print("[ActionRouterSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Generated action safety policy self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_GENERATED_ACTION_SAFETY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_GENERATED_ACTION_SAFETY_SELFTEST"] == "1" {
			let ok = GeneratedActionSafetyPolicy.runSelfTest()
			print("[GeneratedActionSafety] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action plan composition self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_ACTION_PLAN_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_ACTION_PLAN_SELFTEST"] == "1" {
			let ok = GeneratedActionPlanBuilder.runSelfTest()
			print("[ActionPlan] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action explainability self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_ACTION_EXPLAINABILITY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_ACTION_EXPLAINABILITY_SELFTEST"] == "1" {
			let ok = GeneratedActionExplanationBuilder.runSelfTest()
			print("[GeneratedActionExplainability] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow-aware proposal ranking self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_WORKFLOW_PROPOSAL_RANKING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_PROPOSAL_RANKING_SELFTEST"] == "1" {
			let ok = WorkflowAwareProposalRanker.runSelfTest()
			print("[WorkflowProposalRank] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow-sensitive action ordering (T16.3): bundled synthetic self-tests.
		// Run with `CONTEXTUAL_RUN_WORKFLOW_ACTION_ORDERING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_ACTION_ORDERING_SELFTEST"] == "1" {
			let ok = WorkflowActionOrderingSelfTest.run()
			print("[WorkflowActionOrdering] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Proposal card context summary self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_PROPOSAL_CONTEXT_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PROPOSAL_CONTEXT_SELFTEST"] == "1" {
			let ok = ProposalContextSummaryBuilder.runSelfTest()
			print("[ProposalContext] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow continuity panel surfacing (T16.8; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_WORKFLOW_CONTINUITY_UI_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_CONTINUITY_UI_SELFTEST"] == "1" {
			let ok = WorkflowContinuityDisplayBuilder.runSelfTest()
			print("[WorkflowContinuityUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Canonical fused context state self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_CANONICAL_CONTEXT_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CANONICAL_CONTEXT_SELFTEST"] == "1" {
			let ok = CanonicalContextState.shared.selfTest()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich context refresh pipeline self-test (synthetic/current metadata-only).
		// Run the app with `CONTEXTUAL_RUN_RICH_REFRESH_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_REFRESH_SELFTEST"] == "1" {
			Task {
				print("[RichContextRefresh] selftest starting")
				let model = ContextModel()
				let req = RichContextRefreshRequest(
					trigger: .debugSelfTest,
					reason: "selftest",
					includeWindowSnapshot: true,
					includeVisualDescriptor: true,
					includeAXContent: true,
					includeTypingActivity: true,
					includePointerActivity: true,
					allowExpensiveSources: true,
					currentContextModel: model,
					isActionExecuting: false,
					currentIntelligenceConfidence: 0.30
				)

				// Start one refresh and cancel it immediately to validate cancellation/stale protection.
				let pipeline = RichContextRefreshPipeline.shared
				let t = Task { await pipeline.refresh(req) }
				try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
				pipeline.cancelCurrent(reason: "selftest_cancel")
				let cancelledResult = await t.value
				print("[RichContextRefresh] selftest cancel wasCancelled=\(cancelledResult.wasCancelled)")

				// Now run a real refresh.
				let result = await pipeline.refresh(req)
				let collected = result.collectedSources.map(\.rawValue).joined(separator: ",")
				let skipped = result.skippedSources.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
				print("[RichContextRefresh] selftest result ok=true cancelled=\(result.wasCancelled) collected=\(collected) skipped=\(skipped) updatedCanonical=\(result.updatedCanonicalState) primary=\(result.fusedPacket?.primarySource.rawValue ?? "nil")")
				NSApp.terminate(nil)
			}
			return true
		}

		// Rich proposal selection self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_RICH_PROPOSAL_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_PROPOSAL_SELFTEST"] == "1" {
			let ok = RichContextProposalSelfTest.run()
			print("[RichProposal] selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Action eligibility self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_ACTION_ELIGIBILITY_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_ACTION_ELIGIBILITY_SELFTEST"] == "1" {
			let ok = ContextAwareActionEligibility.selfTest()
			print("[ActionEligibility] selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Context confidence arbitration self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_ARBITRATION_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_ARBITRATION_SELFTEST"] == "1" {
			let ok = ContextConfidenceArbitrator.shared.selfTest()
			print("[ContextArbitration] selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Adaptive context sampling self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_ADAPTIVE_SAMPLING_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_ADAPTIVE_SAMPLING_SELFTEST"] == "1" {
			let ok = AdaptiveContextSampler.runSelfTest()
			print("[AdaptiveSampling] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Context awareness UI summary self-test (synthetic fused metadata only).
		// Run the app with `CONTEXTUAL_RUN_CONTEXT_AWARENESS_UI_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CONTEXT_AWARENESS_UI_SELFTEST"] == "1" {
			let ok = ContextAwarenessSummaryBuilder.runSelfTest()
			print("[ContextAwarenessUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich context debug summary self-test (synthetic fused metadata only).
		// Run the app with `CONTEXTUAL_RUN_RICH_CONTEXT_DEBUG_UI_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_CONTEXT_DEBUG_UI_SELFTEST"] == "1" {
			let ok = RichContextDebugSummaryBuilder.runSelfTest()
			print("[RichContextDebugUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Dynamic intent debug summary self-test (synthetic metadata only).
		// Run the app with `CONTEXTUAL_RUN_DYNAMIC_INTENT_DEBUG_UI_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_DYNAMIC_INTENT_DEBUG_UI_SELFTEST"] == "1" {
			let ok = DynamicIntentDebugSummaryBuilder.runSelfTest()
			print("[DynamicIntentDebugUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Dynamic action UX display model self-test (synthetic metadata only).
		// Run the app with `CONTEXTUAL_RUN_DYNAMIC_ACTION_UX_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_DYNAMIC_ACTION_UX_SELFTEST"] == "1" {
			let ok = DynamicActionDisplayBuilder.runSelfTest()
			print("[DynamicActionUX] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 17 stability guardrails (T17.10; metadata-only; no UI/capture).
		// Run with `CONTEXTUAL_RUN_PHASE17_STABILITY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PHASE17_STABILITY_SELFTEST"] == "1" {
			let ok = Phase17StabilitySelfTest.run()
			print("[Phase17Stability] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Screen situation + Analyze Screen prompt jargon self-test (synthetic inputs only; no AI, no screenshots).
		// Run the app with `CONTEXTUAL_RUN_SCREEN_SITUATION_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_SCREEN_SITUATION_SELFTEST"] == "1" {
			let sOk = ScreenSituationClassifier.runSelfTest()
			let jOk = RichAnalyzeScreenPromptBuilder.runJargonSelfTest()
			let ok = sOk && jOk
			print("[ScreenSituation] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich Analyze Screen pipeline self-test (prompt build only; no AI calls, no screenshots).
		// Run the app with `CONTEXTUAL_RUN_RICH_ANALYZE_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_ANALYZE_SELFTEST"] == "1" {
			var ctx = ContextModel()
			ctx.activeAppName = "Xcode"
			ctx.activeAppBundleIdentifier = "com.apple.dt.Xcode"
			let ocr = "Xcode\nBuild failed for target\nfunc foo() { return 1 }\n"
			let fused = FusedContextPacket(
				id: UUID(),
				createdAt: Date(),
				primarySource: .selectedText,
				availableSources: [.activeApp, .selectedText, .visualDescriptor],
				staleSources: [],
				appName: "Xcode",
				bundleIdentifier: "com.apple.dt.Xcode",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: true,
				textLength: 120,
				lineCount: 6,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: true,
				hasAXText: true,
				hasWindowSnapshot: true,
				hasVisualDescriptor: true,
				hasTypingActivity: true,
				hasPointerActivity: true,
				visualKinds: [.editor, .dialog],
				uiStructureHints: ["ax_editor_like", "visual_dialog_like"],
				typingState: .idle,
				pointerState: .idle,
				confidence: 0.82,
				freshnessScore: 0.84,
				conflictScore: 0.10,
				isStale: false,
				suppressedSources: [],
				supportingSources: [.axText, .screenOCR],
				arbitrationReasons: ["selftest"],
				debugSummaryMetadata: ["selftest": "1"]
			)
			let meta: [String: String] = [
				"axFragments": "24",
				"axTextLen": "1200",
				"visualKinds": "editor",
				"visualConf": "0.82",
				"visualPanels": "2"
			]
			let built = RichAnalyzeScreenPromptBuilder.build(
				context: ctx,
				ocrText: ocr,
				ocrLineCount: 4,
				fused: fused,
				refreshMeta: meta
			)
			let containsImageLike = built.input.contains("CGImage") || built.input.contains("data:") || built.input.contains("base64")
			let ok = built.input.contains("## What you are doing")
				&& built.input.contains("## Situation profile")
				&& built.input.contains("## Visible text")
				&& RichAnalyzeScreenPromptBuilder.analyzePromptExcludesBannedTokens(built.input)
				&& built.situation.kind == .codeOrEditor
				&& !containsImageLike

			// Conflicting visual kinds + weak OCR must not enable workflow hints in the situation profile.
			let weakOCR = "YouTube\nSkip ads\n"
			let weakMeta: [String: String] = [
				"axFragments": "0",
				"axTextLen": "0",
				"visualKinds": "browser,editor,terminal,dialog",
				"visualConf": "0.35",
				"visualPanels": "1"
			]
			let weakBuilt = RichAnalyzeScreenPromptBuilder.build(
				context: ctx,
				ocrText: weakOCR,
				ocrLineCount: 2,
				fused: fused,
				refreshMeta: weakMeta
			)
			let weakKindOk = weakBuilt.situation.kind == .browserPage || weakBuilt.situation.kind == .videoOrSocial
			let weakOk = weakBuilt.situation.visualEvidenceConflicting
				&& !weakBuilt.situation.shouldUseWorkflow
				&& weakKindOk
				&& weakBuilt.input.contains("Limited readable text: yes")
				&& RichAnalyzeScreenPromptBuilder.analyzePromptExcludesBannedTokens(weakBuilt.input)
				&& !weakBuilt.input.lowercased().contains("likelyworkflow")

			let finalOk = ok && weakOk
			print("[AnalyzeScreenRich] selftest prompt_built ocrChars=\(built.ocrChars) axFragments=\(built.axFragments) visualKinds=\(built.visualKinds.joined(separator: ",")) ok=\(finalOk)")
			if finalOk {
				print("[Phase14Tuning] tuned reason=analyze_prompt")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Proposal timing self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_PROPOSAL_TIMING_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_PROPOSAL_TIMING_SELFTEST"] == "1" {
			Task { @MainActor in
				let okGate = ProposalTimingGate.selfTest()

				// Deferred-cancel safety self-test: schedule a deferred refresh, then invalidate selection before it fires.
				let sampleText = String(repeating: "a", count: TriggerEngine.selectedTextMinCharacterCount)
				self.processSourceEvent(.sourceChanged(.selectedTextChanged(text: sampleText)))
				let gen = self.contextPipelineGeneration
				self.scheduleDeferredProposalRefreshIfNeeded(retryAfter: 0.15, originalGeneration: gen)

				DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
					self.processSourceEvent(.sourceChanged(.selectedTextChanged(text: nil)))
				}

				try? await Task.sleep(nanoseconds: 300_000_000) // 0.30s

				print("[ProposalTiming] selftest ok=\(okGate)")
				NSApp.terminate(nil)
			}
			return true
		}

		// Self-test hook (no UI, no continuous polling).
		// Run the app with `CONTEXTUAL_RUN_AX_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_AX_SELFTEST"] == "1" {
			print("[AXContent] selftest starting")
			let ok = AXWindowContentSource.shared._selfTest()
			print("[AXContent] selftest finished ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Typing activity DEBUG self-test (metadata-only; uses synthetic events to be non-interactive).
		// Run the app with `CONTEXTUAL_RUN_TYPING_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_TYPING_SELFTEST"] == "1" {
			print("[TypingActivity] selftest starting")
			let src = TypingActivitySource.shared
			src.reset()
			src.startMonitoring()

			func logSnapshot(_ label: String) {
				let ctx = src.currentContext()
				let s = String(format: "%.2f", ctx.estimatedEditingActivity)
				let idle = String(format: "%.1f", ctx.idleDuration)
				print("[TypingActivity] selftest \(label) state=\(ctx.typingState.rawValue) intensity=\(ctx.burstIntensity.rawValue) events=\(ctx.recentEventCount) active=\(ctx.isTypingActive) idle=\(idle)s activity=\(s)")
			}

			logSnapshot("initial")

			for _ in 0..<6 { src.recordSyntheticKeyEventForTesting() }
			logSnapshot("after_6")
			for _ in 0..<10 { src.recordSyntheticKeyEventForTesting() }
			logSnapshot("after_16")

			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				logSnapshot("after_wait_1s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
				logSnapshot("after_wait_3s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
				logSnapshot("after_wait_6s")
				src.stopMonitoring()
				print("[TypingActivity] selftest finished")
				NSApp.terminate(nil)
			}
			return true
		}

		// Pointer activity DEBUG self-test (metadata-only; uses synthetic events to be non-interactive).
		// Run the app with `CONTEXTUAL_RUN_POINTER_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_POINTER_SELFTEST"] == "1" {
			print("[PointerActivity] selftest starting")
			let src = PointerActivitySource.shared
			src.reset()
			src.startMonitoring()

			func logSnapshot(_ label: String) {
				let ctx = src.currentContext()
				let idle = String(format: "%.1f", ctx.idleDuration)
				let focus = String(format: "%.2f", ctx.estimatedFocusIntensity)
				print("[PointerActivity] selftest \(label) state=\(ctx.pointerState.rawValue) moveEvents=\(ctx.recentMoveEventCount) clickEvents=\(ctx.recentClickEventCount) moveIntensity=\(ctx.movementBurstIntensity.rawValue) clickIntensity=\(ctx.clickBurstIntensity.rawValue) active=\(ctx.isPointerActive) idle=\(idle)s focus=\(focus)")
			}

			logSnapshot("initial")

			for _ in 0..<12 { src.recordSyntheticMoveEventForTesting() }
			logSnapshot("after_moves")
			for _ in 0..<3 { src.recordSyntheticClickEventForTesting() }
			logSnapshot("after_clicks")
			for _ in 0..<8 { src.recordSyntheticMoveEventForTesting() }
			for _ in 0..<2 { src.recordSyntheticScrollEventForTesting() }
			for _ in 0..<4 { src.recordSyntheticClickEventForTesting() }
			logSnapshot("after_burst_mix")

			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				logSnapshot("after_wait_1s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
				logSnapshot("after_wait_3s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
				logSnapshot("after_wait_6s")
				src.stopMonitoring()
				print("[PointerActivity] selftest finished")
				NSApp.terminate(nil)
			}
			return true
		}

		// Context fusion DEBUG self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_FUSION_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_FUSION_SELFTEST"] == "1" {
			_ = ContextFusionEngine.shared._selfTest()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Context freshness DEBUG self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_FRESHNESS_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_FRESHNESS_SELFTEST"] == "1" {
			_ = ContextFusionEngine.shared._freshnessSelfTest()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich context debug logger self-test (metadata-only).
		// Run the app with `CONTEXTUAL_RUN_CONTEXT_DEBUG_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CONTEXT_DEBUG_SELFTEST"] == "1" {
			print("[ContextDebug] selftest starting")
			let ok = ContextDebugLogger.shared.selfTest()
			print("[ContextDebug] selftest finished ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// T18.5: Chime-in policy self-test (deterministic; no I/O).
		// Run the app with `CONTEXTUAL_RUN_CHIMEIN_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CHIMEIN_SELFTEST"] == "1" {
			print("[ChimeInPolicy] selftest starting")
			let policyOk = ContextualChimeInPolicy.runSelfTest()
			let noveltyOk = ProposalNoveltyTracker.runSelfTest()
			let presenterOk = GeneratedExecutionResultPresenter.runSelfTest()
			let ok = policyOk && noveltyOk && presenterOk
			print("[ChimeInPolicy] selftest finished ok=\(ok) policy=\(policyOk) novelty=\(noveltyOk) presenter=\(presenterOk)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Run with `CONTEXTUAL_RUN_ACTIVATOR_SELFTEST=1` to validate proposal activation.
		if env["CONTEXTUAL_RUN_ACTIVATOR_SELFTEST"] == "1" {
			let ok = GeneratedExecutionProposalActivatorSelfTest.run()
			print("[GeneratedExecutionProposalActivatorSelfTest] env selftest ok=\(ok)")
			fflush(nil)
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
			return true
		}

		// Run with `CONTEXTUAL_RUN_TASK_INFERENCE_SELFTEST=1` to validate parser + composer (no live AI).
		if env["CONTEXTUAL_RUN_TASK_INFERENCE_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await TaskInferenceSelfTest.run()
				print("[TaskInferenceSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_PROPOSAL_FAILURE_DIAG_SELFTEST=1` to validate failure reason labels.
		if env["CONTEXTUAL_RUN_PROPOSAL_FAILURE_DIAG_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await GeneratedProposalFailureDiagnosticsSelfTest.run()
				print("[GeneratedProposalFailureDiagnosticsSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_AGENTIC_RUNTIME_SELFTEST=1` to validate Phase 4B routing and shell.
		if env["CONTEXTUAL_RUN_AGENTIC_RUNTIME_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await AgenticRuntimeSelfTest.run()
				print("[AgenticRuntimeSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_AGENTIC_LOOP_SELFTEST=1` to validate Phase 4C/4D observe→decide→act loop.
		if env["CONTEXTUAL_RUN_AGENTIC_LOOP_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await AgenticLoopSelfTest.run()
				print("[AgenticLoopSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_AGENTIC_CONTROL_SELFTEST=1` to validate Phase 4D controlled interactions.
		if env["CONTEXTUAL_RUN_AGENTIC_CONTROL_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await AgenticControlSelfTest.run()
				print("[AgenticControlSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_PERCEPTION_REFRESH_SELFTEST=1` to validate Phase 4E perception refresh.
		if env["CONTEXTUAL_RUN_PERCEPTION_REFRESH_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await AgenticPerceptionRefreshSelfTest.run()
				print("[AgenticPerceptionRefreshSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_AGENTIC_INTENT_GROUNDING_SELFTEST=1` to validate Phase 4F intent grounding.
		if env["CONTEXTUAL_RUN_AGENTIC_INTENT_GROUNDING_SELFTEST"] == "1" {
			let ok = AgenticIntentGroundingSelfTest.run()
			print("[AgenticIntentGroundingSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Run with `CONTEXTUAL_RUN_STATEFUL_AGENTIC_LOOP_SELFTEST=1` to validate Phase 4S stateful loop logic.
		if env["CONTEXTUAL_RUN_STATEFUL_AGENTIC_LOOP_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await StatefulAgenticLoopSelfTest.run()
				print("[StatefulAgenticLoopSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_EVIDENCE_QUALITY_GATE_SELFTEST=1` to validate Phase 4T evidence quality gate logic.
		if env["CONTEXTUAL_RUN_EVIDENCE_QUALITY_GATE_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await EvidenceQualityGateSelfTest.run()
				print("[EvidenceQualityGateSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_AGENTIC_EVIDENCE_GATE_SELFTEST=1` to validate evidence requirements/gate.
		if env["CONTEXTUAL_RUN_AGENTIC_EVIDENCE_GATE_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await AgenticEvidenceGateSelfTest.run()
				print("[AgenticEvidenceGateSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 4P — Run with `CONTEXTUAL_RUN_PROPOSAL_CONTEXT_ISOLATION_SELFTEST=1`
		// to validate proposal-context isolation, stale-entity rejection, and
		// planner-recovery validation consistency.
		if env["CONTEXTUAL_RUN_PROPOSAL_CONTEXT_ISOLATION_SELFTEST"] == "1" {
			let ok = ProposalContextIsolationSelfTest.run()
			print("[ProposalContextIsolationSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 4Q — Run with `CONTEXTUAL_RUN_PLANNER_CAPABILITY_ENVELOPE_SELFTEST=1`
		// to validate runtime capability envelope, strict-retry prompt, and
		// [CapabilityRepair] log family.
		if env["CONTEXTUAL_RUN_PLANNER_CAPABILITY_ENVELOPE_SELFTEST"] == "1" {
			let ok = PlannerCapabilityEnvelopeSelfTest.run()
			print("[PlannerCapabilityEnvelopeSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 4R — Run with `CONTEXTUAL_RUN_PARTIAL_PLANNER_RECOVERY_SELFTEST=1`
		// to validate partial-JSON salvage trailing-candidate recovery and the
		// router grounding-sufficiency upgrade.
		if env["CONTEXTUAL_RUN_PARTIAL_PLANNER_RECOVERY_SELFTEST"] == "1" {
			let ok = PartialPlannerRecoverySelfTest.run()
			print("[PartialPlannerRecoverySelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 4S — Run with `CONTEXTUAL_RUN_FAST_VISIBILITY_QUALITY_SELFTEST=1`
		// to validate the fast-visibility quality gate, weak/strong replacement
		// signal, and execution-time stale-goal detection.
		if env["CONTEXTUAL_RUN_FAST_VISIBILITY_QUALITY_SELFTEST"] == "1" {
			let ok = FastVisibilityQualitySelfTest.run()
			print("[FastVisibilityQualitySelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 4T — Run with `CONTEXTUAL_RUN_TOLERANT_PARTIAL_RECOVERY_SELFTEST=1`
		// to validate tolerant partial planner-JSON recovery (caps sanitization,
		// incomplete-object recovery) and recent_changes weak-title scrubbing.
		if env["CONTEXTUAL_RUN_TOLERANT_PARTIAL_RECOVERY_SELFTEST"] == "1" {
			let ok = TolerantPartialRecoverySelfTest.run()
			print("[TolerantPartialRecoverySelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 4U — Run with `CONTEXTUAL_RUN_AGENTIC_RUNTIME_QUALITY_SELFTEST=1`
		// to validate compare→extract pivot, anchored price resolver, and the
		// product-title cleanup synthesizer.
		if env["CONTEXTUAL_RUN_AGENTIC_RUNTIME_QUALITY_SELFTEST"] == "1" {
			let ok = AgenticRuntimeQualitySelfTest.run()
			print("[AgenticRuntimeQualitySelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 4R — Run with `CONTEXTUAL_RUN_RUNTIME_GROUNDING_PRESERVATION_SELFTEST=1`
		// to validate grounded evidence preservation + terminal-step control guard.
		if env["CONTEXTUAL_RUN_RUNTIME_GROUNDING_PRESERVATION_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await RuntimeGroundingPreservationSelfTest.run()
				print("[RuntimeGroundingPreservationSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_EVIDENCE_EXTRACTION_BRIDGE_SELFTEST=1` to validate extraction bridge.
		if env["CONTEXTUAL_RUN_EVIDENCE_EXTRACTION_BRIDGE_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await AgenticEvidenceExtractionBridgeSelfTest.run()
				print("[AgenticEvidenceExtractionBridgeSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_EMAIL_REVIEW_EVIDENCE_SELFTEST=1` to validate email-domain evidence families.
		if env["CONTEXTUAL_RUN_EMAIL_REVIEW_EVIDENCE_SELFTEST"] == "1" {
			Task {
				await EmailReviewEvidenceSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_EXECUTION_FOCUS_HANDOFF_SELFTEST=1` to validate focus handoff and runtime guards.
		if env["CONTEXTUAL_RUN_EXECUTION_FOCUS_HANDOFF_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await ExecutionFocusHandoffSelfTest.run()
				print("[ExecutionFocusHandoffSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_ROUTER_EMPTY_ESCALATION_SELFTEST=1` to validate Phase 4U router empty-escalation recovery logic.
		if env["CONTEXTUAL_RUN_ROUTER_EMPTY_ESCALATION_SELFTEST"] == "1" {
			Task {
				let ok = await RouterEmptyEscalationSelfTest.run()
				print("[RouterEmptyEscalationSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_GOAL_EVIDENCE_ALIGNMENT_SELFTEST=1` to validate Phase 4U goal/evidence alignment logic.
		if env["CONTEXTUAL_RUN_GOAL_EVIDENCE_ALIGNMENT_SELFTEST"] == "1" {
			GoalEvidenceAlignmentSelfTest.run()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Run with `CONTEXTUAL_RUN_EVIDENCE_STATE_CORRECTNESS_SELFTEST=1` to validate Phase 4V evidence correctness logic.
		if env["CONTEXTUAL_RUN_EVIDENCE_STATE_CORRECTNESS_SELFTEST"] == "1" {
			Task {
				await EvidenceStateCorrectnessSelfTest.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Run with `CONTEXTUAL_RUN_ARCHITECTURAL_REGRESSION_SELFTEST=1` to validate architectural regressions.
		if env["CONTEXTUAL_RUN_ARCHITECTURAL_REGRESSION_SELFTEST"] == "1" {
			let ok = ArchitecturalRegressionSelfTest.run()
			print("[ArchitecturalRegressionSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 22.1 — Run with `CONTEXTUAL_RUN_ENTITY_GROUNDING_SELFTEST=1` to validate entity grounding.
		if env["CONTEXTUAL_RUN_ENTITY_GROUNDING_SELFTEST"] == "1" {
			let ok = EntityGroundingSelfTest.run()
			print("[EntityGroundingSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 22.1 — Run with `CONTEXTUAL_RUN_APP_CONTEXT_SELFTEST=1` to validate app context analysis.
		if env["CONTEXTUAL_RUN_APP_CONTEXT_SELFTEST"] == "1" {
			let ok = AppContextSelfTest.run()
			print("[AppContextSelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 22.1 — Run with `CONTEXTUAL_RUN_CONTEXT_SOURCE_PRIORITY_SELFTEST=1` to validate source priority.
		if env["CONTEXTUAL_RUN_CONTEXT_SOURCE_PRIORITY_SELFTEST"] == "1" {
			let ok = ContextSourcePrioritySelfTest.run()
			print("[ContextSourcePrioritySelfTest] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 22.1 — Run with `CONTEXTUAL_RUN_ENTERTAINMENT_POLICY_SELFTEST=1` to validate entertainment suppression.
		if env["CONTEXTUAL_RUN_ENTERTAINMENT_POLICY_SELFTEST"] == "1" {
			Task {
				let ok = await EntertainmentPolicySelfTest.run()
				print("[EntertainmentPolicySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 22.1 — Run with `CONTEXTUAL_RUN_COMPARTMENT_TRANSITION_SELFTEST=1` to validate compartment transitions.
		if env["CONTEXTUAL_RUN_COMPARTMENT_TRANSITION_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await CompartmentTransitionSelfTest.run()
				print("[CompartmentTransitionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 22.2 — Run with `CONTEXTUAL_RUN_ENTITY_LOOKUP_SELFTEST=1` to validate OG metadata parsing and safety guards.
		if env["CONTEXTUAL_RUN_ENTITY_LOOKUP_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = EntityLookupSelfTest.run()
				print("[EntityLookupSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 22.2 — Run with `CONTEXTUAL_RUN_OPPORTUNITY_REASONER_SELFTEST=1` to validate dynamic capability scoring.
		if env["CONTEXTUAL_RUN_OPPORTUNITY_REASONER_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = OpportunityReasonerSelfTest.run()
				print("[OpportunityReasonerSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 22.2 — Run with `CONTEXTUAL_RUN_OPPORTUNITY_NOVELTY_SELFTEST=1` to validate novelty tracking and diversity.
		if env["CONTEXTUAL_RUN_OPPORTUNITY_NOVELTY_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = OpportunityNoveltySelfTest.run()
				print("[OpportunityNoveltySelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 26/26.1 — Run with `CONTEXTUAL_RUN_FRICTION_SELFTEST=1` to validate friction detection, workspace patterns, and friction action execution.
		if env["CONTEXTUAL_RUN_FRICTION_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await FrictionEngineSelfTest.run()
				print("[FrictionEngineSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		// Phase 26.3 — Run with `CONTEXTUAL_RUN_CHEAP_ALWAYS_ON_PORTFOLIO_SELFTEST=1` to validate cheap always-on surfacing.
		if env["CONTEXTUAL_RUN_CHEAP_ALWAYS_ON_PORTFOLIO_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await CheapAlwaysOnPortfolioSelfTest.run()
				print("[CheapAlwaysOnPortfolioSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		return false
	}
}

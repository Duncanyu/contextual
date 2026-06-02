import Foundation

/// Phase B self-tests — drive deterministic temporal sequences through the
/// pipeline and verify the inferred workflow.
///
/// **Critical design note:** these tests exercise the compressor + stabilizer
/// + inference contract using a **signal-driven test backend**, not the live
/// qwen call (which is non-deterministic and may not be reachable in CI). The
/// stub backend reads ONLY temporal packet fields (term frequencies, transition
/// counts, activity patterns, idle patterns) — it never matches on raw app
/// names. This validates that:
///
/// 1. The compressor surfaces enough signal from event sequences.
/// 2. The stabilizer doesn't undo correct classifications.
/// 3. The pipeline contract end-to-end is sound.
///
/// The live qwen model is exercised separately at runtime; here we prove the
/// packet carries the information any classifier would need.
///
/// Trigger:
///   CONTEXTUAL_RUN_WORKFLOW_INFERENCE_SELFTEST=1
public enum WorkflowInferenceSelfTest {

    public static func run() async -> Bool {
        print("[WorkflowInferenceSelfTest] starting")

        var failures: [String] = []

        enum Expectation {
            case exact(String)
            case notIdle
        }

        let cases: [(name: String, events: [ContextEvent], expected: Expectation)] = [
            ("studying_sequence",  Fixtures.studyingSequence(),  .exact("studying")),
            ("gaming_sequence",    Fixtures.gamingSequence(),    .exact("gaming")),
            ("debugging_sequence", Fixtures.debuggingSequence(), .exact("debugging")),
            ("research_sequence",  Fixtures.researchSequence(),  .exact("researching")),
            ("comparing_sequence", Fixtures.comparingSequence(), .exact("comparing")),
            ("idle_sequence",      Fixtures.idleSequence(),      .exact("idle")),
            // B.1.6 regression — the exact B.1.5 failure: Gmail (early, lots
            // of repeats) followed by Amazon (recent, fewer repeats). Without
            // recency weighting + fresh-shift correction this returns
            // "writing"/"emailing"; with B.1.6 it must return "shopping" or
            // the comparing-family fallback.
            ("shopping_after_gmail_recency_weighted",
             Fixtures.shoppingAfterGmailSequence(),
             .exact("shopping")),
            // B.1.7 regression — high browser title churn with no typing/pointer
            // is ACTIVE browsing/research/shopping/comparing, not idle.
            ("active_title_churn_not_idle",
             Fixtures.activeTitleChurnSequence(),
             .notIdle),
        ]

        for tc in cases {
            let now = tc.events.last?.timestamp ?? Date()
            let coordinator = WorkflowIntelligenceCoordinator(
                stream: ContextEventStream(),
                backend: SignalDrivenStubBackend(),
                initial: .empty
            )
            for ev in tc.events { await coordinator.recordEvent(ev) }
            // Two ticks so the stabilizer can confirm medium-confidence shifts.
            _ = await coordinator.tick(now: now)
            let stabilized = await coordinator.tick(now: now)

            let got = stabilized.workflowType.rawValue
            let pass: Bool = {
                switch tc.expected {
                case .exact(let label):
                    return got == label
                case .notIdle:
                    return got != "idle"
                }
            }()

            if pass {
                print("[WorkflowInferenceSelfTest] pass case=\(tc.name)")
            } else {
                let expectedDesc: String = {
                    switch tc.expected {
                    case .exact(let label): return label
                    case .notIdle: return "not_idle"
                    }
                }()
                print("[WorkflowInferenceSelfTest] fail case=\(tc.name) expected=\(expectedDesc) got=\(got)")
                failures.append(tc.name)
            }
        }

		// MARK: - Guard regression tests (B.1.8)
		do {
			let events = Fixtures.activeShoppingTitleChurnSequence()
			let now = events.last?.timestamp ?? Date()
			let buffer = TemporalContextBuffer.build(from: events, now: now)
			let packet = TemporalContextCompressor.compress(buffer: buffer, now: now)

			// 1) Unsupported high-confidence label must be corrected away from reading.
			let fixedReading = AmbientWorkflowInferenceResult(
				workflow: "reading",
				confidence: 1.0,
				why: "recent_title_changes=11",
				evidence: [],
				suggestedIntentHints: [],
				uncertainty: ""
			)
			let corrected = await WorkflowInferenceModel.infer(packet: packet, backend: FixedBackend(result: fixedReading))
			if corrected.workflow != "reading" {
				print("[WorkflowInferenceSelfTest] pass case=unsupported_high_confidence_label_downgraded")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=unsupported_high_confidence_label_downgraded expected=not_reading got=reading")
				failures.append("unsupported_high_confidence_label_downgraded")
			}

			// 2) Generic title churn must not yield high confidence reading/writing/idle.
			let churnOnly = AmbientWorkflowInferenceResult(
				workflow: "writing",
				confidence: 1.0,
				why: "recent_title_changes=9",
				evidence: [],
				suggestedIntentHints: [],
				uncertainty: ""
			)
			let churnGuarded = await WorkflowInferenceModel.infer(packet: packet, backend: FixedBackend(result: churnOnly))
			// Accept either a confidence downgrade OR a provenance-based correction away from writing/idle/reading.
			if churnGuarded.workflow != "writing" || churnGuarded.confidence <= 0.5 || churnGuarded.workflow == "unknown" {
				print("[WorkflowInferenceSelfTest] pass case=generic_title_churn_not_high_confidence")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=generic_title_churn_not_high_confidence got_workflow=\(churnGuarded.workflow) conf=\(String(format: "%.2f", churnGuarded.confidence))")
				failures.append("generic_title_churn_not_high_confidence")
			}

			// 3) B.1.9 regression: model returns writing confidence 1.00 but packet has Amazon/Anker shopping cues.
			let writingPkt = AmbientWorkflowInferenceResult(
				workflow: "writing",
				confidence: 1.0,
				why: "writing some articles",
				evidence: [],
				suggestedIntentHints: [],
				uncertainty: ""
			)
			let writingGuarded = await WorkflowInferenceModel.infer(packet: packet, backend: FixedBackend(result: writingPkt))
			if writingGuarded.workflow != "writing" && (writingGuarded.workflow == "shopping" || writingGuarded.workflow == "comparing") {
				print("[WorkflowInferenceSelfTest] pass case=b19_writing_corrected_to_shopping_or_comparing")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=b19_writing_corrected_to_shopping_or_comparing expected=shopping_or_comparing got=\(writingGuarded.workflow)")
				failures.append("b19_writing_corrected_to_shopping_or_comparing")
			}

            // Phase 20B: Deterministic Fallback on Model Failure
            struct TimeoutBackend: WorkflowInferenceBackend {
                func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult? {
                    return nil // simulates timeout/cancel
                }
            }
            let fallbackResult = await WorkflowInferenceModel.infer(packet: packet, backend: TimeoutBackend())
            if fallbackResult.workflow == "shopping" && fallbackResult.why == "deterministic_temporal_fallback" {
                print("[WorkflowInferenceSelfTest] pass case=phase20b_model_timeout_triggers_deterministic_fallback")
            } else {
                print("[WorkflowInferenceSelfTest] fail case=phase20b_model_timeout_triggers_deterministic_fallback got=\(fallbackResult.workflow)")
                failures.append("phase20b_model_timeout_triggers_deterministic_fallback")
            }

			// 4) B.1.10 regression: model returns zero-support high confidence label (writing), guard corrects to shopping, coordinator ticks once, stabilizer commits shopping immediately.
			let b110Coordinator = WorkflowIntelligenceCoordinator(
				stream: ContextEventStream(),
				backend: FixedBackend(result: writingPkt),
				initial: .empty
			)
			for ev in events { await b110Coordinator.recordEvent(ev) }
			let b110State = await b110Coordinator.tick(now: now)
			if b110State.workflowType == .shopping
			   && b110State.provenanceCorrected == true
			   && b110State.correctionStrength == "strong"
			   && b110State.stabilityScore == 0.5 {
				print("[WorkflowInferenceSelfTest] pass case=b110_provenance_corrected_immediate_commit")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=b110_provenance_corrected_immediate_commit expected=shopping(corrected=true,strength=strong,stability=0.5) got=\(b110State.workflowType.rawValue)(corrected=\(b110State.provenanceCorrected ?? false),strength=\(b110State.correctionStrength ?? "nil"),stability=\(b110State.stabilityScore))")
				failures.append("b110_provenance_corrected_immediate_commit")
			}

			// MARK: - Validation & Confidence Self-Tests (Phase B.2)
			
			// 1) workflow_volatility_detection
			let volatilityEval = WorkflowEvaluation()
			let workflows: [AmbientWorkflowType] = [.shopping, .browsing, .shopping, .browsing, .shopping, .browsing]
			var volScore = 0.0
			for (i, wf) in workflows.enumerated() {
				let state = WorkflowState(
					workflowType: wf,
					confidence: 0.8,
					evidence: ["test"],
					uncertainty: "",
					startedAt: now,
					lastUpdatedAt: now,
					stabilityScore: 0.5,
					dominantApps: [],
					repeatedTerms: [],
					recentTransitions: [],
					suggestedIntentHints: [],
					sourcePacketHash: "",
					provenanceCorrected: false,
					volatilityScore: 0.0
				)
				volScore = await volatilityEval.record(
					stabilized: state,
					candidate: state,
					now: now.addingTimeInterval(Double(i) * 10),
					contextShiftDetected: false
				)
			}
			
			let changesCount = await volatilityEval.getVolatilityChangesCount()
			if changesCount == 5 && volScore == 0.5 {
				print("[WorkflowInferenceSelfTest] pass case=workflow_volatility_detection")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=workflow_volatility_detection expected=5 changes and 0.5 volScore, got=\(changesCount) and \(volScore)")
				failures.append("workflow_volatility_detection")
			}

			// 2) workflow_trust_score
			let trustUnknown = WorkflowState.empty.workflowTrustScore
			
			let perfectState = WorkflowState(
				workflowType: .shopping,
				confidence: 1.0,
				evidence: ["amazon"],
				uncertainty: "",
				startedAt: now,
				lastUpdatedAt: now,
				stabilityScore: 1.0,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: false,
				volatilityScore: 0.0
			)
			let trustPerfect = perfectState.workflowTrustScore
			
			let volatileState = WorkflowState(
				workflowType: .shopping,
				confidence: 0.7,
				evidence: ["amazon"],
				uncertainty: "",
				startedAt: now,
				lastUpdatedAt: now,
				stabilityScore: 0.4,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: false,
				volatilityScore: 0.5
			)
			let trustVolatile = volatileState.workflowTrustScore
			
			let correctedState = WorkflowState(
				workflowType: .shopping,
				confidence: 0.75,
				evidence: ["amazon"],
				uncertainty: "",
				startedAt: now,
				lastUpdatedAt: now,
				stabilityScore: 0.5,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: true,
				volatilityScore: 0.0
			)
			let trustCorrected = correctedState.workflowTrustScore
			
			let isUnknownOk = trustUnknown == 0.0
			let isPerfectOk = abs(trustPerfect - 1.0) < 1e-9
			let isVolatileOk = abs(trustVolatile - 0.49) < 1e-9
			let isCorrectedOk = abs(trustCorrected - 0.75) < 1e-9
			
			if isUnknownOk && isPerfectOk && isVolatileOk && isCorrectedOk {
				print("[WorkflowInferenceSelfTest] pass case=workflow_trust_score")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=workflow_trust_score unknown=\(trustUnknown) perfect=\(trustPerfect) volatile=\(trustVolatile) corrected=\(trustCorrected)")
				failures.append("workflow_trust_score")
			}

			// 3) workflow_duration_tracking
			let durationEval = WorkflowEvaluation()
			let baseTime = Date()
			
			let state1 = WorkflowState(
				workflowType: .shopping,
				confidence: 0.8,
				evidence: ["test"],
				uncertainty: "",
				startedAt: baseTime,
				lastUpdatedAt: baseTime,
				stabilityScore: 0.5,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: false,
				volatilityScore: 0.0
			)
			await durationEval.record(stabilized: state1, candidate: state1, now: baseTime, contextShiftDetected: false)
			
			let state2 = WorkflowState(
				workflowType: .shopping,
				confidence: 0.7,
				evidence: ["test"],
				uncertainty: "",
				startedAt: baseTime,
				lastUpdatedAt: baseTime.addingTimeInterval(20),
				stabilityScore: 0.5,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: false,
				volatilityScore: 0.0
			)
			await durationEval.record(stabilized: state2, candidate: state2, now: baseTime.addingTimeInterval(20), contextShiftDetected: false)
			
			let state3 = WorkflowState(
				workflowType: .browsing,
				confidence: 0.6,
				evidence: ["test"],
				uncertainty: "",
				startedAt: baseTime.addingTimeInterval(40),
				lastUpdatedAt: baseTime.addingTimeInterval(40),
				stabilityScore: 0.5,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: false,
				volatilityScore: 0.0
			)
			await durationEval.record(stabilized: state3, candidate: state3, now: baseTime.addingTimeInterval(40), contextShiftDetected: false)
			
			let completedDurations = await durationEval.getCompletedSessionDurations()
			if completedDurations.count == 1 && completedDurations[0] == 40.0 {
				print("[WorkflowInferenceSelfTest] pass case=workflow_duration_tracking")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=workflow_duration_tracking count=\(completedDurations.count) duration=\(completedDurations.first ?? -1)")
				failures.append("workflow_duration_tracking")
			}

			// 4) workflow_correction_tracking
			let corrEval = WorkflowEvaluation()
			let tick1 = WorkflowState.empty
			await corrEval.record(stabilized: tick1, candidate: tick1, now: now, contextShiftDetected: false)
			
			let tick2 = WorkflowState(
				workflowType: .shopping,
				confidence: 0.75,
				evidence: ["test"],
				uncertainty: "",
				startedAt: now,
				lastUpdatedAt: now,
				stabilityScore: 0.5,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: true,
				volatilityScore: 0.0
			)
			await corrEval.record(stabilized: tick2, candidate: tick2, now: now, contextShiftDetected: false)
			
			let tick3 = WorkflowState(
				workflowType: .comparing,
				confidence: 0.8,
				evidence: ["test"],
				uncertainty: "",
				startedAt: now,
				lastUpdatedAt: now,
				stabilityScore: 0.5,
				dominantApps: [],
				repeatedTerms: [],
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "",
				provenanceCorrected: false,
				volatilityScore: 0.0
			)
			await corrEval.record(stabilized: tick3, candidate: tick3, now: now, contextShiftDetected: false)
			
			let rates = await corrEval.getDiagnosticRates()
			let isUnkRateOk = abs(rates.unknownRate - 0.333333) < 0.01
			let isCorrRateOk = abs(rates.correctionRate - 0.333333) < 0.01
			
			if isUnkRateOk && isCorrRateOk {
				print("[WorkflowInferenceSelfTest] pass case=workflow_correction_tracking")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=workflow_correction_tracking rates=\(rates)")
				failures.append("workflow_correction_tracking")
			}

			// 1) workflow_inference_priority_over_goal_generator
			let backpressure = LocalAIBackpressure.shared
			let acqGoal = await backpressure.acquire(purpose: "goal_generator")
			if acqGoal {
				let acqWorkflow = await backpressure.acquire(purpose: "workflow_inference")
				if acqWorkflow {
					print("[WorkflowInferenceSelfTest] pass case=workflow_inference_priority_over_goal_generator")
				} else {
					print("[WorkflowInferenceSelfTest] fail case=workflow_inference_priority_over_goal_generator expected=true got=false")
					failures.append("workflow_inference_priority_over_goal_generator")
				}
				await backpressure.release(purpose: "workflow_inference")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=workflow_inference_priority_over_goal_generator setup_failed")
				failures.append("workflow_inference_priority_over_goal_generator")
			}

			// 2) phase_b_validation_disables_goal_generation
			setenv("CONTEXTUAL_PHASE_B_VALIDATION_MODE", "1", 1)
			let dummySnap = CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Firefox",
				windowTitle: "Swift docs - Mozilla Firefox",
				inferredWorkflow: .research,
				workflowConfidence: 0.5,
				generatedAt: Date(),
				freshnessScore: 0.5,
				packetIsStale: false
			)
			let engineResult = await DynamicGeneratedProposalEngine.shared.generateProposals(
				snapshot: dummySnap,
				existingStaticActions: [],
				reusableActions: []
			)
			unsetenv("CONTEXTUAL_PHASE_B_VALIDATION_MODE")
			
			// Phase B validation mode disables goal generation via the gate path,
			// which the engine surfaces as `status == .quietByGate`. (Equality on
			// the full `.quiet` constant fails because `createdAt` differs per
			// invocation — the status enum is the contract.)
			if engineResult.status == .quietByGate {
				print("[WorkflowInferenceSelfTest] pass case=phase_b_validation_disables_goal_generation")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=phase_b_validation_disables_goal_generation expected=quietByGate got=\(engineResult.status)")
				failures.append("phase_b_validation_disables_goal_generation")
			}

			// 3) agentic_hook_quarantined_by_default
			let agenticCandidate = GeneratedExecutionProposalCandidate(
				id: "agentic:test_proposal",
				title: "Create a build plan based on latest",
				description: "agentic task",
				source: .hookComposer,
				workflowType: .research,
				intentType: .explain,
				confidence: 0.9,
				interruptionCost: 0.2,
				explainabilitySummary: "hook_composer_agentic",
				expectedOutputSummary: "Task plan output",
				requiredContextTypes: [.textSnippet],
				executionAction: nil,
				generatedActionId: nil,
				primitiveSignature: "agentic_test",
				isExecutableGeneratedProposal: true
			)
			let inputSnap = CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Firefox",
				windowTitle: "Swift docs - Mozilla Firefox",
				inferredWorkflow: .research,
				workflowConfidence: 0.8,
				generatedAt: Date(),
				freshnessScore: 0.8,
				packetIsStale: false
			)
			let agenticActivation = GeneratedExecutionProposalActivator.activateProposals(
				input: GeneratedExecutionProposalActivationInput(
					staticActionIds: [],
					generatedExecutionCandidates: [agenticCandidate],
					snapshot: inputSnap,
					useLLMGeneratedCandidatesOnly: true,
					suppressStaticProposalFallback: true
				)
			)
			if agenticActivation.visibleProposals.isEmpty && agenticActivation.floatingGeneratedProposalId == nil {
				print("[WorkflowInferenceSelfTest] pass case=agentic_hook_quarantined_by_default")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=agentic_hook_quarantined_by_default visible=\(agenticActivation.visibleProposals.count) float=\(String(describing: agenticActivation.floatingGeneratedProposalId))")
				failures.append("agentic_hook_quarantined_by_default")
			}

			// 4) product_page_rejects_dev_vocabulary
			let shoppingIsolated = IsolatedProposalContext(
				appName: "Safari",
				bundleIdentifier: "com.apple.Safari",
				windowTitle: "Anker Prime 100W Power Bank - Amazon.com",
				selectedText: nil,
				ocrExcerpt: "Price: $99.99 list price add to cart",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title"],
				excludedSources: []
			)
			
			let devVocabValidation = ProposalCapabilityValidator.validate(
				title: "Find a compatible version of the latest Anker Prime build plan",
				goal: "List all available Anker Prime builds in the repository",
				isolated: shoppingIsolated,
				stage: "selftest"
			)
			
			let xcodeIsolated = IsolatedProposalContext(
				appName: "Xcode",
				bundleIdentifier: "com.apple.dt.Xcode",
				windowTitle: "LocalAIBackpressure.swift",
				selectedText: nil,
				ocrExcerpt: "import Foundation",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title"],
				excludedSources: []
			)
			let xcodeValidation = ProposalCapabilityValidator.validate(
				title: "Create a build plan based on the latest Anker Prime build order",
				goal: "Verify codebase repository commit status",
				isolated: xcodeIsolated,
				stage: "selftest"
			)
			
			if !devVocabValidation.accepted && devVocabValidation.reason == "dev_vocabulary_on_product_page" && xcodeValidation.accepted {
				print("[WorkflowInferenceSelfTest] pass case=product_page_rejects_dev_vocabulary")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=product_page_rejects_dev_vocabulary shopping_accepted=\(devVocabValidation.accepted) reason=\(devVocabValidation.reason) dev_accepted=\(xcodeValidation.accepted) reason=\(xcodeValidation.reason)")
				failures.append("product_page_rejects_dev_vocabulary")
			}
		}

		// MARK: - Phase 20G.1 regression — context shift blocks deterministic shopping fallback.
		do {
			let shiftedPacket = CompressedTemporalPacket(
				currentApp: "Firefox",
				recentApps: ["Firefox"],
				recentTitles: ["Course Page", "Week 1", "Assignment"],
				topicTerms: ["course", "week", "assignment"],
				activityPattern: "steady",
				idlePattern: "active",
				typingPattern: "light",
				pointerPattern: "steady",
				ocrHints: [],
				selectionHints: [],
				clipboardMetadata: "none",
				recentUserAccepts: [],
				recentUserIgnores: [],
				spanSeconds: 300,
				eventCount: 20,
				contextShiftDetected: true
			)
			struct NilBackend: WorkflowInferenceBackend {
				func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult? { nil }
			}
			let inferred = await WorkflowInferenceModel.infer(packet: shiftedPacket, backend: NilBackend(), applyProvenanceGuard: false)
			if inferred.workflow == "unknown" {
				print("[WorkflowInferenceSelfTest] pass case=fallback_blocked_after_epoch_shift")
			} else {
				print("[WorkflowInferenceSelfTest] fail case=fallback_blocked_after_epoch_shift expected=unknown got=\(inferred.workflow)")
				failures.append("fallback_blocked_after_epoch_shift")
			}
		}

        let ok = failures.isEmpty
        print("[WorkflowInferenceSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

// MARK: - Signal-driven stub backend

/// Test-only inference backend. Picks a workflow label using ONLY temporal
/// packet signals (term frequencies, transition counts, activity patterns).
///
/// IMPORTANT — this is not production code, and it does NOT match on app names.
/// It is a thin proxy that proves the packet carries enough temporal signal
/// for any downstream classifier (model-based or otherwise) to do its job.
private struct SignalDrivenStubBackend: WorkflowInferenceBackend {

    func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult? {
        // 1. Idle: very low activity AND long idle AND no recent topic churn.
        if packet.activityPattern == "idle" && packet.idlePattern == "long_idle"
           && packet.recentTitles.count <= 1 {
            return result("idle", 0.78, "long_idle_no_activity")
        }

        // 2. Debugging: error/build/test terms AND typing activity.
        let errorTerms: Set<String> = ["error", "build", "failed", "test", "exception", "stack", "trace", "crash"]
        let errorHits = packet.topicTerms.lazy.map { $0.lowercased() }.filter { errorTerms.contains($0) }.count
        if errorHits >= 2 && (packet.typingPattern == "light" || packet.typingPattern == "heavy") {
            return result("debugging", 0.84, "repeated_error_terms_typing")
        }

        // 3. Studying: sustained academic-flavored topic terms + multiple apps + at least one PDF/notes-like title.
        let studyTerms: Set<String> = [
            "calculus", "derivative", "integral", "limit", "theorem",
            "chapter", "lecture", "study", "exam", "assignment", "homework",
            "physics", "biology", "history", "essay",
        ]
        let studyHits = packet.topicTerms.lazy.map { $0.lowercased() }.filter { studyTerms.contains($0) }.count
        let multiAppNonGame = packet.recentApps.count >= 2 && packet.activityPattern != "idle"
        if studyHits >= 2 && multiAppNonGame {
            return result("studying", 0.82, "academic_terms_multi_app")
        }

        // 4. Gaming: long stable session, very few title changes, ~no typing.
        //    Detection is signal-only: low transitions + low typing + non-idle activity.
        if packet.recentTitles.count <= 2
           && packet.typingPattern == "none"
           && packet.activityPattern != "idle"
           && packet.spanSeconds >= 300 {
            return result("gaming", 0.86, "stable_single_focus_low_typing")
        }

        // 4.5. Shopping (signal-based) — shopping-platform tokens dominate the
        // recency-weighted topic terms AND the user has been moving between
        // titles. This is what B.1.6 makes possible: the platform token only
        // appears in the topic terms when fresh activity has out-weighted
        // older stale terms.
        let shoppingTokens: Set<String> = ["amazon", "ebay", "walmart", "etsy", "shopify"]
        let shoppingHits = packet.topicTerms.lazy
            .map { $0.lowercased() }
            .filter { shoppingTokens.contains($0) }
            .count
        if shoppingHits >= 1 && packet.recentTitles.count >= 3 {
            return result("shopping", 0.82, "shopping_platform_terms_dominate")
        }

        // 5. Researching: many distinct titles + repeated topic terms + light/heavy pointer/typing.
        if packet.recentTitles.count >= 4 && packet.topicTerms.count >= 2 {
            // Distinguish from comparing: comparing requires product-like terms.
            let productTerms: Set<String> = [
                "price", "review", "stars", "spec", "specs", "buy",
                "model", "warranty", "shipping", "stock",
            ]
            let productHits = packet.topicTerms.lazy.map { $0.lowercased() }.filter { productTerms.contains($0) }.count
            if productHits >= 2 {
                return result("comparing", 0.80, "many_pages_product_terms")
            }
            return result("researching", 0.78, "many_pages_shared_topics")
        }

        // 6. Writing: heavy typing + few app changes + low pointer activity.
        if packet.typingPattern == "heavy" && packet.recentApps.count <= 2 && packet.pointerPattern != "active" {
            return result("writing", 0.72, "heavy_typing_few_apps")
        }

        // 7. Default: unknown.
        return result("unknown", 0.3, "insufficient_temporal_signal")
    }

    private func result(_ label: String, _ confidence: Double, _ why: String) -> AmbientWorkflowInferenceResult {
        AmbientWorkflowInferenceResult(
            workflow: label,
            confidence: confidence,
            why: why,
            evidence: [why],
            suggestedIntentHints: [],
            uncertainty: ""
        )
    }
}

// MARK: - Fixed backend (guard tests)

private struct FixedBackend: WorkflowInferenceBackend {
	let result: AmbientWorkflowInferenceResult
	func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult? { result }
}

// MARK: - Fixtures

/// Synthetic temporal sequences for each test case. Times are anchored to "now
/// = last event" so window calculations are deterministic.
private enum Fixtures {

    // 18 minutes of mixed academic activity. Apps repeat. Calculus terms recur.
    // Interleaved typing/pointer events keep activityPattern non-idle, which is
    // the threshold the inference layer uses to distinguish studying from
    // passive researching.
    static func studyingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-1080)
        let pattern: [(String, String, [String])] = [
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "derivative"]),
            ("Notes",      "Calc 12 notes.md",             ["derivative", "limit"]),
            ("Calculator", "Calculator",                    []),
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "integral"]),
            ("Notes",      "Calc 12 notes.md",             ["integral", "limit"]),
            ("Calculator", "Calculator",                    []),
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "limit"]),
            ("Notes",      "Calc 12 notes.md",             ["chapter", "study"]),
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "derivative"]),
            ("Notes",      "Calc 12 notes.md",             ["study", "chapter"]),
        ]
        var events: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 100),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            )
        }
        // Interleave typing + pointer activity so the medium window registers
        // a non-idle activity pattern (studying is active work, not passive).
        for i in 0..<8 {
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 120 + 50),
                type: .typingStateChanged,
                appName: "Notes",
                bundleIdentifier: nil,
                windowTitle: "Calc 12 notes.md",
                activityIntensity: 0.5
            ))
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 120 + 80),
                type: .pointerStateChanged,
                appName: "Preview",
                bundleIdentifier: nil,
                windowTitle: "Calculus II - Lecture 12.pdf",
                activityIntensity: 0.4
            ))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    // 12 minutes of a single dominant app, no title changes, ~no typing.
    static func gamingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-720)
        var out: [ContextEvent] = []
        for i in 0..<12 {
            out.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                type: .pointerStateChanged,
                appName: "Minecraft",
                bundleIdentifier: "com.mojang.minecraftlauncher",
                windowTitle: "Minecraft",
                textHints: [],
                sourceConfidence: 0.95,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.6
            ))
        }
        return out
    }

    // Repeated build / error / test terms with typing across IDE-like windows.
    static func debuggingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        let pattern: [(String, String, [String])] = [
            ("Editor",   "main.swift",       ["build", "error"]),
            ("Terminal", "zsh",              ["test", "failed"]),
            ("Editor",   "main.swift",       ["error", "stack"]),
            ("Terminal", "zsh",              ["build", "failed"]),
            ("Editor",   "AgenticRuntime.swift", ["test", "error"]),
            ("Terminal", "zsh",              ["build", "trace"]),
            ("Editor",   "main.swift",       ["error", "exception"]),
            ("Terminal", "zsh",              ["test", "failed"]),
        ]
        var out: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 100),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.5
            )
        }
        out.append(ContextEvent(
            timestamp: base.addingTimeInterval(900),
            type: .typingStateChanged,
            appName: "Editor",
            bundleIdentifier: nil,
            windowTitle: "main.swift",
            activityIntensity: 0.5
        ))
        return out
    }

    // Many distinct article-style titles with overlapping topic terms.
    static func researchSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        let pattern: [(String, String, [String])] = [
            ("Firefox", "Quantum Computing: An Overview",                 ["quantum", "computing"]),
            ("Firefox", "Shor's algorithm explained",                     ["quantum", "algorithm"]),
            ("Firefox", "Superposition and entanglement basics",          ["quantum", "qubit"]),
            ("Firefox", "Quantum supremacy milestones",                   ["quantum", "milestone"]),
            ("Firefox", "Qubit error correction techniques",              ["quantum", "qubit"]),
            ("Firefox", "Comparing quantum hardware vendors",             ["quantum", "vendor"]),
            ("Firefox", "Quantum annealing vs gate-based",                ["quantum", "annealing"]),
        ]
        var out: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 120),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            )
        }
        out.append(ContextEvent(
            timestamp: base.addingTimeInterval(900),
            type: .pointerStateChanged,
            appName: "Firefox",
            bundleIdentifier: nil,
            windowTitle: "Quantum annealing vs gate-based",
            activityIntensity: 0.3
        ))
        return out
    }

    // Multiple product-style titles with price/spec terms recurring.
    static func comparingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        let pattern: [(String, String, [String])] = [
            ("Firefox", "Anker USB-C Hub product page", ["price", "spec"]),
            ("Firefox", "Spigen USB-C Hub product page", ["price", "review"]),
            ("Firefox", "Anker USB-C Hub - reviews",     ["review", "stars"]),
            ("Firefox", "Belkin USB-C Hub product page", ["price", "spec"]),
            ("Firefox", "Spigen USB-C Hub - reviews",    ["review", "stars"]),
            ("Firefox", "Anker USB-C Hub - specifications", ["spec", "model"]),
        ]
        var out: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 130),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            )
        }
        out.append(ContextEvent(
            timestamp: base.addingTimeInterval(900),
            type: .pointerStateChanged,
            appName: "Firefox",
            bundleIdentifier: nil,
            windowTitle: "Anker USB-C Hub - specifications",
            activityIntensity: 0.3
        ))
        return out
    }

    // B.1.6 regression: 7 minutes of Gmail followed by 7 minutes of Amazon.
    // Without recency weighting + fresh-shift correction this returns
    // "writing"/"emailing" because the stale Gmail terms have higher raw count
    // than the fresh Amazon terms. With B.1.6 the medium-window weighted score
    // ranks `amazon`/`anker`/`charger` above `inbox`/`gmail`/`duncan` and the
    // stabilizer's fresh-shift fast path commits to `shopping` immediately.
    static func shoppingAfterGmailSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-840)
        var events: [ContextEvent] = []

        // Gmail phase — 7 title changes over the first 7 minutes.
        let gmailTitles = [
            "Inbox (24) — duncan@gmail.com — Gmail",
            "Re: lunch — duncan@gmail.com — Gmail",
            "Gmail — duncan@gmail.com — Promotions",
            "Drafts — duncan@gmail.com — Gmail",
            "Inbox (25) — duncan@gmail.com — Gmail",
            "Sent — duncan@gmail.com — Gmail",
            "Inbox (24) — duncan@gmail.com — Gmail",
        ]
        for i in 0..<7 {
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                type: .windowTitleChanged,
                appName: "Firefox",
                bundleIdentifier: "org.mozilla.firefox",
                windowTitle: gmailTitles[i],
                textHints: ["inbox", "gmail", "duncan"],
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            ))
        }
        // Amazon phase — 7 title changes over the next 7 minutes (most recent).
        let amazonTitles = [
            "Amazon.com — Anker USB-C Hub 7-in-1",
            "Amazon.com — Anker Prime 100W charger",
            "Anker USB-C Hub product — Amazon",
            "Amazon.com — Anker Power Bank 10000",
            "Anker Charger Reviews — Amazon",
            "Amazon.com — Anker GaN charger",
            "Amazon — Anker accessories Electronics",
        ]
        for i in 0..<7 {
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(420 + Double(i) * 60),
                type: .windowTitleChanged,
                appName: "Firefox",
                bundleIdentifier: "org.mozilla.firefox",
                windowTitle: amazonTitles[i],
                textHints: ["amazon", "anker", "charger"],
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            ))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    // Long idle interval bracketed by a single idle / resumed pair.
    // The full sequence fits within the medium (15 min) window so that the
    // accumulated idle time registers in the buffer's `idleSeconds`.
    static func idleSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        return [
            ContextEvent(
                timestamp: base,
                type: .windowTitleChanged,
                appName: "Finder",
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Desktop",
                activityIntensity: 0.0
            ),
            ContextEvent(
                timestamp: base.addingTimeInterval(50),
                type: .userIdle,
                appName: "Finder",
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Desktop",
                activityIntensity: 0.0
            ),
            ContextEvent(
                timestamp: base.addingTimeInterval(890),
                type: .userResumed,
                appName: "Finder",
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Desktop",
                activityIntensity: 0.0
            ),
        ]
    }

    // Active browsing title churn with product/search-like hints but no typing/pointer events.
    static func activeTitleChurnSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-220)
        let titles: [String] = [
            "Search results - USB-C charger 65W",
            "Results - USB-C charger 65W review",
            "Product page - 65W USB-C charger specs",
            "Product page - 65W USB-C charger price",
        ]
        let hints: [[String]] = [
            ["charger", "usb-c", "search"],
            ["charger", "review", "price"],
            ["charger", "specs", "watt"],
            ["charger", "price", "shipping"],
        ]

        return titles.enumerated().map { i, title in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 35),
                type: .windowTitleChanged,
                appName: "Browser",
                bundleIdentifier: nil,
                windowTitle: title,
                textHints: hints[i],
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.05
            )
        }
    }

	// B.1.8: active shopping/comparing title churn with shopping provenance terms.
	static func activeShoppingTitleChurnSequence() -> [ContextEvent] {
		let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-220)
		let titles: [String] = [
			"Search results - USB-C charger docking station",
			"Anker Prime docking station - specs",
			"Product page - charger docking station price",
			"Results - docking station reviews",
		]
		let hints: [[String]] = [
			["amazon", "anker", "charger", "docking", "station", "search"],
			["anker", "prime", "docking", "station", "specs"],
			["amazon", "price", "shipping", "docking", "station"],
			["review", "stars", "amazon", "anker"],
		]

		return titles.enumerated().map { i, title in
			ContextEvent(
				timestamp: base.addingTimeInterval(Double(i) * 35),
				type: .windowTitleChanged,
				appName: "Browser",
				bundleIdentifier: nil,
				windowTitle: title,
				textHints: hints[i],
				sourceConfidence: 0.9,
				privacyLevel: .publicMetadata,
				activityIntensity: 0.05
			)
		}
	}
}

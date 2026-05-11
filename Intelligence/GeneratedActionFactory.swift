import Foundation

/// Deterministic mapping from synthesized intents to generated actions (no execution, no persistence).
enum GeneratedActionFactory {
	private static let maxTitleLength = 56
	private static let maxDescriptionLength = 200
	static let minimumIntentConfidence: Double = 0.40
	private static let defaultTTL: TimeInterval = 180

	/// Rejects empty sets, oversized primitive lists, and incompatible primitive pairs.
	static func validatePrimitives(_ primitives: [GeneratedActionPrimitive]) -> Bool {
		guard !primitives.isEmpty, primitives.count <= 2 else { return false }
		let set = Set(primitives)
		if set.contains(.draft), set.contains(.rewrite) { return false }
		return true
	}

	enum MaterializeOutcome: Equatable {
		case produced(GeneratedAction)
		case skippedStale
		case skippedLowConfidence
		case skippedUnknown
		case rejectedUnsafePrimitive
	}

	static func materialize(
		from intent: SynthesizedIntent,
		referenceTime: Date = Date(),
		ttl: TimeInterval = defaultTTL,
		source: GeneratedActionSource = .synthesizedIntent,
		primitiveOverride: [GeneratedActionPrimitive]? = nil
	) -> MaterializeOutcome {
		if intent.isStale { return .skippedStale }
		if intent.confidence < minimumIntentConfidence { return .skippedLowConfidence }
		if intent.type == .unknown { return .skippedUnknown }

		let primitives = primitiveOverride ?? primitives(for: intent.type)
		if primitives.isEmpty { return .skippedUnknown }
		guard validatePrimitives(primitives) else { return .rejectedUnsafePrimitive }

		let title = clampedTitle(intent.title)
		let description = clampedDescription(intent.description)
		guard !title.isEmpty, !description.isEmpty else { return .rejectedUnsafePrimitive }

		let wfRel = workflowRelevance(intent.workflow, intentConfidence: intent.confidence)
		let codes = intent.sourceReasonCodes + ["mapped_intent:\(intent.type.rawValue)"]
		let explain = "intent_type=\(intent.type.rawValue)|primitives=\(primitives.map(\.rawValue).sorted().joined(separator: ","))"

		let action = GeneratedAction(
			id: UUID(),
			title: title,
			description: description,
			intentType: intent.type,
			confidence: isGAMClamp01(intent.confidence),
			workflow: intent.workflow,
			requiredContext: GeneratedActionRequiredContext.fromIntentContexts(intent.requiredContext),
			primitives: primitives,
			interruptionCost: isGAMClamp01(intent.interruptionCost),
			workflowRelevance: isGAMClamp01(wfRel),
			sourceIntentId: intent.id,
			sourceReasonCodes: Array(Set(codes)).sorted(),
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(ttl),
			isStale: intent.isStale,
			safetyProfile: .profile(for: Set(primitives)),
			explainabilitySummary: explain,
			source: source
		)
		return .produced(action)
	}

	static func makeActions(
		from intents: [SynthesizedIntent],
		referenceTime: Date = Date(),
		maxActions: Int = 3,
		ttl: TimeInterval = defaultTTL,
		source: GeneratedActionSource = .synthesizedIntent
	) -> (actions: [GeneratedAction], rejectedUnsafePrimitive: Bool) {
		var out: [GeneratedAction] = []
		var unsafe = false
		out.reserveCapacity(min(maxActions, intents.count))
		for intent in intents {
			guard out.count < maxActions else { break }
			switch materialize(from: intent, referenceTime: referenceTime, ttl: ttl, source: source) {
			case .produced(let a):
				out.append(a)
			case .rejectedUnsafePrimitive:
				unsafe = true
			case .skippedStale, .skippedLowConfidence, .skippedUnknown:
				break
			}
		}
		return (out, unsafe)
	}

	private static func primitives(for type: SynthesizedIntentType) -> [GeneratedActionPrimitive] {
		switch type {
		case .explainLikelyError:
			return [.explain, .classify]
		case .summarizeCurrentArticle:
			return [.summarize]
		case .extractActionItems:
			return [.extract, .checklist]
		case .reviewSelectedText:
			return [.review, .explain]
		case .summarizeCodeChange:
			return [.summarize, .structure]
		case .identifyPossibleBugSource:
			return [.explain, .classify]
		case .explainApiResponse:
			return [.explain]
		case .turnNotesIntoChecklist:
			return [.structure, .checklist]
		case .compareSelectedSnippets:
			return [.compare, .classify]
		case .draftReply:
			return [.draft, .explain]
		case .explainScreenContext:
			return [.explain, .classify]
		case .unknown:
			return []
		}
	}

	private static func workflowRelevance(_ workflow: InferredWorkflow, intentConfidence: Double) -> Double {
		let w: Double
		switch workflow {
		case .debugging, .editing, .reviewing: w = 0.92
		case .writing, .research: w = 0.88
		case .browsing: w = 0.78
		case .unknown: w = 0.55
		}
		return intentConfidence * w
	}

	private static func clampedTitle(_ s: String) -> String {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count <= maxTitleLength else {
			return String(t.prefix(maxTitleLength)).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return t
	}

	private static func clampedDescription(_ s: String) -> String {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count <= maxDescriptionLength else {
			return String(t.prefix(maxDescriptionLength)).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return t
	}
}

/// Stores the latest bounded generated actions and emits metadata-only logs.
final class GeneratedActionEngine {
	static let shared = GeneratedActionEngine()

	private let lock = NSLock()
	private var latest: [GeneratedAction] = []
	private var lastLogSignature: String?
	private var lastLogAt: Date?

	private init() {}

	func reset() {
		lock.lock()
		latest.removeAll()
		lastLogSignature = nil
		lastLogAt = nil
		lock.unlock()
	}

	func latestActions() -> [GeneratedAction] {
		lock.lock()
		let c = latest
		lock.unlock()
		return c
	}

	/// Builds from synthesized intents (order preserved, max 3).
	func record(from intents: [SynthesizedIntent], referenceTime: Date = Date()) {
		guard !intents.isEmpty else {
			lock.lock()
			latest = []
			lock.unlock()
			return
		}

		let (built, rejectedUnsafe) = GeneratedActionFactory.makeActions(from: intents, referenceTime: referenceTime, maxActions: 3)
		lock.lock()
		latest = built
		lock.unlock()
		logOutcome(actions: built, intents: intents, rejectedUnsafe: rejectedUnsafe)
	}

	private func logOutcome(actions: [GeneratedAction], intents: [SynthesizedIntent], rejectedUnsafe: Bool) {
		if rejectedUnsafe {
			print("[GeneratedAction] rejected reason=unsafe_profile")
		}

		if actions.isEmpty {
			let allStale = intents.allSatisfy(\.isStale)
			if allStale {
				print("[GeneratedAction] skipped reason=stale_intent")
				return
			}
			let allLow = intents.allSatisfy { $0.confidence < GeneratedActionFactory.minimumIntentConfidence }
			if allLow {
				print("[GeneratedAction] skipped reason=low_confidence")
				return
			}
			return
		}

		let top = actions.max(by: { $0.confidence < $1.confidence })
		let topType = top?.intentType.rawValue ?? "none"
		let conf = String(format: "%.2f", top?.confidence ?? 0)
		let sig = "\(actions.count)|\(topType)|\(conf)"
		let now = Date()
		lock.lock()
		let shouldSkip: Bool
		if lastLogSignature == sig, let t = lastLogAt, now.timeIntervalSince(t) < 2.2 {
			shouldSkip = true
		} else {
			shouldSkip = false
			lastLogSignature = sig
			lastLogAt = now
		}
		lock.unlock()
		if shouldSkip { return }

		print("[GeneratedAction] created count=\(actions.count) top=\(topType) confidence=\(conf)")
		print("[GeneratedAction] kept reason=non_executable count=\(actions.count)")
	}
}

// MARK: - DEBUG self-test

extension GeneratedActionEngine {
	static func runSelfTest() -> Bool {
		print("[GeneratedAction] selftest starting")
		let engine = GeneratedActionEngine.shared
		engine.reset()
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_030_000_000)

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func intent(
			type: SynthesizedIntentType,
			title: String,
			description: String,
			confidence: Double,
			workflow: InferredWorkflow,
			stale: Bool,
			id: UUID = UUID()
		) -> SynthesizedIntent {
			SynthesizedIntent(
				id: id,
				type: type,
				title: title,
				description: description,
				confidence: confidence,
				workflow: workflow,
				requiredContext: [.textSnippet],
				supportingSignals: ["selftest"],
				interruptionCost: 0.4,
				freshness: 0.75,
				createdAt: t0,
				isStale: stale,
				sourceReasonCodes: ["selftest"]
			)
		}

		// explain_likely_error → explain
		let ex = intent(type: .explainLikelyError, title: "Explain likely error", description: "Desc", confidence: 0.72, workflow: .debugging, stale: false)
		let exA = GeneratedActionFactory.materialize(from: ex, referenceTime: t0, source: .selfTest)
		var explainAction: GeneratedAction?
		if case .produced(let exAct) = exA {
			explainAction = exAct
			assertCase("explain_likely_error_has_explain", exAct.primitives.contains(.explain))
		} else {
			assertCase("explain_materialized", false)
		}

		// summarize article
		let sum = intent(type: .summarizeCurrentArticle, title: "Summarize article", description: "D", confidence: 0.66, workflow: .research, stale: false)
		if case .produced(let sumAct) = GeneratedActionFactory.materialize(from: sum, referenceTime: t0, source: .selfTest) {
			assertCase("summarize_primitive", sumAct.primitives == [.summarize])
		} else {
			assertCase("summarize_materialized", false)
		}

		// extract → extract + checklist
		let ext = intent(type: .extractActionItems, title: "Extract", description: "D", confidence: 0.65, workflow: .research, stale: false)
		if case .produced(let extAct) = GeneratedActionFactory.materialize(from: ext, referenceTime: t0, source: .selfTest) {
			assertCase("extract_checklist", extAct.primitives.contains(.extract) && extAct.primitives.contains(.checklist))
		} else {
			assertCase("extract_materialized", false)
		}

		// review → review + explain
		let rev = intent(type: .reviewSelectedText, title: "Review", description: "D", confidence: 0.68, workflow: .writing, stale: false)
		if case .produced(let revAct) = GeneratedActionFactory.materialize(from: rev, referenceTime: t0, source: .selfTest) {
			assertCase("review_explain", revAct.primitives.contains(.review) && revAct.primitives.contains(.explain))
		} else {
			assertCase("review_materialized", false)
		}

		// code change → summarize + structure
		let code = intent(type: .summarizeCodeChange, title: "Code change", description: "D", confidence: 0.67, workflow: .reviewing, stale: false)
		if case .produced(let codeAct) = GeneratedActionFactory.materialize(from: code, referenceTime: t0, source: .selfTest) {
			assertCase("code_summarize_structure", codeAct.primitives.contains(.summarize) && codeAct.primitives.contains(.structure))
		} else {
			assertCase("code_materialized", false)
		}

		// stale → no action
		let staleI = intent(type: .explainLikelyError, title: "T", description: "D", confidence: 0.9, workflow: .debugging, stale: true)
		assertCase("stale_skipped", GeneratedActionFactory.materialize(from: staleI, referenceTime: t0) == .skippedStale)

		// low confidence
		let low = intent(type: .explainLikelyError, title: "T", description: "D", confidence: 0.12, workflow: .debugging, stale: false)
		assertCase("low_conf_skipped", GeneratedActionFactory.materialize(from: low, referenceTime: t0) == .skippedLowConfidence)

		// unsafe primitive override (same file — tests factory guardrails only).
		let unsafeBase = intent(type: .explainLikelyError, title: "T", description: "D", confidence: 0.8, workflow: .debugging, stale: false)
		let unsafeOut = GeneratedActionFactory.materialize(
			from: unsafeBase,
			referenceTime: t0,
			source: .selfTest,
			primitiveOverride: [.draft, .rewrite]
		)
		assertCase("unsafe_rejected", unsafeOut == .rejectedUnsafePrimitive)
		assertCase("validate_draft_rewrite", !GeneratedActionFactory.validatePrimitives([.draft, .rewrite]))

		// bounded: 5 intents, max 3 actions
		let many = (0..<5).map { i in
			intent(type: .explainApiResponse, title: "E\(i)", description: "D\(i)", confidence: 0.7, workflow: .research, stale: false, id: UUID())
		}
		let (manyActs, _) = GeneratedActionFactory.makeActions(from: many, referenceTime: t0, maxActions: 3)
		assertCase("bounded_three", manyActs.count <= 3)

		// safety defaults
		if let ea = explainAction {
			assertCase("safety_reads_only", ea.safetyProfile.readsContextOnly && !ea.safetyProfile.writesExternalState)
			assertCase("safety_no_auto", ea.safetyProfile.canRunAutomatically == false)
			assertCase("title_short", ea.title.count <= 56)
		} else {
			assertCase("safety_defaults_need_explain_action", false)
		}
		if case .produced(let draftAct) = GeneratedActionFactory.materialize(
			from: intent(type: .draftReply, title: "Draft", description: "D", confidence: 0.75, workflow: .writing, stale: false),
			referenceTime: t0,
			source: .selfTest
		) {
			assertCase("draft_requires_approval", draftAct.safetyProfile.requiresUserApproval)
		} else {
			assertCase("draft_materialized", false)
		}

		// stale batch logging + reset clears
		engine.record(from: [staleI], referenceTime: t0)
		assertCase("stale_batch_empty", engine.latestActions().isEmpty)
		engine.reset()
		assertCase("reset_latest", engine.latestActions().isEmpty)

		let ok = failures.isEmpty
		print("[GeneratedAction] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}

private func isGAMClamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}

import Foundation

/// T18.3.3B LLM timeout diagnostic tests (not wired to app launch).
enum DynamicGeneratedProposalLLMPathSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Test",
			generatedAt: Date()
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap)

		let timeoutEngine = DynamicGeneratedProposalEngine(
			modelManager: LLMPathTestModelGate(),
			client: SlowLLMPathClient(),
			timeoutSeconds: 0.08
		)
		let timeoutResult = await timeoutEngine.generateProposals(
			snapshot: snap,
			existingStaticActions: [],
			reusableActions: [],
			situational: situational
		)
		check("timeout_status", timeoutResult.status == .timeout)
		check("timeout_cause", timeoutResult.llmDiagnosticCause == .appTimeout)

		let failEngine = DynamicGeneratedProposalEngine(
			modelManager: LLMPathTestModelGate(),
			client: FailingLLMPathClient(),
			timeoutSeconds: 5
		)
		let failResult = await failEngine.generateProposals(
			snapshot: snap,
			existingStaticActions: [],
			reusableActions: [],
			situational: situational
		)
		check("client_fail_cause", failResult.llmDiagnosticCause == .clientFailed)

		let ok = failures.isEmpty
		print("[DynamicGeneratedProposalLLM] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
		return ok
	}
}

private struct LLMPathTestModelGate: DynamicGeneratedProposalAvailabilityChecking {
	func isGenerationAvailable() async -> Bool { true }
}

private struct SlowLLMPathClient: DynamicGeneratedProposalLLMGenerating {
	func generate(prompt: String, model: String) async throws -> String {
		_ = prompt
		try await Task.sleep(nanoseconds: 500_000_000)
		return "{}"
	}
}

private struct FailingLLMPathClient: DynamicGeneratedProposalLLMGenerating {
	func generate(prompt: String, model: String) async throws -> String {
		_ = prompt
		throw LocalAIClientError.emptyResponse
	}
}

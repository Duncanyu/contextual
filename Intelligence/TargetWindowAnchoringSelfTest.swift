import Foundation

enum TargetWindowAnchoringSelfTest {

	static func run() async -> Bool {
		let assistantBundle = Bundle.main.bundleIdentifier ?? "com.contextual.Contextual"

		// Ensure hook catalog reset remains active (empty installed catalog).
		let registry = HookCapabilityRegistry.shared
		guard registry.all.isEmpty else {
			print("[TargetWindowAnchoringSelfTest] failed reason=hook_catalog_not_empty count=\(registry.all.count)")
			return false
		}

		// Simulate: proposal generated for Firefox, but user click makes Contextual frontmost at execution time.
		let anchor = TargetWindowAnchor(
			bundleIdentifier: "org.mozilla.firefox",
			appName: "Firefox",
			windowTitle: "Anker Laptop Charger - Amazon.com",
			contextFingerprint: TargetWindowAnchor.fingerprint(
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: "Anker Laptop Charger - Amazon.com",
				workflow: .browsing
			),
			createdAt: Date(),
			sourceCandidateId: "agentic:test"
		)

		let noisyOCR = [
			"Processing Update Product Information...",
			"Generated Execution",
			"Anker Prime 140W Charger",
			"Price $76",
			"Rating 4.6 stars"
		].joined(separator: "\n")

		let snapshot = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Contextual",
			windowTitle: anchor.windowTitle,
			bundleIdentifier: assistantBundle,
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: noisyOCR,
			contextSummary: nil,
			workflowConfidence: 0.7,
			availableContextTypes: [.textSnippet],
			visualContextAvailability: .init(),
			permissionAvailability: [.screenRecording: true],
			generatedAt: Date(),
			freshnessScore: 0.9,
			sourceMetadata: .init(),
			fusedPacketId: nil,
			packetIsStale: false
		)

		// Snapshot repair should prefer the target anchor over the assistant bundle.
		let repaired = snapshot.applyingTargetAnchor(anchor, workflowOverride: .browsing)
		guard repaired.bundleIdentifier == anchor.bundleIdentifier, repaired.activeApp == "Firefox" else {
			print("[TargetWindowAnchoringSelfTest] failed reason=snapshot_not_repaired active_app=\(repaired.activeApp) bundle=\(repaired.bundleIdentifier ?? "nil")")
			return false
		}

		let filtered = AssistantChromeFilter.filterOCR(noisyOCR, targetBundleIdentifier: anchor.bundleIdentifier)
		if filtered.filteredText.lowercased().contains("processing update product information") || filtered.suppressedLineCount == 0 {
			print("[TargetWindowAnchoringSelfTest] failed reason=assistant_chrome_not_filtered")
			return false
		}

		print("[TargetWindowAnchoringSelfTest] ok repaired_bundle=\(repaired.bundleIdentifier ?? "nil") suppressed=\(filtered.suppressedLineCount)")
		return true
	}
}

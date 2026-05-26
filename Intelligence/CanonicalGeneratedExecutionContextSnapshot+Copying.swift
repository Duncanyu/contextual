import Foundation

extension CanonicalGeneratedExecutionContextSnapshot {
	func replacing(
		windowTitle: String? = nil,
		recentOCRExcerpt: String? = nil,
		inferredWorkflow: InferredWorkflow? = nil,
		workflowConfidence: Double? = nil
	) -> CanonicalGeneratedExecutionContextSnapshot {
		CanonicalGeneratedExecutionContextSnapshot(
			activeApp: activeApp,
			windowTitle: windowTitle ?? self.windowTitle,
			bundleIdentifier: bundleIdentifier,
			inferredWorkflow: inferredWorkflow ?? self.inferredWorkflow,
			inferredIntent: inferredIntent,
			selectedText: selectedText,
			clipboardText: clipboardText,
			recentOCRExcerpt: recentOCRExcerpt ?? self.recentOCRExcerpt,
			contextSummary: contextSummary,
			workflowConfidence: workflowConfidence ?? self.workflowConfidence,
			availableContextTypes: availableContextTypes,
			visualContextAvailability: visualContextAvailability,
			permissionAvailability: permissionAvailability,
			generatedAt: generatedAt,
			freshnessScore: freshnessScore,
			sourceMetadata: sourceMetadata,
			fusedPacketId: fusedPacketId,
			packetIsStale: packetIsStale
		)
	}
}


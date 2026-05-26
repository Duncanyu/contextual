import Foundation

extension SituationalContextSnapshot {
	func replacing(
		windowTitle: String,
		inferredWorkflow: InferredWorkflow? = nil,
		workflowConfidence: Double? = nil
	) -> SituationalContextSnapshot {
		SituationalContextSnapshot(
			id: id,
			activeAppName: activeAppName,
			activeBundleId: activeBundleId,
			windowTitle: windowTitle,
			appCategory: appCategory,
			inferredWorkflow: inferredWorkflow ?? self.inferredWorkflow,
			inferredIntent: inferredIntent,
			workflowConfidence: workflowConfidence ?? self.workflowConfidence,
			contextFreshness: contextFreshness,
			continuityConfidence: continuityConfidence,
			primaryAvailableSource: primaryAvailableSource,
			availableSources: availableSources,
			staleSources: staleSources,
			suppressedSources: suppressedSources,
			selectedTextSignal: selectedTextSignal,
			clipboardSignal: clipboardSignal,
			visualSignal: visualSignal,
			ocrSignal: ocrSignal,
			activitySignal: activitySignal,
			interactionSignal: interactionSignal,
			missingContextReasons: missingContextReasons,
			perceptionRecommendation: perceptionRecommendation,
			perceptionReasons: perceptionReasons,
			situationalSummary: situationalSummary,
			assistantGuidance: assistantGuidance,
			createdAt: createdAt,
			expiresAt: expiresAt,
			metadata: metadata
		)
	}
}


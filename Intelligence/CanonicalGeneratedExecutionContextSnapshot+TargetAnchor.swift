import Foundation

extension CanonicalGeneratedExecutionContextSnapshot {

	func applyingTargetAnchor(
		_ anchor: TargetWindowAnchor,
		workflowOverride: WorkflowType?
	) -> CanonicalGeneratedExecutionContextSnapshot {
		let inferredWorkflow: InferredWorkflow = {
			guard let workflowOverride else { return self.inferredWorkflow }
			switch workflowOverride {
			case .debugging: return .debugging
			case .writing: return .writing
			case .research: return .research
			case .browsing: return .browsing
			case .editing: return .editing
			case .reviewing: return .reviewing
			default: return self.inferredWorkflow
			}
		}()

		return CanonicalGeneratedExecutionContextSnapshot(
			activeApp: anchor.appName,
			windowTitle: anchor.windowTitle,
			bundleIdentifier: anchor.bundleIdentifier,
			inferredWorkflow: inferredWorkflow,
			inferredIntent: inferredIntent,
			selectedText: selectedText,
			clipboardText: clipboardText,
			recentOCRExcerpt: recentOCRExcerpt,
			contextSummary: contextSummary,
			workflowConfidence: workflowConfidence,
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


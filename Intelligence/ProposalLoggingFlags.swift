import Foundation

/// Environment-gated logging flags (debug builds only).
enum ProposalLoggingFlags {
	static var traceInitEnabled: Bool {
		#if DEBUG
		return ProcessInfo.processInfo.environment["CONTEXTUAL_TRACE_INIT"] == "1"
		#else
		return false
		#endif
	}

	static var verboseProposalLogsEnabled: Bool {
		#if DEBUG
		return ProcessInfo.processInfo.environment["CONTEXTUAL_VERBOSE_PROPOSAL_LOGS"] == "1"
		#else
		return false
		#endif
	}

	/// Debug-only fallback to the seeded template library when task inference fails.
	/// Disabled by default; enable only for explicit debugging.
	static var templateFallbackEnabled: Bool {
		#if DEBUG
		ProcessInfo.processInfo.environment["CONTEXTUAL_ENABLE_TEMPLATE_FALLBACK"] == "1"
		#else
		return false
		#endif
	}
}

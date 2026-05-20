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
}


import Foundation

/// Debug-only unified ranking line with TTL cache (T17.10). Not for live proposal hot paths.
enum UnifiedActionRankingDebug {
	private static let lock = NSLock()
	private static var cacheFingerprint: String?
	private static var cacheLine: String = ""
	private static var cacheAt: Date?
	private static let minRefreshInterval: TimeInterval = 2.5

	/// Metadata-only summary line; recomputes at most once per fingerprint per interval.
	static func unifiedRankingLine(inputs: DynamicIntentDebugPipelineInputs) -> String {
		let fingerprint = fingerprint(for: inputs)
		let now = Date()

		lock.lock()
		if fingerprint == cacheFingerprint,
		   let cacheAt,
		   now.timeIntervalSince(cacheAt) < minRefreshInterval
		{
			let line = cacheLine
			lock.unlock()
			return line
		}
		lock.unlock()

		let ranking = UnifiedActionRankingAdapter.buildDebugRanking(inputs: inputs, emitRankingLog: false)
		let line: String
		if let top = ranking.rankedActions.first {
			let src = top.action.sourceType.rawValue
			let score = String(format: "%.2f", top.components.finalScore)
			line = "Unified rank: top=\(src) score=\(score) static=\(ranking.staticActionCount) gen=\(ranking.generatedActionCount) reuse=\(ranking.reusableActionCount) \(ranking.rankingReasonSummary)"
		} else {
			line = ""
		}

		lock.lock()
		cacheFingerprint = fingerprint
		cacheLine = line
		cacheAt = now
		lock.unlock()
		return line
	}

	#if DEBUG
	static func resetCacheForTests() {
		lock.lock()
		cacheFingerprint = nil
		cacheLine = ""
		cacheAt = nil
		lock.unlock()
	}
	#endif

	private static func fingerprint(for inputs: DynamicIntentDebugPipelineInputs) -> String {
		let wf = inputs.workflow.map { "\($0.workflow.rawValue):\(Int($0.confidence * 100)):\($0.isStale)" } ?? "nil"
		let acts = inputs.actions.count
		let plans = inputs.plans.count
		let genTop = inputs.ranking?.rankedGeneratedActionIds.first ?? "nil"
		return "\(wf)|a=\(acts)|p=\(plans)|g=\(genTop)"
	}
}

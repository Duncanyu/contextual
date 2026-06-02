import Foundation

public struct WorkingMemorySnapshot: Sendable, Codable, Equatable {
    public let currentEntity: String
    public let recentEntities: [String]
    public let repeatedConcepts: [String]
    public let inferredActivity: String
    public let comparisonCandidates: [String]
	public let staleEntities: [String]
	public let relatedFocusEntities: [String]
	public let backgroundEntities: [String]
    
    // Phase 20I: Trust Metrics
    public var workingMemoryTrust: Double {
        let e = Double(recentEntities.count) * 0.10
        let c = Double(repeatedConcepts.count) * 0.15
        let r = Double(relatedFocusEntities.count) * 0.10
        return min(0.95, e + c + r)
    }
    
    public init(
        currentEntity: String,
        recentEntities: [String],
        repeatedConcepts: [String],
        inferredActivity: String,
        comparisonCandidates: [String],
		staleEntities: [String] = [],
		relatedFocusEntities: [String] = [],
		backgroundEntities: [String] = []
    ) {
        self.currentEntity = currentEntity
        self.recentEntities = recentEntities
        self.repeatedConcepts = repeatedConcepts
        self.inferredActivity = inferredActivity
        self.comparisonCandidates = comparisonCandidates
		self.staleEntities = staleEntities
		self.relatedFocusEntities = relatedFocusEntities
		self.backgroundEntities = backgroundEntities
    }
}

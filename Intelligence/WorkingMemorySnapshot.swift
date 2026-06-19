import Foundation

public enum ContextAuthority: String, Sendable, Codable, Equatable {
    case currentFocus = "current_focus"
    case relatedFocus = "related_focus"
    case background = "background"
    case stale = "stale"
}

public struct ContextSourceTag: Sendable, Codable, Equatable {
    public let text: String
    public let authority: ContextAuthority
}

public struct WorkingMemorySnapshot: Sendable, Codable, Equatable {
    public let currentEntity: String
    public let recentEntities: [String]
    public let repeatedConcepts: [String]
    public let inferredActivity: String
    public let comparisonCandidates: [String]
	public let staleEntities: [String]
	public let relatedFocusEntities: [String]
	public let backgroundEntities: [String]
	public let currentFocusTerms: [String]
	public let relatedTerms: [String]
	public let backgroundTerms: [String]
	
	public let taggedEntities: [ContextSourceTag]
	public let taggedTerms: [ContextSourceTag]
    
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
		backgroundEntities: [String] = [],
		currentFocusTerms: [String] = [],
		relatedTerms: [String] = [],
		backgroundTerms: [String] = [],
		taggedEntities: [ContextSourceTag] = [],
		taggedTerms: [ContextSourceTag] = []
    ) {
        self.currentEntity = currentEntity
        self.recentEntities = recentEntities
        self.repeatedConcepts = repeatedConcepts
        self.inferredActivity = inferredActivity
        self.comparisonCandidates = comparisonCandidates
		self.staleEntities = staleEntities
		self.relatedFocusEntities = relatedFocusEntities
		self.backgroundEntities = backgroundEntities
		self.currentFocusTerms = currentFocusTerms
		self.relatedTerms = relatedTerms
		self.backgroundTerms = backgroundTerms
		self.taggedEntities = taggedEntities
		self.taggedTerms = taggedTerms
    }
}

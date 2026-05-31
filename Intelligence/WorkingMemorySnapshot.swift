import Foundation

public struct WorkingMemorySnapshot: Sendable, Codable, Equatable {
    public let currentEntity: String
    public let recentEntities: [String]
    public let repeatedConcepts: [String]
    public let inferredActivity: String
    public let comparisonCandidates: [String]
    
    public init(
        currentEntity: String,
        recentEntities: [String],
        repeatedConcepts: [String],
        inferredActivity: String,
        comparisonCandidates: [String]
    ) {
        self.currentEntity = currentEntity
        self.recentEntities = recentEntities
        self.repeatedConcepts = repeatedConcepts
        self.inferredActivity = inferredActivity
        self.comparisonCandidates = comparisonCandidates
    }
}

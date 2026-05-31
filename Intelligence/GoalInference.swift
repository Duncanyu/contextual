import Foundation

public struct GoalInference: Sendable, Codable, Equatable {
    public let goal: String
    public let confidence: Double
    public let reasoning: String
    
    public init(goal: String, confidence: Double, reasoning: String) {
        self.goal = goal
        self.confidence = confidence
        self.reasoning = reasoning
    }
}

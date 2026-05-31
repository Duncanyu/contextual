import Foundation

public struct CognitiveArtifact: Sendable, Codable, Equatable {
    public let artifactType: String
    public let sections: [ArtifactSection]
    
    public struct ArtifactSection: Sendable, Codable, Equatable {
        public let heading: String
        public let items: [String]
    }
    
    public init(artifactType: String, sections: [ArtifactSection]) {
        self.artifactType = artifactType
        self.sections = sections
    }
}

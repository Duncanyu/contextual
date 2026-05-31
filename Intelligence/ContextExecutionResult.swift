import Foundation

/// Stage-2 output from the `ContextExecutionEngine`. The structure is fixed
/// across every workflow on purpose — the explicit Observed / Web /
/// Inferred / Unknown split is what prevents the model from inventing facts.
public struct ContextExecutionResult: Sendable, Codable, Equatable {
    /// The Stage-1 intent that produced this result.
    public let intent: InferredIntent

    /// Phase 19: Inferred goal and generated cognitive artifact.
    public let goalInference: GoalInference
    public let cognitiveArtifact: CognitiveArtifact

    /// Phase 20D: The engine's judgment about evidence quality and
    /// comparison validity. Rendered above the artifact (one line) so the
    /// user can see *why* the artifact takes the shape it does.
    public let judgment: ContextJudgment

    /// Items that appear verbatim or paraphrase what is in the context packet
    /// (titles, apps, repeated terms, OCR hints).
    public let observed: [String]

    /// Cautious interpretations derived from observation. These items use
    /// hedging language ("appears", "may", "seems") rather than asserting.
    public let inferred: [String]

    /// Explicit gaps — things the engine does NOT know because they are not
    /// present in the supplied context.
    public let unknown: [String]

    /// A single short question the user could answer to clarify the situation.
    public let nextQuestion: String

    /// Public-web encyclopedia snippets (if enrichment fired). ALWAYS rendered
    /// in its own labelled section so it is never confused with on-screen
    /// observation. Empty when enrichment was skipped or returned nothing.
    public let webContext: [String]

	/// Public page metadata extracted from a public URL (OpenGraph/JSON-LD), if available.
	public let publicPageMetadata: [String]

	/// Explicitly extracted product facts (JSON-LD Product fields only), if available.
	public let extractedProductFacts: [String]

	/// Coarse evidence quality gate used to keep outputs conservative.
	/// "title_only" | "product_metadata"
	public let evidenceQuality: String

    /// `model` when the local model produced this structured payload,
    /// `fallback` when the engine assembled it deterministically from context
    /// signals.
    public let source: String

    public let executedAt: Date

    public init(
        intent: InferredIntent,
        goalInference: GoalInference,
        cognitiveArtifact: CognitiveArtifact,
        judgment: ContextJudgment = .empty,
        observed: [String],
        inferred: [String],
        unknown: [String],
        nextQuestion: String,
        webContext: [String] = [],
		publicPageMetadata: [String] = [],
		extractedProductFacts: [String] = [],
		evidenceQuality: String = "title_only",
        source: String,
        executedAt: Date = Date()
    ) {
        self.intent = intent
        self.goalInference = goalInference
        self.cognitiveArtifact = cognitiveArtifact
        self.judgment = judgment
        self.observed = observed
        self.inferred = inferred
        self.unknown = unknown
        self.nextQuestion = nextQuestion
        self.webContext = webContext
		self.publicPageMetadata = publicPageMetadata
		self.extractedProductFacts = extractedProductFacts
		self.evidenceQuality = evidenceQuality
        self.source = source
        self.executedAt = executedAt
    }

    /// Plain-text rendering for the assistant panel.
    /// Phase 19: Prioritizes the Cognitive Artifact.
    public func render() -> String {
        func bullet(_ items: [String]) -> String {
            guard !items.isEmpty else { return "- (none)" }
            return items.map { "- \($0)" }.joined(separator: "\n")
        }
        var sections: [String] = []
        
        // 1. Intent & Goal
        sections.append("""
        Intent: \(intent.intent)
        Goal: \(goalInference.goal)
        """)
        // Phase 20D — surface the engine's own judgment one line above the
        // artifact, but only when it is *not* a clean direct comparison.
        // For valid direct comparisons we stay quiet — no need to explain.
        if judgment.comparisonValidity != .direct {
            sections.append("""
            Judgment: relationship=\(judgment.relationship.rawValue); comparison_validity=\(judgment.comparisonValidity.rawValue); decision_type=\(judgment.decisionType.rawValue)
            """)
        }
        
        // 2. Cognitive Artifact
        let artifactHeading = cognitiveArtifact.artifactType.replacingOccurrences(of: "_", with: " ").capitalized
        sections.append("### \(artifactHeading)")
        for section in cognitiveArtifact.sections {
            sections.append("""
            \(section.heading):
            \(bullet(section.items))
            """)
        }
        
        // 3. Grounded Evidence (Secondary)
        sections.append("""
        ---
        Observed from screen:
        \(bullet(observed))
        """)
		if !publicPageMetadata.isEmpty {
			sections.append("""
			Public page metadata:
			\(bullet(publicPageMetadata))
			""")
		}
		if !extractedProductFacts.isEmpty {
			sections.append("""
			Extracted product facts:
			\(bullet(extractedProductFacts))
			""")
		}
        if !webContext.isEmpty {
            sections.append("""
            Public web context (sourced externally):
            \(bullet(webContext))
            """)
        }
        
        sections.append("""
        Possibly inferred:
        \(bullet(inferred))
        """)
        sections.append("""
        Not enough information:
        \(bullet(unknown))
        """)
        
        sections.append("""
        Useful next question:
        \(nextQuestion)
        """)
        
        return sections.joined(separator: "\n\n")
    }
}

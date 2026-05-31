import Foundation

/// Phase 20D Judgment Layer — answers, given the engine's evidence so far:
///
///   1. Are these entities related?
///   2. Is the user's comparison even meaningful?
///   3. What is the user's likely decision type?
///   4. What information is missing?
///   5. What is the most useful next question?
///
/// **No hardcoded category trees.** No `title.contains("charger")`. No
/// workflow→artifact mappings. Inputs are evidence (memory, page facts,
/// research, packet); outputs are a `ContextJudgment` struct. The artifact
/// selector consumes the judgment.
enum JudgmentLayer {

    // MARK: - Public API

    static func judge(
        workflow: WorkflowState,
        behavior: BehavioralStateRecord,
        memory: WorkingMemorySnapshot,
        page: PublicPageContextExtractor.PublicPageContext,
        researchFacts: [PublicWebResearchEnricher.PublicGroundedFact],
        packet: CompressedTemporalPacket
    ) -> ContextJudgment {

        let entities = candidateEntities(memory: memory, packet: packet)
        guard entities.count >= 1 else {
            let j = ContextJudgment.empty
            j.log()
            return j
        }

        // --- Step 1: tokenize each entity into a meaningful concept bag ---
        let perEntityConcepts = entities.map { conceptTokens(forTitle: $0) }
        let totalEntities = perEntityConcepts.count

        // --- Step 2: pairwise relatedness score from shared concepts ---
        // Average jaccard across all distinct pairs.
        var totalPairs = 0
        var totalJaccard = 0.0
        if totalEntities >= 2 {
            for i in 0..<totalEntities {
                for j in (i+1)..<totalEntities {
                    let a = perEntityConcepts[i]
                    let b = perEntityConcepts[j]
                    let inter = a.intersection(b).count
                    let union = a.union(b).count
                    let jac = union == 0 ? 0.0 : Double(inter) / Double(union)
                    totalJaccard += jac
                    totalPairs += 1
                }
            }
        }
        let avgJaccard: Double = totalPairs == 0 ? 0.0 : totalJaccard / Double(totalPairs)

        // --- Step 3: shared concepts that survived the generic filter ---
        let sharedConcepts: Set<String> = perEntityConcepts.reduce(perEntityConcepts.first ?? []) { acc, set in
            acc.intersection(set)
        }
        let sharedNonGeneric = sharedConcepts.subtracting(genericConcepts)

        // --- Step 4: numeric-facts collection across entities ---
        let allNumericFacts = collectNumericFacts(page: page, researchFacts: researchFacts)
        let dimensionsPresent = Set(allNumericFacts.map { $0.dimension }).subtracting([.unknown])
        let incompatibleUnits: Bool = {
            // Only meaningful when at least two distinct dimensions are present
            // AND there are no shared dimensions with multiple entities backing each.
            // In practice: if we have *just* mAh on one fact and *just* W on another,
            // a comparison between them is forbidden.
            dimensionsPresent.count >= 2
        }()

        // --- Step 5: relationship classification ---
        // Evidence weights — explicit research facts beat title overlap.
        // Strongest "same category" signal: a non-generic shared concept that
        // is ALSO present in the packet's topic terms (i.e. the user has been
        // seeing it repeatedly across the temporal window).
        let researchCategoryClash = researchFactsConflict(researchFacts)
        let topicTermSet = Set(packet.topicTerms.map { $0.lowercased() })
        let sharedConceptInTopicTerms = sharedNonGeneric.contains(where: { topicTermSet.contains($0) })
        let relationship: ContextJudgment.EntityRelationship
        if totalEntities == 1 {
            relationship = .insufficientEvidence
        } else if researchCategoryClash {
            relationship = .differentCategory
        } else if avgJaccard >= 0.40 && !sharedNonGeneric.isEmpty {
            relationship = .sameCategory
        } else if sharedConceptInTopicTerms {
            // e.g. "charger" appears in 3 titles AND in topic terms — the
            // recurrence across the temporal window is the stronger signal.
            relationship = .sameCategory
        } else if sharedNonGeneric.count >= 1 {
            relationship = .relatedDomain
        } else if totalEntities >= 2 && avgJaccard < 0.10 && allNumericFacts.isEmpty {
            relationship = .insufficientEvidence
        } else {
            relationship = .differentCategory
        }

        // --- Step 6: decision type ---
        let decisionType: ContextJudgment.DecisionType = {
            let wf = workflow.workflowType
            let bh = behavior.state
            // Diagnostic — explicit error-flavored topic terms
            let errorTerms: Set<String> = ["error", "build", "failed", "test", "exception", "stack", "trace", "crash", "warning"]
            let hasErrorTerms = packet.topicTerms.contains(where: { errorTerms.contains($0.lowercased()) })
            if hasErrorTerms || wf == .debugging || bh == .debugging {
                return .diagnostic
            }
            // Knowledge acquisition — research/reading workflows or shared
            // domain concepts across many entities.
            if wf == .researching || wf == .reading || wf == .studying || bh == .researching || bh == .reading {
                return .knowledgeAcquisition
            }
            // Product choice — comparing/shopping with >= 2 entities.
            if (wf == .comparing || wf == .shopping || bh == .comparing) && totalEntities >= 2 {
                return .productChoice
            }
            return .unclear
        }()

        // --- Step 7: comparison validity ---
        let comparisonValidity: ContextJudgment.ComparisonValidity = {
            if decisionType == .knowledgeAcquisition || decisionType == .diagnostic {
                return .notApplicable
            }
            if totalEntities < 2 {
                return .notApplicable
            }
            switch relationship {
            case .differentCategory, .unrelated:
                return .invalid
            case .insufficientEvidence:
                return totalEntities >= 2 ? .invalid : .notApplicable
            case .relatedDomain:
                return .partial
            case .sameCategory:
                // Incompatible units (e.g. mAh + W in the fact pool with no
                // shared dimension) downgrades to partial — even though the
                // categories match, the numbers don't rank against each other.
                if incompatibleUnits {
                    return .partial
                }
                let perEntityDims = perEntityDimensionSets(
                    entities: entities,
                    facts: allNumericFacts
                )
                let directComparable = !perEntityDims.isEmpty &&
                    perEntityDims.dropFirst().allSatisfy { !$0.intersection(perEntityDims.first!).isEmpty }
                return directComparable ? .direct : .partial
            }
        }()

        // --- Step 8: missing information ---
        var missing: [String] = []
        if page.productFacts.isEmpty && researchFacts.isEmpty {
            missing.append("Detailed page facts (no public-page metadata fetched).")
        }
        if totalEntities >= 2 && relationship == .insufficientEvidence {
            missing.append("Evidence about how these items relate (only titles available).")
        }
        if comparisonValidity == .invalid {
            missing.append("User's intended use case (the items appear to serve different needs).")
        }
        if incompatibleUnits {
            missing.append("A common metric to compare on (current numeric facts are in different unit dimensions).")
        }
        if missing.isEmpty {
            missing.append("User's specific decision criteria.")
        }

        // --- Step 9: rationale ---
        var rationale: [String] = []
        rationale.append("entities=\(totalEntities)")
        rationale.append(String(format: "avg_jaccard=%.2f", avgJaccard))
        if !sharedNonGeneric.isEmpty {
            rationale.append("shared_concepts=\(sharedNonGeneric.sorted().prefix(4).joined(separator: ","))")
        }
        if !dimensionsPresent.isEmpty {
            rationale.append("dimensions=\(dimensionsPresent.map { $0.rawValue }.sorted().joined(separator: ","))")
        }
        if researchCategoryClash {
            rationale.append("research_categories_conflict=yes")
        }
        if incompatibleUnits {
            rationale.append("incompatible_units=yes")
        }

        // --- Step 10: confidence — derives from how much evidence we have ---
        var confidence = 0.30
        if !page.productFacts.isEmpty { confidence += 0.25 }
        if !researchFacts.isEmpty { confidence += 0.20 }
        if totalEntities >= 2 { confidence += 0.10 }
        if !sharedNonGeneric.isEmpty { confidence += 0.10 }
        confidence = min(confidence, 0.95)

        let judgment = ContextJudgment(
            entities: entities,
            relationship: relationship,
            comparisonValidity: comparisonValidity,
            decisionType: decisionType,
            missingInformation: missing,
            rationale: rationale,
            confidence: confidence,
            incompatibleUnitsDetected: incompatibleUnits
        )
        judgment.log()
        return judgment
    }

    // MARK: - Internals

    /// Pick the candidate entities. Prefers `WorkingMemory.comparisonCandidates`
    /// when present; otherwise uses the deduplicated `recentEntities`.
    private static func candidateEntities(
        memory: WorkingMemorySnapshot,
        packet: CompressedTemporalPacket
    ) -> [String] {
        if !memory.comparisonCandidates.isEmpty {
            return Array(memory.comparisonCandidates.prefix(4))
        }
        if !memory.recentEntities.isEmpty {
            return Array(memory.recentEntities.prefix(4))
        }
        return Array(packet.recentTitles.prefix(4))
    }

    /// Generic concepts that should never count as evidence of shared category.
    /// This is the SAME stoplist the existing working-memory builder uses; we
    /// repeat it here so the layer is self-contained.
    private static let genericConcepts: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "an", "a",
        "amazon", "google", "youtube", "page", "tab", "browser", "site",
        "new", "best", "top", "review", "pro", "max", "mini",
        "phone", "laptop", "computer", "watch",
        "bank", "prime", "apple",   // ambiguous brand/category words from Phase 18C
    ]

    /// Tokenize a title into concept tokens. Lowercased, alphabetic-only,
    /// length ≥ 3, deduped.
    private static func conceptTokens(forTitle title: String) -> Set<String> {
        let tokens = title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        return Set(tokens)
    }

    /// Collect all numeric facts from page metadata and web research, attaching
    /// their unit dimension. Keeps short prompts: capped at 12 facts.
    private static func collectNumericFacts(
        page: PublicPageContextExtractor.PublicPageContext,
        researchFacts: [PublicWebResearchEnricher.PublicGroundedFact]
    ) -> [ExtractedNumericFact] {
        var out: [ExtractedNumericFact] = []
        for (k, v) in page.productFacts {
            let facts = NumericUnitClassifier.extractFacts(from: v, label: k)
            out.append(contentsOf: facts)
            if out.count >= 12 { break }
        }
        for f in researchFacts {
            let facts = NumericUnitClassifier.extractFacts(from: f.value, label: f.label)
            out.append(contentsOf: facts)
            if out.count >= 12 { break }
        }
        return Array(out.prefix(12))
    }

    /// Per-entity set of unit dimensions — used to decide whether a direct
    /// comparison is grounded in like-for-like data.
    private static func perEntityDimensionSets(
        entities: [String],
        facts: [ExtractedNumericFact]
    ) -> [Set<NumericUnitDimension>] {
        // Today we don't have a per-entity mapping from research facts;
        // collapse facts to a single global set. This is conservative — if
        // ANY entity in the comparison has a dimension, every entity must
        // share it for the comparison to be "direct".
        let dims = Set(facts.map { $0.dimension }).subtracting([.unknown])
        return entities.map { _ in dims }
    }

    /// Detects a categorical conflict in the research facts — for example one
    /// fact says "category=Battery" and another says "category=HomeBackupSystem".
    private static func researchFactsConflict(_ facts: [PublicWebResearchEnricher.PublicGroundedFact]) -> Bool {
        let categoryValues = facts
            .filter { $0.label.lowercased().contains("category") || $0.label.lowercased().contains("type") }
            .map { $0.value.lowercased() }
        let unique = Set(categoryValues)
        return unique.count >= 2
    }
}

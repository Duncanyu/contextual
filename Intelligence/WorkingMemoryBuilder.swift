import Foundation

public enum WorkingMemoryBuilder {
    
    private static func checkSemanticOverlap(
        title: String,
        current: String
    ) -> (hasOverlap: Bool, basis: [String]) {
        var basis: [String] = []
        
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "page", "home", "document", "google", 
            "search", "course", "studying", "about", "web", "new", "tab", "my"
        ]
        
        func cleanAndTokenize(_ s: String) -> Set<String> {
            let clean = s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 3 && !stopWords.contains($0) }
            return Set(clean)
        }
        
        let currentTokens = cleanAndTokenize(current)
        let titleTokens = cleanAndTokenize(title)
        
        // 1. Title overlap / Shared tokens
        let intersection = currentTokens.intersection(titleTokens)
        if !intersection.isEmpty {
            basis.append("shared_tokens")
        }
        
        // 2. Same host / same path (parsed from title domain suffixes or markers like queen's, amazon, etc.)
        let hosts = ["amazon", "queensu", "onq", "wikipedia", "github", "stackoverflow", "youtube"]
        let lowerCurrent = current.lowercased()
        let lowerTitle = title.lowercased()
        
        var sharedHost = false
        for host in hosts {
            if lowerCurrent.contains(host) && lowerTitle.contains(host) {
                sharedHost = true
                break
            }
        }
        
        // Also if they both contain ".com" or ".org" or ".ca" or ".edu"
        let domainIndicators = [".com", ".org", ".ca", ".edu", ".net", ".io"]
        for ind in domainIndicators {
            if lowerCurrent.contains(ind) && lowerTitle.contains(ind) {
                sharedHost = true
                break
            }
        }
        
        if sharedHost {
            basis.append("same_host")
        }
        
        // Same path: if they share path-like terms or specific directories/codes
        let paths = ["week", "cisc", "computational", "thinking", "problem", "solving", "outline", "syllabus"]
        var sharedPath = false
        for path in paths {
            if lowerCurrent.contains(path) && lowerTitle.contains(path) {
                sharedPath = true
                break
            }
        }
        if sharedPath {
            basis.append("same_path")
        }
        
        // Recency: if they are in the same tab list and share any minimal word, or just because they are open nearby
        if !intersection.isEmpty {
            basis.append("recency")
        }
        
        let uniqueBasis = Array(Set(basis)).sorted()
        return (!uniqueBasis.isEmpty, uniqueBasis)
    }

    public static func build(
        workflow: WorkflowState,
        behavior: BehavioralStateRecord,
        packet: CompressedTemporalPacket,
        browserTabTitles: [String] = [],
        selectedBrowserTabTitle: String? = nil,
        activeCompartment: TaskCompartment? = nil,
        allCompartments: [TaskCompartment] = []
    ) -> WorkingMemorySnapshot {
        
        // Filter raw titles
        let trimmedTabs = browserTabTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let titleCandidates: [String] = {
            if !trimmedTabs.isEmpty {
                var used = Array(trimmedTabs.prefix(12))
                // Put selected tab first so `currentEntity` tracks focus.
                if let sel = selectedBrowserTabTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !sel.isEmpty {
                    if let idx = used.firstIndex(of: sel) {
                        used.remove(at: idx)
                    }
                    used.insert(sel, at: 0)
                }
                return used
            }
            return packet.recentTitles
        }()

        let currentEntity = titleCandidates.first ?? "Unknown"
        
        var relatedFocusEntities: [String] = []
        var backgroundEntities: [String] = []
        var staleEntities: [String] = []
        var allBasis: Set<String> = []

        for title in titleCandidates {
            if title.isEmpty { continue }
            if title == currentEntity { continue }
            
            let (hasOverlap, basis) = checkSemanticOverlap(title: title, current: currentEntity)
            if hasOverlap {
                relatedFocusEntities.append(title)
                allBasis.formUnion(basis)
            } else {
                if ContextEpochTracker.shared.isStale(title: title) {
                    staleEntities.append(title)
                } else {
                    backgroundEntities.append(title)
                }
            }
        }
        
        // Logs required by Failure 1 and 2
        print("[WorkingMemory] current_entity=\"\(currentEntity)\"")
        print("[WorkingMemory] related_focus_entities=[\(relatedFocusEntities.joined(separator: ", "))]")
        print("[WorkingMemory] background_entities=[\(backgroundEntities.joined(separator: ", "))]")
        print("[WorkingMemory] stale_entities=[\(staleEntities.joined(separator: ", "))]")
        print("[WorkingMemory] related_focus_entities count=\(relatedFocusEntities.count)")
        
        if !relatedFocusEntities.isEmpty {
            let basisStr = allBasis.isEmpty ? "recency" : Array(allBasis).sorted().joined(separator: "|")
            print("[WorkingMemory] relationship_basis=\(basisStr)")
        }
        
        // Construct recentEntities (excluding stale)
        var recentEntities = [currentEntity]
        recentEntities.append(contentsOf: relatedFocusEntities)
        recentEntities.append(contentsOf: backgroundEntities)
        
        // 2. Filter repeated concepts (Bug 2 defensive filtering)
        let baseTerms: [String] = {
            let terms = activeCompartment?.dominantTerms.map { $0 } ?? packet.topicTerms
            return Array(terms).sorted()
        }()
        
        let focusTokens: Set<String> = {
            let joined = ([currentEntity] + relatedFocusEntities).joined(separator: " ")
            let toks = joined.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && $0.count <= 24 }
            return Set(toks)
        }()
        
        var rejectedBackground: [String] = []
        var acceptedFocus: [String] = []
        
        for raw in baseTerms {
            let t = raw.lowercased()
            if focusTokens.contains(t) {
                acceptedFocus.append(t)
            } else {
                rejectedBackground.append(t)
            }
        }
        
        print("[WorkingMemory] active_terms_before_filter=\(baseTerms.joined(separator: ","))")
        print("[WorkingMemory] rejected_background_terms=\(rejectedBackground.joined(separator: ","))")
        print("[WorkingMemory] active_terms_after_filter=\(acceptedFocus.joined(separator: ","))")
        
        let repeatedConcepts = acceptedFocus
        
        let activityVerb: String
        if behavior.state == .unknown || behavior.state.rawValue == workflow.workflowType.rawValue {
            activityVerb = workflow.workflowType.rawValue
        } else {
            activityVerb = behavior.state.rawValue
        }
        
        let conceptsStr = repeatedConcepts.prefix(3).joined(separator: " ")
        let inferredActivity = conceptsStr.isEmpty ? activityVerb : "\(activityVerb) \(conceptsStr)"
        
        // Bug 4 — comparison candidates propagation for shopping/comparing
        // Phase 21.2 — block comparison candidates when current context is
        // clearly email/document work (not commercial intent).
        let comparisonCandidates: [String] = {
            let isShoppingOrComparing = workflow.workflowType == .shopping || workflow.workflowType == .comparing ||
                                        behavior.state == .comparing || behavior.state == .shopping
            let emailDocTerms: Set<String> = ["gmail", "inbox", "sent", "mail", "invoice", "receipt", "payment", "client", "document", "attachment", "contract", "billing"]
            let entityTokens = Set((currentEntity + " " + relatedFocusEntities.joined(separator: " ")).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
            let hasEmailDocContext = !entityTokens.intersection(emailDocTerms).isEmpty
            let explicitShoppingTerms: Set<String> = ["price", "buy", "cart", "checkout", "purchase", "order", "product", "store", "shop"]
            let hasExplicitShopping = !entityTokens.intersection(explicitShoppingTerms).isEmpty
            let isActualShopping = isShoppingOrComparing && !(hasEmailDocContext && !hasExplicitShopping)

            if isActualShopping {
                let candidates = [currentEntity] + relatedFocusEntities
                print("[WorkingMemory] comparison_candidates_source=current_plus_related_focus")
                print("[WorkingMemory] comparison_candidates_count=\(candidates.count)")
                return candidates
            } else {
                if let active = activeCompartment {
                    let activeEntities = recentEntities.filter { active.entities.contains($0) || $0 == currentEntity }
                    return activeEntities.count == 1 ? Array(activeEntities.prefix(1)) : []
                } else {
                    return recentEntities.count == 1 ? Array(recentEntities.prefix(1)) : []
                }
            }
        }()
        
        if let active = activeCompartment {
            print("[WorkingMemory] compartment_id=\(active.id)")
            print("[WorkingMemory] compartment_label=\"\(active.label)\"")
            print("[WorkingMemory] active_terms=\(repeatedConcepts.joined(separator: ","))")
            let bg = allCompartments.filter { $0.id != active.id }.map { $0.label }
            print("[WorkingMemory] background_compartments=[\(bg.joined(separator: ", "))]")
        }

        func simpleTokenize(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && $0.count <= 24 && Int($0) == nil }
        }
        let currentFocusTerms = Array(Set(simpleTokenize(currentEntity))).sorted()
        let relatedTerms = Array(Set(relatedFocusEntities.flatMap { simpleTokenize($0) })).sorted()
        let backgroundTerms = Array(Set(backgroundEntities.flatMap { simpleTokenize($0) })).sorted()

        print("[WorkingMemory] current_focus_terms=\(currentFocusTerms.joined(separator: ","))")
        print("[WorkingMemory] related_terms=\(relatedTerms.joined(separator: ","))")
        print("[WorkingMemory] background_terms=\(backgroundTerms.joined(separator: ","))")
        
        let snapshot = WorkingMemorySnapshot(
            currentEntity: currentEntity,
            recentEntities: recentEntities,
            repeatedConcepts: repeatedConcepts,
            inferredActivity: inferredActivity,
            comparisonCandidates: comparisonCandidates,
            staleEntities: staleEntities,
            relatedFocusEntities: relatedFocusEntities,
            backgroundEntities: backgroundEntities,
            currentFocusTerms: currentFocusTerms,
            relatedTerms: relatedTerms,
            backgroundTerms: backgroundTerms
        )
        
        print("[WorkingMemory] recent_entities=[\(recentEntities.joined(separator: ", "))]")
        print("[WorkingMemory] comparison_candidates=[\(comparisonCandidates.joined(separator: ", "))]")
        print("[WorkingMemory] entities=\(recentEntities.count) concepts=\(repeatedConcepts.count) comparisons=\(comparisonCandidates.count)")
        print("[WorkingMemory] summary=\"\(inferredActivity)\"")
        
        return snapshot
    }
}

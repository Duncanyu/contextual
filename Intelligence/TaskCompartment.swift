import Foundation

public struct TaskCompartment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workflow: AmbientWorkflowType
    public let label: String
    public var dominantTerms: Set<String>
    public var entities: Set<String>
    public var browserTabs: Set<String>
    public let firstSeen: Date
    public var lastSeen: Date
    public var confidence: Double
    public var activeScore: Double
    public var staleScore: Double

    // Phase 21.4 — Dwell tracking.
    // Set when this compartment first becomes the active compartment.
    public var firstActivatedAt: Date?

    /// Seconds this compartment has been continuously active (since first activation).
    public var dwellSeconds: TimeInterval {
        guard let activated = firstActivatedAt else { return 0 }
        return max(0, Date().timeIntervalSince(activated))
    }

    public var dwellState: ActivityState.DwellState {
        if dwellSeconds < 120 { return .fresh }
        if dwellSeconds < 600 { return .settled }
        return .deep_work
    }

    // Phase 20I: Trust & Entity Metrics
    public var compartmentTrust: Double {
        let e = Double(entities.count) * 0.15
        let t = Double(dominantTerms.count) * 0.10
        let r = Double(browserTabs.count) * 0.05
        let base = min(0.95, confidence + e + t + r)
        let freshness = currentEntityFreshness
        // Phase 21.4 — Dwell boost: long active dwell increases trust even when
        // content extraction is weak (e.g., canvas game with no AX text).
        let dwellMinutes = dwellSeconds / 60.0
        let dwellBoost = min(0.30, dwellMinutes * 0.02)   // +0.02 per minute, cap +0.30
        let boosted = min(0.95, base + dwellBoost)
        return boosted * freshness
    }
    
    public var entityCount: Int { entities.count }
    public var activeTermCount: Int { dominantTerms.count }
    public var relatedEntityCount: Int { browserTabs.count }
    
    public var currentEntityFreshness: Double {
        let seconds = Date().timeIntervalSince(lastSeen)
        if seconds < 60 { return 1.0 }
        if seconds < 300 { return 0.8 }
        if seconds < 900 { return 0.5 }
        return 0.2
    }
    
    public var focusMatchScore: Double {
        // High if we just saw it, decaying over time.
        activeScore * currentEntityFreshness
    }
    
    public init(
        id: UUID = UUID(),
        workflow: AmbientWorkflowType,
        label: String,
        dominantTerms: Set<String>,
        entities: Set<String>,
        browserTabs: Set<String>,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        confidence: Double = 0.8,
        activeScore: Double = 1.0,
        staleScore: Double = 0.0,
        firstActivatedAt: Date? = nil
    ) {
        self.id = id
        self.workflow = workflow
        self.label = label
        self.dominantTerms = dominantTerms
        self.entities = entities
        self.browserTabs = browserTabs
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.confidence = confidence
        self.activeScore = activeScore
        self.staleScore = staleScore
        self.firstActivatedAt = firstActivatedAt
    }
}

@MainActor
public final class TaskCompartmentTracker {
    public static let shared = TaskCompartmentTracker()
    
    public private(set) var compartments: [TaskCompartment] = []
    public private(set) var activeCompartmentId: UUID? = nil
    
    private init() {}
    
    public func reset() {
        compartments.removeAll()
        activeCompartmentId = nil
    }
    
    public func setCompartments(_ comps: [TaskCompartment], activeId: UUID?) {
        self.compartments = comps
        self.activeCompartmentId = activeId
    }
    
    private func isTermSupported(
        _ term: String,
        comp: TaskCompartment?,
        cleanTitle: String,
        tabs: [String],
        epochTerms: Set<String>
    ) -> Bool {
        let t = term.lowercased()
        
        // Helper to check token presence
        func textContainsToken(_ text: String, _ token: String) -> Bool {
            let textTokens = Self.extractCleanTokens(from: text)
            return textTokens.contains(token)
        }
        
        // 1. Selected/current entity title
        if textContainsToken(cleanTitle, t) {
            return true
        }
        
        // 2. relatedFocusEntities / tabs / URLs assigned to that compartment (both passed tabs and existing comp.browserTabs)
        for tab in tabs {
            if textContainsToken(tab, t) {
                return true
            }
        }
        
        if let comp = comp {
            // 3. Titles already assigned to that compartment
            for ent in comp.entities {
                if textContainsToken(ent, t) {
                    return true
                }
            }
            // 4. URLs/tabs assigned to that compartment
            for tab in comp.browserTabs {
                if textContainsToken(tab, t) {
                    return true
                }
            }
        }
        
        // 5. Current epoch terms that overlap with that compartment
        if epochTerms.contains(t) {
            if let comp = comp, comp.dominantTerms.contains(t) {
                return true
            }
        }
        
        return false
    }

    @discardableResult
    public func ingestUpdate(
        workflow: AmbientWorkflowType,
        behavior: BehavioralState,
        title: String,
        tabs: [String],
        topicTerms: [String]
    ) -> TaskCompartment {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTerms = Set(topicTerms.map { $0.lowercased() })
        let cleanTitleTokens = Self.extractCleanTokens(from: cleanTitle)
        let combinedTerms = cleanTitleTokens.union(incomingTerms)
        
        let bestWorkflow = workflow == .unknown ? (behavior == .unknown ? .browsing : AmbientWorkflowType(rawString: behavior.rawValue)) : workflow
        
        // Find best match among existing compartments
        let matched = findBestCompartment(workflow: bestWorkflow, title: cleanTitle, tabs: tabs, cleanTokens: combinedTerms)
        
        // Build accepted/rejected terms
        let epochTerms = Set(ContextEpochTracker.shared.currentEpoch().terms.map { $0.lowercased() })
        let fullUnion = (matched?.dominantTerms ?? []).union(combinedTerms)
        var accepted: Set<String> = []
        var rejected: [String] = []
        
        for term in fullUnion {
            if isTermSupported(term, comp: matched, cleanTitle: cleanTitle, tabs: tabs, epochTerms: epochTerms) {
                accepted.insert(term)
            } else {
                rejected.append(term)
            }
        }
        
        print("[TaskCompartment] update_source=current_focus|related_entities|global_packet")
        let rejectedSorted = rejected.sorted()
        print("[TaskCompartment] rejected_terms=[\(rejectedSorted.joined(separator: ","))] reason=not_supported_by_active_compartment")
        let acceptedSorted = accepted.sorted()
        print("[TaskCompartment] terms_after_filter=\(acceptedSorted.joined(separator: ","))")
        
        let active: TaskCompartment
        if let existing = matched {
            // Update existing compartment
            var updated = existing
            updated.dominantTerms = accepted
            if !cleanTitle.isEmpty {
                updated.entities.insert(cleanTitle)
            }
            for t in tabs {
                updated.browserTabs.insert(t)
            }
            updated.lastSeen = Date()
            
            // Save it
            if let idx = compartments.firstIndex(where: { $0.id == existing.id }) {
                compartments[idx] = updated
            }
            
            active = updated
            let sortedTerms = updated.dominantTerms.sorted().joined(separator: ",")
            print("[TaskCompartment] updated id=\(updated.id) terms=\(sortedTerms)")
            
            // Handle activation if it changed
            if activeCompartmentId != updated.id {
                triggerActivation(active: updated)
            }
        } else {
            // Create a new compartment
            let label = Self.extractLabel(from: cleanTitle, tabs: tabs, workflow: bestWorkflow)
            let newComp = TaskCompartment(
                workflow: bestWorkflow,
                label: label,
                dominantTerms: accepted,
                entities: cleanTitle.isEmpty ? [] : [cleanTitle],
                browserTabs: Set(tabs)
            )
            compartments.append(newComp)
            active = newComp
            
            print("[TaskCompartment] created id=\(newComp.id) workflow=\(bestWorkflow.rawValue) label=\"\(label)\"")
            
            triggerActivation(active: newComp)
        }
        
        // Required candidate print
        print("[TaskCompartment] active id=\(active.id) label=\"\(active.label)\" workflow=\(active.workflow.rawValue)")
        print("[TaskCompartment] candidates count=\(compartments.count)")
        
        return active
    }
    
    public func getActiveCompartment() -> TaskCompartment? {
        return compartments.first { $0.id == activeCompartmentId }
    }
    
    // MARK: - Internals
    
    private func triggerActivation(active: TaskCompartment) {
        if let prevId = activeCompartmentId, prevId != active.id {
            if let prevIdx = compartments.firstIndex(where: { $0.id == prevId }) {
                let prev = compartments[prevIdx]
                print("[TaskCompartment] deactivated id=\(prev.id) reason=focus_shift")
                print("[TaskCompartment] deactivated label=\"\(prev.label)\"")
            }
        }
        activeCompartmentId = active.id
        // Phase 21.4 — Record first activation time for dwell tracking.
        if let idx = compartments.firstIndex(where: { $0.id == active.id }),
           compartments[idx].firstActivatedAt == nil {
            compartments[idx].firstActivatedAt = Date()
        }
        print("[TaskCompartment] activated id=\(active.id) reason=current_focus_match")
        print("[TaskCompartment] activated label=\"\(active.label)\"")
        // Log dwell state if re-activating a previously seen compartment
        let dwell = active.dwellSeconds
        if dwell > 0 {
            let dwellStr = String(format: "%.0f", dwell)
            print("[CompartmentDwell] duration_s=\(dwellStr) state=\(active.dwellState.rawValue)")
            if active.dwellState == .deep_work {
                let trustStr = String(format: "%.2f", active.compartmentTrust)
                print("[CompartmentTrust] boosted reason=dwell_time_activity trust=\(trustStr)")
            }
        }
    }
    
    private func findBestCompartment(
        workflow: AmbientWorkflowType,
        title: String,
        tabs: [String],
        cleanTokens: Set<String>
    ) -> TaskCompartment? {
        var bestMatch: TaskCompartment? = nil
        var bestScore = 0.0
        
        for comp in compartments {
            // 1. Workflow compatibility:
            let isCompStudy = comp.workflow == .studying || comp.workflow == .reading || comp.workflow == .researching
            let isCurrentStudy = workflow == .studying || workflow == .reading || workflow == .researching
            
            let isCompShop = comp.workflow == .shopping || comp.workflow == .comparing
            let isCurrentShop = workflow == .shopping || workflow == .comparing
            
            if isCompStudy != isCurrentStudy {
                continue
            }
            if isCompShop != isCurrentShop {
                continue
            }
            
            // 2. Token overlap:
            let titleOverlap = comp.dominantTerms.intersection(cleanTokens)
            var overlapCount = Double(titleOverlap.count) * 3.0
            
            // Tab token overlap
            for tab in tabs {
                let tabTokens = Self.extractCleanTokens(from: tab)
                let tabOverlap = comp.dominantTerms.intersection(tabTokens)
                overlapCount += Double(tabOverlap.count) * 0.4
            }
            
            // Add a small recency bonus
            let recencyBonus = max(0.0, 1.0 - Date().timeIntervalSince(comp.lastSeen) / 300.0)
            let score = overlapCount + recencyBonus
            
            // Score threshold of 1.2 to be a valid match
            if score > 1.2 && score > bestScore {
                bestScore = score
                bestMatch = comp
            }
        }
        
        return bestMatch
    }
    
    public static func extractCleanTokens(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "page", "home", "document", "google", 
            "search", "course", "studying", "about", "web", "new", "tab", "my",
            "safari", "firefox", "chrome", "amazon", "ca", "com", "html", "untitled"
        ]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Set(words)
    }
    
    public static func extractLabel(from title: String, tabs: [String], workflow: AmbientWorkflowType) -> String {
        let cleanTitle = title.replacingOccurrences(of: " - Google Search", with: "")
            .replacingOccurrences(of: " : Amazon.ca", with: "")
            .replacingOccurrences(of: " | Wikipedia", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let targetString = cleanTitle.isEmpty ? (tabs.first ?? "") : cleanTitle
        if targetString.isEmpty {
            return workflow == .studying ? "Study Outline" : "General Browsing"
        }
        
        // 1. Search for standard subject/course codes (e.g., CISC 121, BOTA 301, CISC-121, BOTA301).
        let pattern = "\\b([A-Z]{3,4})[\\s-]?(\\d{3})\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsRange = NSRange(targetString.startIndex..<targetString.endIndex, in: targetString)
            if let match = regex.firstMatch(in: targetString, options: [], range: nsRange),
               let range = Range(match.range, in: targetString) {
                return String(targetString[range]).uppercased()
            }
        }
        
        let words = targetString.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        let labelStopWords: Set<String> = [
            "how", "what", "why", "who", "when", "where", "your", "their", "our", "you",
            "this", "that", "with", "from", "the", "and", "for", "page", "home", "document",
            "google", "search", "safari", "firefox", "chrome", "amazon", "web", "untitled"
        ]
        
        let significant = words.filter { w in
            let lower = w.lowercased()
            return w.count >= 3 && !labelStopWords.contains(lower)
        }
        
        if significant.count >= 2 {
            let word1 = significant[0].capitalized
            let word2 = significant[1].capitalized
            return "\(word1) \(word2)"
        } else if let single = significant.first {
            return single.capitalized
        }
        
        return String(targetString.prefix(25))
    }
}

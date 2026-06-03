import Foundation

/// Phase 26 — Converts friction signals into actionable opportunities.
///
/// Priority order (highest to lowest):
///   1. Friction reduction (environment action that removes annoyance)
///   2. Environment action (launch app, restore workspace)
///   3. Cognitive action (explain, summarize — only if friction-justified)
///   4. Text artifact (checklist, quiz — lowest priority)
///
/// Every proposal must answer: "What annoyance does this remove?"
/// If no answer exists, suppress the proposal.
///
/// Required logs: [FrictionOpportunity], [FrictionReduction], [ProposalQuality]
enum FrictionOpportunityReasoner {

    // MARK: - Output

    struct FrictionOpportunity {
        let capabilityId: String        // e.g. "restore_workspace", "pin_reference"
        let title: String               // user-facing proposal text
        let frictionType: FrictionType  // which friction this removes
        let frictionRemoved: String     // human-readable explanation
        let confidence: Double          // 0..1
        let requiresConfirmation: Bool  // environment actions always need confirmation
        let involvedApps: [String]      // apps that would be launched/arranged
    }

    // MARK: - Scoring

    /// Score a friction signal's opportunity potential.
    /// Returns nil if the friction isn't strong enough to warrant a proposal.
    static func reason(
        frictionSignals: [FrictionSignal],
        workspacePatterns: [WorkspacePattern],
        currentApps: Set<String>,
        currentEntity: String,
        compartmentLabel: String
    ) -> [FrictionOpportunity] {

        var opportunities: [FrictionOpportunity] = []

        for signal in frictionSignals {
            guard signal.confidence >= 0.40 else {
                print("[FrictionOpportunity] skipped type=\(signal.type.rawValue)"
                    + " reason=low_confidence"
                    + " confidence=\(String(format: "%.2f", signal.confidence))")
                print("""
                [FrictionAudit]
                signal=\(signal.type.rawValue)
                confidence=\(String(format: "%.2f", signal.confidence))
                evidence=\(signal.evidence.joined(separator: ","))

                generated_candidate=no
                candidate=none
                """)
                continue
            }

            var generatedCandidate: String? = nil
            switch signal.type {

            case .repeated_app_switching:
                if let opp = handleAppOscillation(signal: signal,
                                                   patterns: workspacePatterns,
                                                   currentApps: currentApps) {
                    opportunities.append(opp)
                    generatedCandidate = opp.capabilityId
                }

            case .repeated_tab_switching:
                // Phase 26.1 — Browser tab pinning is not wired. Use honest title.
                // "Pin tabs" implies browser-level pinning; "Collect" is what actually executes.
                let opp = FrictionOpportunity(
                    capabilityId: "pin_reference_tabs",
                    title: "Collect the tabs you keep switching between?",
                    frictionType: .repeated_tab_switching,
                    frictionRemoved: "Stops revisiting \(signal.evidence.first ?? "tabs") repeatedly",
                    confidence: signal.confidence,
                    requiresConfirmation: true,
                    involvedApps: []
                )
                opportunities.append(opp)
                generatedCandidate = opp.capabilityId

            case .repeated_reference_lookup:
                let concepts = signal.evidence.prefix(2).joined(separator: ", ")
                let opp = FrictionOpportunity(
                    capabilityId: "collect_references",
                    title: "Collect the references you keep looking up?",
                    frictionType: .repeated_reference_lookup,
                    frictionRemoved: "Consolidates repeated searches for \(concepts)",
                    confidence: signal.confidence,
                    requiresConfirmation: false,
                    involvedApps: []
                )
                opportunities.append(opp)
                generatedCandidate = opp.capabilityId

            case .repeated_workspace_reconstruction:
                if let opp = handleWorkspaceReconstruction(signal: signal,
                                                            patterns: workspacePatterns,
                                                            currentApps: currentApps) {
                    opportunities.append(opp)
                    generatedCandidate = opp.capabilityId
                }

            case .repeated_copy_paste:
                let opp = FrictionOpportunity(
                    capabilityId: "extract_and_organize",
                    title: "Extract the content you keep copying between apps?",
                    frictionType: .repeated_copy_paste,
                    frictionRemoved: "Eliminates manual copy-paste cycle",
                    confidence: signal.confidence,
                    requiresConfirmation: false,
                    involvedApps: signal.involvedApps
                )
                opportunities.append(opp)
                generatedCandidate = opp.capabilityId

            case .repeated_window_restore:
                let opp = FrictionOpportunity(
                    capabilityId: "restore_workspace",
                    title: "Reopen the windows you keep restoring?",
                    frictionType: .repeated_window_restore,
                    frictionRemoved: "Stops repeated window restoration",
                    confidence: signal.confidence,
                    requiresConfirmation: true,
                    involvedApps: signal.involvedApps
                )
                opportunities.append(opp)
                generatedCandidate = opp.capabilityId

            case .repeated_media_toggle:
                let opp = FrictionOpportunity(
                    capabilityId: "resume_focus_media",
                    title: "Resume the playlist you usually use here?",
                    frictionType: .repeated_media_toggle,
                    frictionRemoved: "Removes repeated play/pause toggling",
                    confidence: signal.confidence,
                    requiresConfirmation: true,
                    involvedApps: []
                )
                opportunities.append(opp)
                generatedCandidate = opp.capabilityId

            case .repeated_ai_assistant_usage:
                let opp = FrictionOpportunity(
                    capabilityId: "precompute_answer",
                    title: "Pre-load the answer you keep asking for?",
                    frictionType: .repeated_ai_assistant_usage,
                    frictionRemoved: "Reduces repeated AI queries for the same topic",
                    confidence: signal.confidence,
                    requiresConfirmation: false,
                    involvedApps: []
                )
                opportunities.append(opp)
                generatedCandidate = opp.capabilityId
            }

            if let generatedCandidate {
                print("""
                [FrictionAudit]
                signal=\(signal.type.rawValue)
                confidence=\(String(format: "%.2f", signal.confidence))
                evidence=\(signal.evidence.joined(separator: ","))

                generated_candidate=yes
                candidate=\(generatedCandidate)
                """)
            } else {
                print("""
                [FrictionAudit]
                signal=\(signal.type.rawValue)
                confidence=\(String(format: "%.2f", signal.confidence))
                evidence=\(signal.evidence.joined(separator: ","))

                generated_candidate=no
                candidate=none
                """)
            }
        }

        // Sort by confidence descending
        opportunities.sort { $0.confidence > $1.confidence }

        // Log results
        if let top = opportunities.first {
            print("[FrictionOpportunity] selected=\(top.capabilityId)"
                + " friction=\(top.frictionType.rawValue)"
                + " confidence=\(String(format: "%.2f", top.confidence))"
                + " removes=\"\(top.frictionRemoved)\"")
            print("[FrictionReduction] action=\(top.capabilityId)"
                + " title=\"\(top.title)\"")
        } else if !frictionSignals.isEmpty {
            print("[FrictionOpportunity] none_actionable"
                + " signals=\(frictionSignals.count)")
        }

        return opportunities
    }

    // MARK: - Quality gate

    /// Validate that a proposal actually removes friction.
    /// Returns true if the proposal answers "what annoyance does this remove?"
    static func validateProposalQuality(
        title: String,
        frictionRemoved: String?,
        hasFrictionSignal: Bool
    ) -> Bool {
        // Text-generation proposals without friction backing are rejected
        if !hasFrictionSignal && frictionRemoved == nil {
            print("[ProposalQuality] rejected reason=no_friction_removed"
                + " title=\"\(title.prefix(60))\"")
            return false
        }
        print("[ProposalQuality] accepted"
            + " title=\"\(title.prefix(60))\""
            + " friction_removed=\"\(frictionRemoved?.prefix(60) ?? "none")\"")
        return true
    }

    // MARK: - Friction-specific handlers

    private static func handleAppOscillation(
        signal: FrictionSignal,
        patterns: [WorkspacePattern],
        currentApps: Set<String>
    ) -> FrictionOpportunity? {
        let apps = signal.involvedApps

        // Check if we have a learned workspace pattern that includes these apps
        let matchingPattern = patterns.first { pattern in
            let patternLower = Set(pattern.apps.map { $0.lowercased() })
            return apps.allSatisfy { patternLower.contains($0.lowercased()) }
        }

        if let pattern = matchingPattern {
            // We know this workspace — offer to arrange it
            let missing = WorkspacePatternTracker.shared.missingApps(
                from: pattern, currentApps: currentApps)
            if !missing.isEmpty {
                return FrictionOpportunity(
                    capabilityId: "restore_workspace",
                    title: "Open your usual \(pattern.label) setup?",
                    frictionType: .repeated_app_switching,
                    frictionRemoved: "Stops switching between \(apps.joined(separator: " and "))",
                    confidence: signal.confidence * 1.1,  // boost for known pattern
                    requiresConfirmation: true,
                    involvedApps: missing
                )
            }
        }

        // No known workspace — still offer to arrange the oscillating pair
        return FrictionOpportunity(
            capabilityId: "arrange_side_by_side",
            title: "Put \(apps.prefix(2).joined(separator: " and ")) side by side?",
            frictionType: .repeated_app_switching,
            frictionRemoved: "Stops switching between \(apps.joined(separator: " and "))",
            confidence: signal.confidence,
            requiresConfirmation: true,
            involvedApps: apps
        )
    }

    private static func handleWorkspaceReconstruction(
        signal: FrictionSignal,
        patterns: [WorkspacePattern],
        currentApps: Set<String>
    ) -> FrictionOpportunity? {
        // Find the most relevant learned pattern
        guard let pattern = patterns.first else { return nil }

        let missing = WorkspacePatternTracker.shared.missingApps(
            from: pattern, currentApps: currentApps)
        guard !missing.isEmpty else { return nil }

        return FrictionOpportunity(
            capabilityId: "restore_workspace",
            title: "Open your usual \(pattern.label) setup?",
            frictionType: .repeated_workspace_reconstruction,
            frictionRemoved: "Skips manual workspace setup (done \(pattern.frequency)x before)",
            confidence: min(0.95, signal.confidence + 0.10),
            requiresConfirmation: true,
            involvedApps: missing
        )
    }
}

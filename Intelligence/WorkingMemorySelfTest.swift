import Foundation

/// Phase 20G.5 — WorkingMemory classification self test
///
/// Trigger:
///   CONTEXTUAL_RUN_WORKING_MEMORY_SELFTEST=1
@MainActor
public struct WorkingMemorySelfTest: Sendable {
    
    public static func run() async -> Bool {
        print("[WorkingMemorySelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[WorkingMemorySelfTest] pass case=\(name)") }
            else  { print("[WorkingMemorySelfTest] fail case=\(name)"); failures.append(name) }
        }
        
        let now = Date()
        let workflow = WorkflowState(
            workflowType: .studying,
            confidence: 0.85,
            evidence: ["test"],
            uncertainty: "none",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.80,
            dominantApps: ["Firefox"],
            repeatedTerms: ["cisc"],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "abc"
        )
        
        let behavior = BehavioralStateRecord(
            state: .learning,
            confidence: 0.80,
            reasoning: "test",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.75
        )
        
        let packet = CompressedTemporalPacket(
            currentApp: "Firefox",
            recentApps: ["Firefox"],
            recentTitles: ["Week-2 - CISC 121"],
            topicTerms: ["cisc", "121"],
            activityPattern: "active",
            idlePattern: "active",
            typingPattern: "none",
            pointerPattern: "active",
            ocrHints: [],
            selectionHints: [],
            clipboardMetadata: "none",
            recentUserAccepts: [],
            recentUserIgnores: [],
            spanSeconds: 120,
            eventCount: 5,
            contextShiftDetected: false
        )
        
        // Setup current epoch
        ContextEpochTracker.shared.resetForTests()
        ContextEpochTracker.shared.observe(
            contextShiftDetected: false,
            shiftReason: "seed",
            earlyTopTerms: [],
            recentTopTerms: ["cisc", "121", "study", "thinking"],
            recentTitles: ["Week-2 - CISC 121"]
        )
        
        let tabs = [
            "Week-2 - CISC 121",
            "Computational Thinking - CISC 121",
            "Problem Solving - CISC 121",
            "Programming Tools - CISC 121",
            "AI and CODE review Basics - CISC 121",
            "how to advertise your rental property - Google Search",
            "Amazon.ca: Buy Anker Prime 200W"
        ]
        
        // Test 1: Selected CISC tab keeps related CISC tabs as relatedFocusEntities
        let mem = WorkingMemoryBuilder.build(
            workflow: workflow,
            behavior: behavior,
            packet: packet,
            browserTabTitles: tabs,
            selectedBrowserTabTitle: "Week-2 - CISC 121"
        )
        
        check("primary_selected_tab_is_current", mem.currentEntity == "Week-2 - CISC 121")
        check("keeps_related_cisc_tabs", mem.relatedFocusEntities.contains("Computational Thinking - CISC 121") && mem.relatedFocusEntities.contains("Problem Solving - CISC 121"))
        check("related_focus_entities_count", mem.relatedFocusEntities.count >= 4)
        
        // Test 2: Selected product tab keeps related product tabs as relatedFocusEntities
        let productWorkflow = WorkflowState(
            workflowType: .shopping,
            confidence: 0.85,
            evidence: ["test"],
            uncertainty: "none",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.80,
            dominantApps: ["Firefox"],
            repeatedTerms: ["anker", "powerbank"],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "xyz"
        )
        let productBehavior = BehavioralStateRecord(
            state: .comparing,
            confidence: 0.80,
            reasoning: "test",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.75
        )
        
        ContextEpochTracker.shared.resetForTests()
        ContextEpochTracker.shared.observe(
            contextShiftDetected: false,
            shiftReason: "seed",
            earlyTopTerms: [],
            recentTopTerms: ["anker", "powerbank", "charger"],
            recentTitles: ["Anker Prime 200W"]
        )
        
        let productTabs = [
            "Anker Prime 200W",
            "Anker PowerCore 24K",
            "Baseus 65W Charger",
            "Week-2 - CISC 121",
            "Google Docs"
        ]
        
        let productMem = WorkingMemoryBuilder.build(
            workflow: productWorkflow,
            behavior: productBehavior,
            packet: packet,
            browserTabTitles: productTabs,
            selectedBrowserTabTitle: "Anker Prime 200W"
        )
        
        check("product_current_tab_is_primary", productMem.currentEntity == "Anker Prime 200W")
        check("keeps_related_product_tabs", productMem.relatedFocusEntities.contains("Anker PowerCore 24K") || productMem.relatedFocusEntities.contains("Baseus 65W Charger"))
        
        // Test 3: Unrelated tabs become backgroundEntities, not stale (if they are recent but not stale in epoch)
        // Since Google Docs is in productTabs, let's see if it's marked as stale or background
        let docsStale = ContextEpochTracker.shared.isStale(title: "Google Docs")
        if !docsStale {
            check("docs_is_background", productMem.backgroundEntities.contains("Google Docs"))
        } else {
            check("docs_is_stale", productMem.staleEntities.contains("Google Docs"))
        }
        
        let ok = failures.isEmpty
        print("[WorkingMemorySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

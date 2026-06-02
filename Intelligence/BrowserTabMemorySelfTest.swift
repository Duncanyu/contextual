import Foundation

/// Phase 20G.1 — Browser tab titles must feed WorkingMemory as candidate
/// entities (not just the current window title), while still being filtered
/// by the current epoch.
///
/// Trigger:
///   CONTEXTUAL_RUN_BROWSER_TAB_MEMORY_SELFTEST=1
@MainActor
enum BrowserTabMemorySelfTest {
	static func run() async -> Bool {
		print("[BrowserTabMemorySelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if ok { print("[BrowserTabMemorySelfTest] pass case=\(name)") }
			else  { print("[BrowserTabMemorySelfTest] fail case=\(name)"); failures.append(name) }
		}

		ContextEpochTracker.shared.resetForTests()
		ContextEpochTracker.shared.observe(
			contextShiftDetected: false,
			shiftReason: "seed",
			earlyTopTerms: [],
			recentTopTerms: ["anker", "solix", "portable", "power"],
			recentTitles: ["Anker SOLIX C200", "Anker SOLIX C2000"]
		)

		let packet = CompressedTemporalPacket(
			currentApp: "Firefox",
			recentApps: ["Firefox"],
			recentTitles: ["Anker SOLIX C200"],
			topicTerms: ["anker", "solix"],
			activityPattern: "active",
			idlePattern: "active",
			typingPattern: "light",
			pointerPattern: "steady",
			ocrHints: [],
			selectionHints: [],
			clipboardMetadata: "none",
			recentUserAccepts: [],
			recentUserIgnores: [],
			spanSeconds: 120,
			eventCount: 8,
			contextShiftDetected: false
		)

		let workflow = WorkflowState(
			workflowType: .shopping,
			confidence: 0.75,
			evidence: ["selftest"],
			uncertainty: "test",
			startedAt: Date(),
			lastUpdatedAt: Date(),
			stabilityScore: 0.6,
			dominantApps: ["Firefox"],
			repeatedTerms: ["anker", "solix"],
			recentTransitions: [],
			suggestedIntentHints: [],
			sourcePacketHash: "h"
		)
		let behavior = BehavioralStateRecord(
			state: .comparing,
			confidence: 0.7,
			reasoning: "selftest",
			startedAt: Date(),
			lastUpdatedAt: Date(),
			stabilityScore: 0.5
		)

		let tabs = [
			"Anker SOLIX C200",
			"Anker SOLIX C2000",
			"Anker 521",
			"Rental property search",
			"Google Docs"
		]
		let mem = WorkingMemoryBuilder.build(
			workflow: workflow,
			behavior: behavior,
			packet: packet,
			browserTabTitles: tabs,
			selectedBrowserTabTitle: "Anker SOLIX C200"
		)

		check("browser_tabs_produce_multiple_entities", mem.recentEntities.count >= 3)
		let joined = mem.recentEntities.joined(separator: " | ").lowercased()
		check("unrelated_tabs_filtered_by_epoch", joined.contains("docs") == false)

		let ok = failures.isEmpty
		print("[BrowserTabMemorySelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}


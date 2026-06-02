import Foundation

/// Phase 20G — integration regression test for context shift deprecation.
///
/// Covers the dogfood failure:
/// - user moves from shopping/product pages → studying/course pages
/// - context shift is detected
/// - stale shopping workflow should be released (not retained by stability)
/// - working memory should drop stale product entities
///
/// Trigger:
///   CONTEXTUAL_RUN_CONTEXT_DEPRECATION_SELFTEST=1
@MainActor
enum ContextDeprecationSelfTest {

	static func run() async -> Bool {
		print("[ContextDeprecationSelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if ok { print("[ContextDeprecationSelfTest] pass case=\(name)") }
			else  { print("[ContextDeprecationSelfTest] fail case=\(name)"); failures.append(name) }
		}

		ContextEpochTracker.shared.resetForTests()

		let now = Date()
		func ev(
			age: TimeInterval,
			title: String,
			terms: [String]
		) -> ContextEvent {
			ContextEvent(
				timestamp: now.addingTimeInterval(-age),
				type: .windowTitleChanged,
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: title,
				textHints: terms
			)
		}

		// 1) Build a medium-window with enough events to trigger shift analysis.
		let shoppingTitles = [
			"Anker SOLIX — Portable power station",
			"Anker Prime — Charger",
			"Anker SOLIX — Battery",
		]
		let courseTitles = [
			"CISC 121 — Intro to Computing",
			"onQ — Week 1",
			"CISC 121 — Problem Solving",
		]
		var events: [ContextEvent] = []
		events.append(ev(age: 820, title: shoppingTitles[0], terms: ["anker", "solix", "power", "station"]))
		events.append(ev(age: 780, title: shoppingTitles[1], terms: ["anker", "prime", "charger"]))
		events.append(ev(age: 740, title: shoppingTitles[2], terms: ["anker", "solix", "battery"]))
		events.append(ev(age: 700, title: shoppingTitles[0], terms: ["anker", "solix"]))
		events.append(ev(age: 660, title: shoppingTitles[1], terms: ["anker", "prime"]))
		events.append(ev(age: 620, title: shoppingTitles[2], terms: ["anker", "battery"]))

		events.append(ev(age: 240, title: courseTitles[0], terms: ["cisc", "intro", "computing"]))
		events.append(ev(age: 200, title: courseTitles[1], terms: ["onq", "week", "cisc"]))
		events.append(ev(age: 160, title: courseTitles[2], terms: ["cisc", "problem", "solving"]))
		events.append(ev(age: 120, title: courseTitles[0], terms: ["cisc", "computing"]))
		events.append(ev(age: 80,  title: courseTitles[1], terms: ["onq", "week"]))
		events.append(ev(age: 40,  title: courseTitles[2], terms: ["problem", "solving"]))

		let buffer = TemporalContextBuffer.build(from: events, now: now)
		let packet = TemporalContextCompressor.compress(buffer: buffer, now: now)

		check("context_shift_detected", packet.contextShiftDetected == true)

		// 2) Epoch tracker should have rolled to a new epoch with course terms.
		let epoch = ContextEpochTracker.shared.currentEpoch()
		let prev = ContextEpochTracker.shared.previousEpoch()
		check("epoch_has_course_terms", epoch.terms.contains("cisc") || epoch.terms.contains("computing"))
		check("epoch_archived_previous", prev != nil)

		// 3) Stale workflow should be released on shift even if candidate is weak.
		var stabilizer = WorkflowStabilizer(initial: WorkflowState(
			workflowType: .shopping,
			confidence: 0.78,
			evidence: ["shopping_terms=anker,solix"],
			uncertainty: "low",
			startedAt: now.addingTimeInterval(-600),
			lastUpdatedAt: now.addingTimeInterval(-10),
			stabilityScore: 0.65,
			dominantApps: ["Firefox"],
			repeatedTerms: ["anker", "solix"],
			recentTransitions: [],
			suggestedIntentHints: [],
			sourcePacketHash: "test"
		))

		let after = stabilizer.ingest(
			candidate: WorkflowState(
				workflowType: .unknown,
				confidence: 0.45,
				evidence: ["recent_title_changes=11"],
				uncertainty: "medium",
				startedAt: now,
				lastUpdatedAt: now,
				stabilityScore: 0.0,
				dominantApps: ["Firefox"],
				repeatedTerms: packet.topicTerms,
				recentTransitions: [],
				suggestedIntentHints: [],
				sourcePacketHash: "test2"
			),
			now: now,
			freshShiftSignal: packet.contextShiftDetected
		)
		check("stale_workflow_released_to_unknown", after.workflowType == .unknown)

		// 4) WorkingMemory should drop stale Anker entities in the new epoch.
		let mem = WorkingMemoryBuilder.build(
			workflow: after,
			behavior: BehavioralStateRecord(
				state: .unknown,
				confidence: 0.50,
				reasoning: "test",
				startedAt: now,
				lastUpdatedAt: now,
				stabilityScore: 0.0
			),
			packet: packet
		)
		let memJoined = mem.recentEntities.joined(separator: " ").lowercased()
		check("working_memory_drops_anker_entities", memJoined.contains("anker") == false)
		check("working_memory_keeps_course_entities", memJoined.contains("cisc") || memJoined.contains("onq"))
		check("working_memory_drops_stale_terms_from_summary", mem.inferredActivity.lowercased().contains("anker") == false)

		let ok = failures.isEmpty
		print("[ContextDeprecationSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

import Foundation

// MARK: - Environment action model

enum EnvironmentActionType: String, Sendable, Codable, Equatable, CaseIterable {
    case playFocusMedia = "play_focus_media"
    case pauseMedia = "pause_media"
    case suggestFocusPlaylist = "suggest_focus_playlist"
    case enableReduceInterruptions = "enable_reduce_interruptions"
    case launchRecentWorkspace = "launch_recent_workspace"
    case openRelatedAppSet = "open_related_app_set"
    case switchToPairedApp = "switch_to_paired_app"
    case arrangeSideBySide = "arrange_side_by_side"
    case restoreWorkspace = "restore_workspace"
    case restoreResearchTabs = "restore_research_tabs"
    case splitResearchSetup = "split_research_setup"
    case startFocusTimer = "start_focus_timer"
    case collectReferences = "collect_references"
    case copyCurrentURL = "copy_current_url"
    case rememberWorkspace = "remember_workspace"
    case openCurrentTaskPanel = "open_current_task_panel"
    case copyResultToClipboard = "copy_result_to_clipboard"
    case suppressBecauseUserIsWatching = "suppress_because_user_is_watching"
}

public struct MusicIntent: Sendable, Codable, Equatable {
    public enum Mood: String, Sendable, Codable {
        case focus
        case deepWork = "deep_work"
        case calm
        case energetic
        case instrumental
    }
	public enum Action: String, Sendable, Codable {
		case resume
		case playPlaylist = "play_playlist"
		case search
	}
    public let taskDomain: String
    public let mood: Mood
    public let query: String
    public let playlistName: String?
	public let action: Action
}

// MARK: - Playlist memory

final class PlaylistMemory: @unchecked Sendable {
    static let shared = PlaylistMemory()

    private let lock = NSLock()
    private var history: [PlaylistRecord] = []

    struct PlaylistRecord: Codable, Sendable, Equatable {
        let name: String
        let compartmentId: UUID?
        let workflow: AmbientWorkflowType
        let timeOfDay: Int // hour
        let timestamp: Date
    }

    private init() {}

    func resetForTests() {
        lock.lock()
        history.removeAll()
        lock.unlock()
    }

    func record(name: String, compartment: TaskCompartment?, workflow: AmbientWorkflowType) {
        guard name != "Library" && !name.isEmpty else { return }
        let record = PlaylistRecord(
            name: name,
            compartmentId: compartment?.id,
            workflow: workflow,
            timeOfDay: Calendar.current.component(.hour, from: Date()),
            timestamp: Date()
        )
        lock.lock()
        history.append(record)
        if history.count > 100 { history.removeFirst() }
        lock.unlock()
        print("[PlaylistMemory] recorded=\(name) workflow=\(workflow.rawValue)")
    }

    func suggest(compartment: TaskCompartment?, workflow: AmbientWorkflowType) -> String? {
        suggestWithConfidence(compartment: compartment, workflow: workflow)?.name
    }

    /// Phase 51 — suggestion with an explicit confidence so callers can refuse
    /// to act on weakly-learned playlists. Confidence scales with how many times
    /// the playlist was confirmed in the matching context.
    func suggestWithConfidence(
        compartment: TaskCompartment?,
        workflow: AmbientWorkflowType
    ) -> (name: String, confidence: Double, reason: String)? {
        lock.lock()
        defer { lock.unlock() }

        func confidence(for name: String, in records: [PlaylistRecord], base: Double) -> Double {
            let count = records.filter { $0.name == name }.count
            return min(0.95, base + Double(min(count, 5)) * 0.08)
        }

        // 1. Prefer current compartment match
        if let compId = compartment?.id {
            let compMatches = history.filter { $0.compartmentId == compId }
            if let best = mostFrequent(compMatches) {
                print("[PlaylistMemory] selected=\(best) reason=compartment_history")
                return (best, confidence(for: best, in: compMatches, base: 0.55), "compartment_history")
            }
        }

        // 2. Prefer workflow match
        let workflowMatches = history.filter { $0.workflow == workflow }
        if let best = mostFrequent(workflowMatches) {
            print("[PlaylistMemory] selected=\(best) reason=workflow_history")
            return (best, confidence(for: best, in: workflowMatches, base: 0.45), "workflow_history")
        }

        // 3. Prefer time of day match (if similar workflow family)
        let hour = Calendar.current.component(.hour, from: Date())
        let timeMatches = history.filter { abs($0.timeOfDay - hour) <= 2 }
        if let best = mostFrequent(timeMatches) {
            print("[PlaylistMemory] selected=\(best) reason=time_history")
            return (best, confidence(for: best, in: timeMatches, base: 0.3), "time_history")
        }

        return nil
    }

    private func mostFrequent(_ records: [PlaylistRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for r in records { counts[r.name, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.first?.key
    }
}

// MARK: - Passive playlist observer

final class PassivePlaylistObserver: @unchecked Sendable {
    static let shared = PassivePlaylistObserver()

    private let lock = NSLock()
    private var currentPlaylist: String?
    private var stableStart: Date?
    private var lastRecordedPlaylist: String?
    private var lastRecordedAt: Date?

    private let minStableDuration: TimeInterval = 180
    private let minRecordInterval: TimeInterval = 600

    private init() {}

    func tick(isMusicPlaying: Bool, compartment: TaskCompartment?, workflow: AmbientWorkflowType, now: Date = Date()) {
        guard isMusicPlaying else {
            lock.lock()
            currentPlaylist = nil
            stableStart = nil
            lock.unlock()
            return
        }

        guard let playlistName = MediaStateSource.currentPlaylistName() else { return }

        lock.lock()
        defer { lock.unlock() }

        if playlistName != currentPlaylist {
            currentPlaylist = playlistName
            stableStart = now
            print("[PassivePlaylistObserver] playlist_changed name=\(playlistName)")
            return
        }

        guard let started = stableStart else { return }
        let dwellSeconds = now.timeIntervalSince(started)
        guard dwellSeconds >= minStableDuration else { return }

        if let last = lastRecordedPlaylist, last == playlistName,
           let lastAt = lastRecordedAt, now.timeIntervalSince(lastAt) < minRecordInterval {
            return
        }

        lastRecordedPlaylist = playlistName
        lastRecordedAt = now
        print("[PassivePlaylistObserver] recording_passive name=\(playlistName) dwell=\(Int(dwellSeconds))s workflow=\(workflow.rawValue)")
        PlaylistMemory.shared.record(name: playlistName, compartment: compartment, workflow: workflow)
    }

    func reset() {
        lock.lock()
        currentPlaylist = nil
        stableStart = nil
        lastRecordedPlaylist = nil
        lastRecordedAt = nil
        lock.unlock()
    }
}


struct EnvironmentAction: Sendable, Codable, Equatable, Identifiable {
    let id: String
    let type: EnvironmentActionType
    let title: String
    let reasoning: String
    let executionMode: ExecutionMode
    let requiresConfirmation: Bool
    let apps: [String]
    let capabilityId: String?
    let createdAt: Date
    let musicIntent: MusicIntent?
	let compartment: TaskCompartment?
	let workflow: AmbientWorkflowType?

    init(
        id: String? = nil,
        type: EnvironmentActionType,
        title: String,
        reasoning: String,
        executionMode: ExecutionMode,
        requiresConfirmation: Bool,
        apps: [String] = [],
        capabilityId: String? = nil,
        createdAt: Date = Date(),
        musicIntent: MusicIntent? = nil,
		compartment: TaskCompartment? = nil,
		workflow: AmbientWorkflowType? = nil
    ) {
        self.id = id ?? "environment:\(type.rawValue):\(abs(title.lowercased().hashValue))"
        self.type = type
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executionMode = executionMode
        self.requiresConfirmation = requiresConfirmation
        self.apps = apps
        self.capabilityId = capabilityId ?? type.rawValue
        self.createdAt = createdAt
        self.musicIntent = musicIntent
		self.compartment = compartment
		self.workflow = workflow
    }
}

public struct EnvironmentMediaState: Sendable, Codable, Equatable {
    public enum VisualMediaKind: String, Sendable, Codable, Equatable {
        case none
        case youtubeVideo = "youtube_video"
        case movieOrShow = "movie_or_show"
        case genericVideo = "generic_video"
    }

    let isMusicPlaying: Bool
    let visualMediaKind: VisualMediaKind
    let source: String
    let detectionAvailable: Bool

    init(
        isMusicPlaying: Bool,
        visualMediaKind: VisualMediaKind,
        source: String,
        detectionAvailable: Bool = true
    ) {
        self.isMusicPlaying = isMusicPlaying
        self.visualMediaKind = visualMediaKind
        self.source = source
        self.detectionAvailable = detectionAvailable
    }

    static func derived(
        activeApp: String,
        recentApps: [String],
        currentEntity: String,
        entityType: EntityGrounding.EntityType,
        domain: DeterminerSignal.Domain,
        behavior: BehavioralState
    ) -> EnvironmentMediaState {
        let appText = ([activeApp] + recentApps).joined(separator: " ").lowercased()
        let entityText = currentEntity.lowercased()
        let musicPlaying = appText.contains("spotify")
            || appText.contains("music")
            || appText.contains("podcast")

        let visualKind: VisualMediaKind = {
            if entityType == .youtube_video || entityText.contains("youtube") { return .youtubeVideo }
            if entityType == .tv_show || entityText.contains("netflix") || entityText.contains("episode") || entityText.contains("movie") { return .movieOrShow }
            if domain == .watching || behavior == .watching || entityText.contains("video") { return .genericVideo }
            return .none
        }()

        let source: String = musicPlaying ? "recent_apps" : (visualKind == .none ? "context_no_music_app" : "visual_media_context")
        return EnvironmentMediaState(isMusicPlaying: musicPlaying, visualMediaKind: visualKind, source: source, detectionAvailable: true)
    }

    func withMusicPlayback(isPlaying: Bool, detectionAvailable: Bool, source: String) -> EnvironmentMediaState {
        EnvironmentMediaState(
            isMusicPlaying: isPlaying,
            visualMediaKind: visualMediaKind,
            source: source,
            detectionAvailable: detectionAvailable
        )
    }
}

struct EnvironmentFocusState: Sendable, Codable, Equatable {
    let isDeepWork: Bool
    let reduceInterruptionsKnownEnabled: Bool?
    let source: String

    static func derived(compartment: TaskCompartment?, workflow: WorkflowState) -> EnvironmentFocusState {
        let deepFromCompartment = compartment?.dwellState == .deep_work
        let deepFromWorkflow = workflow.durationSeconds >= 600 && workflow.stabilityScore >= 0.65
        return EnvironmentFocusState(
            isDeepWork: deepFromCompartment || deepFromWorkflow,
            reduceInterruptionsKnownEnabled: nil,
            source: deepFromCompartment ? "compartment_dwell" : (deepFromWorkflow ? "workflow_stability" : "not_deep_work")
        )
    }
}

struct EnvironmentActivityContext: Sendable, Codable, Equatable {
    let state: String
    let isActive: Bool
    let isDeepWork: Bool

    static func derived(packet: CompressedTemporalPacket, focus: EnvironmentFocusState) -> EnvironmentActivityContext {
        let active = packet.idlePattern != "long_idle"
        let state: String = {
            if !active { return "idle" }
            if packet.typingPattern == "heavy" { return "typing" }
            if packet.pointerPattern == "active" { return "interacting" }
            return packet.activityPattern
        }()
        return EnvironmentActivityContext(state: state, isActive: active, isDeepWork: focus.isDeepWork)
    }
}

struct EnvironmentUserContext: Sendable, Codable, Equatable {
    let recentAcceptedActions: [String]
    let recentDismissedActions: [String]

    static let empty = EnvironmentUserContext(recentAcceptedActions: [], recentDismissedActions: [])
}

struct EnvironmentActionInput: Sendable, Equatable {
    let activeApp: String
    let recentApps: [String]
    let taskCompartment: TaskCompartment?
    let entityType: EntityGrounding.EntityType
    let entityConfidence: Double
    let currentEntity: String
    let activeTerms: [String]
    let activityState: EnvironmentActivityContext
    let generatedAction: GeneratedActionProposal?
    let userContext: EnvironmentUserContext
    let mediaState: EnvironmentMediaState
    let focusState: EnvironmentFocusState
    let workflow: AmbientWorkflowType
    let behavior: BehavioralState
    let domain: DeterminerSignal.Domain
    let mode: DeterminerSignal.Mode
}

// MARK: - Media suitability

struct MediaSuitabilityResult: Sendable, Equatable {
    let suitable: Bool
    let reason: String
}

enum MediaSuitability {
    static func evaluate(_ input: EnvironmentActionInput) -> MediaSuitabilityResult {
        if input.mediaState.visualMediaKind == .youtubeVideo {
            return MediaSuitabilityResult(suitable: false, reason: "watching_youtube")
        }
        if input.mediaState.visualMediaKind == .movieOrShow || input.mediaState.visualMediaKind == .genericVideo {
            return MediaSuitabilityResult(suitable: false, reason: "watching_video")
        }
        if isCompetitiveOrHearingSensitiveGaming(input) {
            return MediaSuitabilityResult(suitable: false, reason: "competitive_or_hearing_sensitive_gaming")
        }
        if input.mediaState.isMusicPlaying {
            return MediaSuitabilityResult(suitable: false, reason: "music_already_playing")
        }
        if isFocusMusicWorkflow(input) {
            return MediaSuitabilityResult(suitable: true, reason: "work_context_no_music")
        }
        return MediaSuitabilityResult(suitable: false, reason: "workflow_not_music_suitable")
    }

    static func isCompetitiveOrHearingSensitiveGaming(_ input: EnvironmentActionInput) -> Bool {
        guard input.workflow == .gaming || input.domain == .gaming || input.behavior == .gaming else { return false }
        let text = ([input.currentEntity] + input.activeTerms).joined(separator: " ").lowercased()
        let hearingSensitiveTerms = ["competitive", "ranked", "fps", "shooter", "footstep", "footsteps", "counter-strike", "valorant", "fortnite", "enemy", "sound cue"]
        return hearingSensitiveTerms.contains { text.contains($0) }
    }

    private static func isFocusMusicWorkflow(_ input: EnvironmentActionInput) -> Bool {
        switch input.workflow {
        case .coding, .debugging, .studying, .researching, .writing, .reading, .browsing:
            return true
        default:
            break
        }
        switch input.domain {
        case .creative_coding, .coding, .studying, .researching, .working, .browsing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Workspace memory

final class WorkspaceMemory: @unchecked Sendable {
    static let shared = WorkspaceMemory()

    private let lock = NSLock()
    private var appsByCompartment: [String: Set<String>] = [:]

    private init() {}

    func resetForTests() {
        lock.lock()
        appsByCompartment.removeAll()
        lock.unlock()
    }

    @discardableResult
    func learn(compartment: TaskCompartment?, workflow: AmbientWorkflowType, apps: [String]) -> [String] {
        let key = memoryKey(compartment: compartment, workflow: workflow)
        let cleaned = apps.map(Self.cleanAppName).filter(Self.isLearnableApp)
        guard !cleaned.isEmpty else {
            print("[WorkspaceMemory] learned apps= reason=no_learnable_apps")
            return []
        }

        lock.lock()
        var existing = appsByCompartment[key] ?? []
        cleaned.forEach { existing.insert($0) }
        appsByCompartment[key] = existing
        let learned = existing.sorted()
        lock.unlock()

        print("[WorkspaceMemory] learned apps=\(learned.joined(separator: ",")) compartment=\(key)")
        return learned
    }

    func restoreCandidate(compartment: TaskCompartment?, workflow: AmbientWorkflowType, currentApps: [String]) -> [String] {
        let key = memoryKey(compartment: compartment, workflow: workflow)
        let current = Set(currentApps.map(Self.cleanAppName).filter(Self.isLearnableApp))

        lock.lock()
        let learned = appsByCompartment[key] ?? []
        lock.unlock()

        guard learned.count >= 2 else { return [] }
        let missing = learned.subtracting(current).sorted()
        guard !missing.isEmpty else { return [] }
        return learned.sorted()
    }

    private func memoryKey(compartment: TaskCompartment?, workflow: AmbientWorkflowType) -> String {
        if let compartment {
            return "\(compartment.workflow.rawValue)|\(compartment.label.lowercased())"
        }
        return workflow.rawValue
    }

    private static func cleanAppName(_ app: String) -> String {
        app.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLearnableApp(_ app: String) -> Bool {
        let lower = app.lowercased()
        guard app.count >= 2 else { return false }
        if lower == "unknown" || lower == "contextual" { return false }
        return true
    }
}

// MARK: - Environment action engine

enum EnvironmentActionEngine {
    static func propose(_ input: EnvironmentActionInput) async -> EnvironmentAction? {
        let playing = input.mediaState.isMusicPlaying ? "yes" : "no"
        print("[MediaContext] playing=\(playing) source=\(input.mediaState.source) detection_available=\(input.mediaState.detectionAvailable ? "yes" : "no")")
        // Phase 36 audit: arrange_side_by_side is produced only by the deterministic panel path
        // (Phase35ContextLayer → DeterministicPanelCandidate → DeterministicCapabilityActionSeed)
        // and never by the environment path. The proposal-bound target contract chain is therefore
        // enforced exclusively on the panel path; the environment path cannot bypass it.
        print("[ProposalFunnelAudit] not_generated capability=arrange_side_by_side path=environment reason=handled_by_deterministic_panel_path")

        // Part E: build general media awareness snapshot
        let awareness = MediaAwarenessClassifier.classify(
            mediaState: input.mediaState,
            activeApp: input.activeApp,
            recentApps: input.recentApps,
            domain: input.domain,
            behavior: input.behavior,
            workflow: input.workflow,
            activityState: input.activityState,
            userContext: input.userContext
        )
        awareness.log()

		// Phase 25.2 — Cheap Ambient Action Policy
		let userIsActive = input.activityState.isActive
		let stableCompartment = input.taskCompartment?.dwellState == .settled || input.taskCompartment?.dwellState == .deep_work
		let eligible = (userIsActive || stableCompartment) && input.behavior != .idle
		print("[CheapAmbientAction] eligible=\(eligible ? "yes" : "no") reason=\(userIsActive ? "user_active" : (stableCompartment ? "stable_compartment" : "idle_or_inactive"))")

        let learnedApps = WorkspaceMemory.shared.learn(
            compartment: input.taskCompartment,
            workflow: input.workflow,
            apps: [input.activeApp] + input.recentApps
        )

        let mediaSuitability = MediaSuitability.evaluate(input)
        print("[MediaSuitability] suitable=\(mediaSuitability.suitable ? "yes" : "no") reason=\(mediaSuitability.reason)")

		if !eligible {
			print("[CheapAmbientAction] selected=none reason=not_eligible")
			return nil
		}

        if input.mediaState.isMusicPlaying && (input.mediaState.visualMediaKind == .youtubeVideo || input.mediaState.visualMediaKind == .movieOrShow) {
            let action = EnvironmentAction(
                type: .pauseMedia,
                title: "Pause focus music?",
                reasoning: "Music is playing while you are watching visual media; Jarvis can silence background audio.",
                executionMode: .local_action,
                requiresConfirmation: true,
				compartment: input.taskCompartment,
				workflow: input.workflow
            )
            print("[MusicAction] suggested=pause reason=watching_visual_media")
            print("[CheapAmbientAction] selected=pause_media")
            return validated(action, input: input)
        }

        if input.mediaState.visualMediaKind == .youtubeVideo {
            print("[EnvironmentAction] proposed=suppress_because_user_is_watching reason=youtube_video")
			print("[CheapAmbientAction] selected=suppress_watching")
            return EnvironmentAction(
                type: .suppressBecauseUserIsWatching,
                title: "Suppress while you watch",
                reasoning: "The active context is a YouTube/video page, so Jarvis should stay quiet instead of adding text or music.",
                executionMode: .preview_only,
                requiresConfirmation: false,
                capabilityId: nil,
				compartment: input.taskCompartment,
				workflow: input.workflow
            )
        }

        let focusShortcutAvailable = await CapabilityExecutor.shared.isFocusShortcutAvailable()
        let shouldSuggestFocus =
            input.mediaState.visualMediaKind == .movieOrShow
            || input.behavior == .watching
            || input.workflow == .watching
            || input.domain == .watching
            || MediaSuitability.isCompetitiveOrHearingSensitiveGaming(input)
            || input.focusState.isDeepWork

        if shouldSuggestFocus {
            if focusShortcutAvailable {
                let action = EnvironmentAction(
                    type: .enableReduceInterruptions,
                    title: "Enable Work Focus?",
                    reasoning: "A local Focus shortcut is available and this context would benefit from reduced interruptions.",
                    executionMode: .local_action,
                    requiresConfirmation: true,
                    compartment: input.taskCompartment,
                    workflow: input.workflow
                )
                print("[FocusAction] suggested=yes method=shortcuts")
                print("[CheapAmbientAction] selected=enable_reduce_interruptions")
                return validated(action, input: input)
            }
            print("[FocusAction] suppressed reason=shortcut_missing")
        }

        let workspaceApps = WorkspaceMemory.shared.restoreCandidate(
            compartment: input.taskCompartment,
            workflow: input.workflow,
            currentApps: [input.activeApp] + input.recentApps
        )
		
		if workspaceApps.isEmpty {
			print("[WorkspaceAction] skipped reason=insufficient_history")
		}

        // Phase 25.4 — launch_recent_workspace (Honest: Show "Open ... apps")
        // Moved before openRelatedAppSet so it takes priority for established compartments.
        if let compartment = input.taskCompartment, compartment.dwellState != .fresh && learnedApps.count >= 3 && workspaceApps.count >= 1 {
            let action = EnvironmentAction(
                type: .launchRecentWorkspace,
                title: "Open your usual \(compartment.label) apps?",
                reasoning: "You recently worked in this compartment with a specific set of apps.",
                executionMode: .local_action,
                requiresConfirmation: true,
                apps: Array(learnedApps),
				compartment: input.taskCompartment,
				workflow: input.workflow
            )
			print("[WorkspaceAction] mode=open_apps")
            print("[WorkspaceAction] suggested=launch_recent reason=stale_apps apps_to_open=\(learnedApps.joined(separator: ","))")
            print("[CheapAmbientAction] selected=launch_recent_workspace")
            return validated(action, input: input)
        }

        if workspaceApps.count >= 2 && learnedApps.count >= 2 {
			let title = workspaceApps.count == 2
				? "Open \(workspaceApps[0]) and \(workspaceApps[1])?"
				: workspaceTitle(workflow: input.workflow, compartment: input.taskCompartment, previewOnly: false)
            let action = EnvironmentAction(
                type: .openRelatedAppSet,
                title: title,
                reasoning: "This compartment has a learned app set that is not fully present in the current context.",
                executionMode: .local_action,
                requiresConfirmation: true,
                apps: workspaceApps,
				compartment: input.taskCompartment,
				workflow: input.workflow
            )
			print("[WorkspaceAction] mode=open_apps")
            print("[WorkspaceAction] suggested=yes apps=\(workspaceApps.joined(separator: ","))")
			print("[CheapAmbientAction] selected=restore_workspace")
            return validated(action, input: input)
        }

        if mediaSuitability.suitable {
            // Part E: music usefulness gate via media awareness model
            let musicUsefulness = MusicUsefulnessEvaluator.evaluate(
                capabilityID: "play_focus_media",
                awareness: awareness,
                isMusicAlreadyPlaying: input.mediaState.isMusicPlaying,
                recentFeedbackCooldownActive: input.userContext.recentDismissedActions.contains(where: { $0.lowercased().contains("play") || $0.lowercased().contains("music") }),
                hasHigherPriorityTaskAction: false
            )
            guard musicUsefulness.eligible else {
                print("[EnvironmentAction] proposed=none reason=music_usefulness_gate reason=\(musicUsefulness.reason)")
                print("[CheapAmbientAction] selected=none reason=music_not_useful")
                return nil
            }

			let mood: MusicIntent.Mood = (input.focusState.isDeepWork || input.mode == .building) ? .deepWork : .focus
			// Phase 51 — learned playlist is only used when confidence is high.
			// A weakly-learned playlist must not silently drive what gets played.
			let learnedSuggestion = PlaylistMemory.shared.suggestWithConfidence(compartment: input.taskCompartment, workflow: input.workflow)
			let learnedPlaylist: String?
			if let suggestion = learnedSuggestion {
				if suggestion.confidence >= 0.6 {
					learnedPlaylist = suggestion.name
				} else {
					print("[MusicSuppression] reason=low_confidence detail=learned_playlist_confidence_\(String(format: "%.2f", suggestion.confidence))")
					learnedPlaylist = nil
				}
			} else {
				learnedPlaylist = nil
			}
			let query = learnedPlaylist ?? musicQuery(workflow: input.workflow, domain: input.domain, mood: mood)

			let canPlayDirectly: Bool
			if learnedPlaylist != nil {
				canPlayDirectly = true
			} else {
				canPlayDirectly = await MusicExecutor.checkLocalPlaylist(query: query)
			}

			let actionType: MusicIntent.Action = {
				if learnedPlaylist != nil { return .playPlaylist }
				return .resume
			}()
			print("[MusicTarget] app=Music playlist=\(learnedPlaylist.map { "\"\($0)\"" } ?? "none") confidence=\(learnedSuggestion.map { String(format: "%.2f", $0.confidence) } ?? "0.00") learned=\(learnedPlaylist != nil ? "yes" : "no")")

			let intent = MusicIntent(
				taskDomain: input.domain.rawValue,
				mood: mood,
				query: query,
				playlistName: learnedPlaylist,
				action: actionType
			)
			print("[MusicIntent] domain=\(intent.taskDomain) mood=\(intent.mood.rawValue) query=\"\(intent.query)\" action=\(intent.action.rawValue)")

			let title = mediaTitle(
				workflow: input.workflow,
				domain: input.domain,
				mood: mood,
				canPlayDirectly: canPlayDirectly,
				learnedPlaylist: learnedPlaylist,
				compartmentLabel: input.taskCompartment?.label
			)
			
            let action = EnvironmentAction(
                type: .playFocusMedia,
                title: title,
                reasoning: "No music is detected and the current task is compatible with background focus audio.",
                executionMode: .local_action,
                requiresConfirmation: true,
                apps: ["Music"],
				musicIntent: intent,
				compartment: input.taskCompartment,
				workflow: input.workflow
            )
            print("[EnvironmentAction] type=\(action.type.rawValue)")
			print("[CheapAmbientAction] selected=play_focus_media")
            return validated(action, input: input)
        }

        print("[EnvironmentAction] proposed=none reason=\(mediaSuitability.reason)")
		print("[CheapAmbientAction] selected=none reason=no_suitable_action")
        return nil
    }

    private static func validated(_ action: EnvironmentAction, input: EnvironmentActionInput) -> EnvironmentAction? {
        guard EnvironmentActionValidation.validate(action, input: input) else { return nil }
        print("[EnvironmentAction] proposed=\(action.type.rawValue) title=\(action.title)")
        return action
    }

    private static func mediaTitle(
        workflow: AmbientWorkflowType,
        domain: DeterminerSignal.Domain,
        mood: MusicIntent.Mood,
        canPlayDirectly: Bool,
        learnedPlaylist: String?,
        compartmentLabel: String?,
        firstLocalPlaylistName: String? = nil
    ) -> String {
        if let p = learnedPlaylist {
            if let label = compartmentLabel {
                return "Play your \(p) playlist while you work on \(label)?"
            }
            return "Play your \(p) playlist?"
        }

        if canPlayDirectly {
            return "Resume your music?"
        }
        if let name = firstLocalPlaylistName {
            return "Play \(name)?"
        }
        return "Play a local playlist?"
    }

    private static func musicQuery(workflow: AmbientWorkflowType, domain: DeterminerSignal.Domain, mood: MusicIntent.Mood) -> String {
        let base: String = {
            if workflow == .coding || domain == .coding || domain == .creative_coding { return "instrumental coding focus" }
            if workflow == .studying || domain == .studying { return "study focus instrumental" }
            if workflow == .researching || domain == .researching { return "deep focus instrumental" }
            if domain == .creative_coding { return "creative coding focus music" }
            return "focus instrumental"
        }()
        return mood == .deepWork ? "deep work \(base)" : base
    }

    private static func workspaceTitle(workflow: AmbientWorkflowType, compartment: TaskCompartment?, previewOnly: Bool) -> String {
        let label = compartment?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = previewOnly ? "Preview" : "Open"
        
        if workflow == .coding || workflow == .debugging { return "\(prefix) your coding setup?" }
        if workflow == .studying { return "\(prefix) your usual study workspace?" }
        if label.lowercased().contains("scratch") { return "\(prefix) your usual Scratch apps?" }
        
        return "\(prefix) your usual workspace?"
    }
}

enum EnvironmentActionValidation {
    static func validate(_ action: EnvironmentAction, input: EnvironmentActionInput) -> Bool {
        let dismissed = Set(input.userContext.recentDismissedActions.map { $0.lowercased() })
        let accepted: Bool
        let reason: String

        if dismissed.contains(action.type.rawValue.lowercased()) || dismissed.contains(action.title.lowercased()) {
            accepted = false
            reason = "recently_dismissed"
        } else if (action.type == .enableReduceInterruptions || action.type == .openRelatedAppSet) && !action.requiresConfirmation {
            accepted = false
            reason = "missing_confirmation"
        } else if action.title.isEmpty {
            accepted = false
            reason = "empty_title"
        } else {
            accepted = true
            reason = "ok"
        }

        print("[EnvironmentActionValidation] accepted=\(accepted ? "yes" : "no") reason=\(reason)")
        return accepted
    }
}

// MARK: - Route selection

enum ActionRouteKind: String, Sendable, Codable, Equatable {
    case cognitive
    case environment
    case hybrid
    case suppress
}

struct ActionRouteDecision: Sendable, Equatable {
    let selectedRoute: ActionRouteKind
    let generatedAction: GeneratedActionProposal?
    let environmentAction: EnvironmentAction?
    let reason: String
}

extension ActionRouter {
    static func selectRoute(
        generatedAction: GeneratedActionProposal?,
        environmentAction: EnvironmentAction?
    ) -> ActionRouteDecision {
        let route: ActionRouteDecision
        if let environmentAction, environmentAction.type == .suppressBecauseUserIsWatching {
            route = ActionRouteDecision(selectedRoute: .suppress, generatedAction: generatedAction, environmentAction: environmentAction, reason: "watching_context")
        } else if let environmentAction, environmentAction.type == .enableReduceInterruptions {
            route = ActionRouteDecision(selectedRoute: .environment, generatedAction: generatedAction, environmentAction: environmentAction, reason: "environment_action_supersedes_text")
        } else if let environmentAction, generatedAction != nil {
            route = ActionRouteDecision(selectedRoute: .hybrid, generatedAction: generatedAction, environmentAction: environmentAction, reason: "generated_action_plus_environment_support")
        } else if let environmentAction {
            // Task A: Surface environment action when cognitive is unavailable or suppressed.
            route = ActionRouteDecision(selectedRoute: .environment, generatedAction: nil, environmentAction: environmentAction, reason: "environment_action_available")
        } else if let generatedAction {
            route = ActionRouteDecision(selectedRoute: .cognitive, generatedAction: generatedAction, environmentAction: nil, reason: "no_environment_action")
        } else {
            route = ActionRouteDecision(selectedRoute: .suppress, generatedAction: nil, environmentAction: nil, reason: "no_action")
        }

        print("[ActionRouter] selected_route=\(route.selectedRoute.rawValue) reason=\(route.reason)")
        return route
    }
}

enum EnvironmentActionCapabilityAdapter {
    static func capability(from action: EnvironmentAction) -> CognitiveCapability {
        CognitiveCapability(
            id: action.capabilityId ?? action.type.rawValue,
            label: action.title,
            inputRequirements: [],
            outputType: "system_action",
            evidenceThreshold: "contextual_environment",
            privacyLevel: .local,
            riskLevel: .light_action,
            requiresConfirmation: action.requiresConfirmation,
            executionMode: action.executionMode
        )
    }
}

@MainActor
enum EnvironmentActionExecutor {
    static func previewOrExecute(_ action: EnvironmentAction, supplementalContext: [String: Any] = [:]) async -> CapabilityExecutionStatus {
        let sourceSurface = (supplementalContext["source_surface"] as? String) ?? "unknown"
        print("[EnvironmentActionExecution] started id=\(action.type.rawValue)")
        print("[CapabilityExecution] started id=\(action.type.rawValue) source_surface=\(sourceSurface)")
        print("[CapabilityExecution] mode=\(action.executionMode.rawValue) id=\(action.type.rawValue)")
        if action.executionMode == .preview_only {
            print("[CapabilityExecution] status=preview_generated id=\(action.type.rawValue)")
            print("[CapabilityExecution] completed status=success id=\(action.type.rawValue) reason=preview_only")
            return .previewGenerated
        }

        guard let capabilityId = action.capabilityId,
              let capability = CognitiveCapabilityRegistry.shared.get(capabilityId) else {
            print("[CapabilityExecution] status=unavailable id=\(action.type.rawValue) reason=capability_not_registered")
            print("[CapabilityExecution] completed status=unavailable id=\(action.type.rawValue)")
            return .unavailable
        }

        // Phase 36: proposal-bound layout capabilities must carry a target contract.
        // The env path never produces them today, but if something ever did, block to prevent
        // a generic-fallback substitution from running unproven.
        let proposalBoundCapabilities: Set<String> = ["arrange_side_by_side", "switch_to_paired_app", "split_research_setup"]
        if proposalBoundCapabilities.contains(capabilityId)
           && supplementalContext["targetContract"] == nil {
            print("[CapabilityExecution] status=unavailable id=\(capabilityId) reason=env_path_missing_target_contract")
            print("[CapabilityExecution] completed status=unavailable id=\(capabilityId) reason=target_contract_failed")
            print("[ActionPreflight] capability=\(capabilityId) path=environment status=blocked reason=no_contract_on_env_path")
            return .unavailable
        }
        AppState.lastAssistantInitiatedAppLaunch = action.apps.first
        AppState.lastAssistantInitiatedAction = action.type.rawValue
		AppState.lastAssistantInitiatedAt = Date()

        var context: [String: Any] = [
            "apps": action.apps,
            "confirmation_satisfied": true,
            "musicIntent": action.musicIntent as Any,
			"compartment": action.compartment as Any,
			"workflow": action.workflow as Any
        ]
        for (key, value) in supplementalContext {
            context[key] = value
        }
        return await CapabilityExecutor.shared.execute(capability: capability, context: context)
    }
}

// MARK: - Self-tests

@MainActor
enum EnvironmentActionSelfTest {
    static func run() async -> Bool {
        print("[EnvironmentActionSelfTest] starting")
        WorkspaceMemory.shared.resetForTests()
        CapabilityExecutor.testHooks = .init()
        defer { CapabilityExecutor.testHooks = .init() }
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition { print("[EnvironmentActionSelfTest] pass case=\(name)") }
            else { print("[EnvironmentActionSelfTest] fail case=\(name)"); failures.append(name) }
        }

        let coding = makeInput(workflow: .coding, behavior: .coding, domain: .coding, entityType: .code_project, terms: ["swift", "contextual"], media: noMusic())
        check("coding_no_music_focus_media", await EnvironmentActionEngine.propose(coding)?.type == .playFocusMedia)

        let study = makeInput(workflow: .studying, behavior: .learning, domain: .studying, entityType: .course_material, terms: ["recursion", "quiz"], media: noMusic())
        check("studying_no_music_study_music", await EnvironmentActionEngine.propose(study)?.type == .playFocusMedia)

        let youtube = makeInput(workflow: .watching, behavior: .watching, domain: .watching, entityType: .youtube_video, entity: "YouTube lecture", media: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .youtubeVideo, source: "test"))
        let youtubeAction = await EnvironmentActionEngine.propose(youtube)
        check("youtube_suppresses_music", youtubeAction?.type == .suppressBecauseUserIsWatching)

        CapabilityExecutor.testHooks.focusShortcutAvailable = { true }
        let movie = makeInput(workflow: .watching, behavior: .watching, domain: .watching, entityType: .tv_show, entity: "Movie Night Episode", media: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .movieOrShow, source: "test"))
        let movieAction = await EnvironmentActionEngine.propose(movie)
        let movieRoute = ActionRouter.selectRoute(generatedAction: movie.generatedAction, environmentAction: movieAction)
        check("movie_reduce_interruptions_not_text", movieAction?.type == .enableReduceInterruptions && movieRoute.selectedRoute == .environment)

        let game = makeInput(workflow: .gaming, behavior: .gaming, domain: .gaming, entityType: .game, entity: "Ranked FPS shooter", terms: ["ranked", "footsteps"], media: noMusic())
        let gameAction = await EnvironmentActionEngine.propose(game)
        check("competitive_game_dnd_no_music", gameAction?.type == .enableReduceInterruptions)

        CapabilityExecutor.testHooks.runFocusShortcut = {
            CapabilityExecutor.LocalActionOutcome(status: .success, verificationStatus: "success", reason: "shortcut_ran")
        }
        let focusRuns = await EnvironmentActionExecutor.previewOrExecute(EnvironmentAction(type: .enableReduceInterruptions, title: "Turn on Reduce Interruptions?", reasoning: "self-test", executionMode: .local_action, requiresConfirmation: true))
        check("focus_shortcut_runs_successfully", focusRuns == .success)

        CapabilityExecutor.testHooks.focusShortcutAvailable = { false }
        CapabilityExecutor.testHooks.runFocusShortcut = nil
        let deepWorkInput = makeInput(workflow: .coding, behavior: .coding, domain: .coding, entityType: .code_project, terms: ["swift"], media: noMusic(), deepWork: true)
        let hiddenFocusAction = await EnvironmentActionEngine.propose(deepWorkInput)
        check("focus_action_hidden_when_shortcut_missing", hiddenFocusAction?.type != .enableReduceInterruptions)

        let timerUnavailable = await EnvironmentActionExecutor.previewOrExecute(EnvironmentAction(type: .startFocusTimer, title: "Start focus timer?", reasoning: "self-test", executionMode: .local_action, requiresConfirmation: true))
        check("unavailable_timer_not_success", timerUnavailable == .unavailable)

        let noEnv = makeInput(workflow: .shopping, behavior: .shopping, domain: .shopping, entityType: .product, media: noMusic())
        let noEnvAction = await EnvironmentActionEngine.propose(noEnv)
        let noEnvRoute = ActionRouter.selectRoute(generatedAction: noEnv.generatedAction, environmentAction: noEnvAction)
        check("cognitive_still_works_when_environment_not_useful", noEnvAction == nil && noEnvRoute.selectedRoute == .cognitive)

        let noSearchMusic = await EnvironmentActionEngine.propose(coding)
        check("music_intent_never_search", noSearchMusic?.musicIntent?.action != .search)

        let fallbackPlan = MusicExecutor.executionPlanForTests(
            intent: MusicIntent(taskDomain: "coding", mood: .focus, query: "coding focus", playlistName: nil, action: .resume),
            localPlaylistMatchExists: false,
            hasFirstLocalPlaylist: true
        )
        check("music_falls_back_to_first_local_playlist", fallbackPlan == "resume_then_first_local_playlist")

        let requestedPlaylistPlan = MusicExecutor.executionPlanForTests(
            intent: MusicIntent(taskDomain: "coding", mood: .focus, query: "coding focus", playlistName: "deep work", action: .playPlaylist),
            localPlaylistMatchExists: false,
            hasFirstLocalPlaylist: true
        )
        check("requested_playlist_never_becomes_search", requestedPlaylistPlan == "play_first_local_playlist")

        CapabilityExecutor.testHooks.openAppPair = { apps in
            CapabilityExecutor.LocalActionOutcome(status: apps.count >= 2 ? .success : .blocked, verificationStatus: apps.count >= 2 ? "success" : "failed", reason: apps.count >= 2 ? "opened_app_pair" : "no_apps")
        }
        let openPair = await EnvironmentActionExecutor.previewOrExecute(
            EnvironmentAction(type: .openRelatedAppSet, title: "Open Preview and Firefox?", reasoning: "self-test", executionMode: .local_action, requiresConfirmation: true, apps: ["Preview", "Firefox"])
        )
        check("open_common_app_pair_launches_apps", openPair == .success)

        let ok = failures.isEmpty
        print("[EnvironmentActionSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

enum MediaSuitabilitySelfTest {
    static func run() async -> Bool {
        print("[MediaSuitabilitySelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition { print("[MediaSuitabilitySelfTest] pass case=\(name)") }
            else { print("[MediaSuitabilitySelfTest] fail case=\(name)"); failures.append(name) }
        }

        let coding = makeInput(workflow: .coding, behavior: .coding, domain: .coding, entityType: .code_project, media: noMusic())
        check("coding_suitable", MediaSuitability.evaluate(coding).suitable)

        let youtube = makeInput(workflow: .watching, behavior: .watching, domain: .watching, entityType: .youtube_video, media: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .youtubeVideo, source: "test"))
        check("youtube_not_suitable", !MediaSuitability.evaluate(youtube).suitable)

        let gaming = makeInput(workflow: .gaming, behavior: .gaming, domain: .gaming, entityType: .game, entity: "Competitive shooter", terms: ["footsteps"], media: noMusic())
        let gamingResult = MediaSuitability.evaluate(gaming)
        check("competitive_game_not_suitable", !gamingResult.suitable && gamingResult.reason == "competitive_or_hearing_sensitive_gaming")

        let ok = failures.isEmpty
        print("[MediaSuitabilitySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

enum WorkspaceMemorySelfTest {
    static func run() async -> Bool {
        print("[WorkspaceMemorySelfTest] starting")
        WorkspaceMemory.shared.resetForTests()
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition { print("[WorkspaceMemorySelfTest] pass case=\(name)") }
            else { print("[WorkspaceMemorySelfTest] fail case=\(name)"); failures.append(name) }
        }

        let comp = TaskCompartment(workflow: .coding, label: "Contextual project", dominantTerms: ["contextual"], entities: ["Contextual"], browserTabs: [], confidence: 0.9)
        _ = WorkspaceMemory.shared.learn(compartment: comp, workflow: .coding, apps: ["Xcode", "Firefox", "Terminal"])
        let input = makeInput(workflow: .coding, behavior: .coding, domain: .coding, entityType: .code_project, compartment: comp, recentApps: ["Xcode"], media: noMusic())
        let action = await EnvironmentActionEngine.propose(input)
        check("coding_project_suggests_restore_workspace", action?.type == .openRelatedAppSet && (action?.apps.contains("Terminal") ?? false))

        let ok = failures.isEmpty
        print("[WorkspaceMemorySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

enum ActionRouterSelfTest {
    static func run() -> Bool {
        print("[ActionRouterSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition { print("[ActionRouterSelfTest] pass case=\(name)") }
            else { print("[ActionRouterSelfTest] fail case=\(name)"); failures.append(name) }
        }

        let generated = testGeneratedAction()
        let media = EnvironmentAction(type: .playFocusMedia, title: "Play focus music?", reasoning: "test", executionMode: .local_action, requiresConfirmation: true)
        check("coding_env_hybrid", ActionRouter.selectRoute(generatedAction: generated, environmentAction: media).selectedRoute == .hybrid)

        let focus = EnvironmentAction(type: .enableReduceInterruptions, title: "Turn on Reduce Interruptions?", reasoning: "test", executionMode: .local_action, requiresConfirmation: true)
        check("watching_environment_only", ActionRouter.selectRoute(generatedAction: generated, environmentAction: focus).selectedRoute == .environment)

        let suppress = EnvironmentAction(type: .suppressBecauseUserIsWatching, title: "Suppress while you watch", reasoning: "test", executionMode: .preview_only, requiresConfirmation: false)
        check("youtube_suppress", ActionRouter.selectRoute(generatedAction: generated, environmentAction: suppress).selectedRoute == .suppress)

        check("cognitive_fallback", ActionRouter.selectRoute(generatedAction: generated, environmentAction: nil).selectedRoute == .cognitive)

        let ok = failures.isEmpty
        print("[ActionRouterSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

// MARK: - Self-test fixtures

private func noMusic() -> EnvironmentMediaState {
    EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test")
}

private func testGeneratedAction() -> GeneratedActionProposal {
    GeneratedActionProposal(
        id: "generated:test",
        title: "Investigate collision bug",
        description: "Synthetic generated action for environment routing tests.",
        reasoning: "self_test",
        confidence: 0.82,
        workflow: .debugging,
        requiredContext: [.textSnippet],
        primitives: [.answerFromContext]
    )
}

private func makeInput(
    workflow: AmbientWorkflowType,
    behavior: BehavioralState,
    domain: DeterminerSignal.Domain,
    entityType: EntityGrounding.EntityType,
    entity: String = "Contextual project",
    terms: [String] = ["contextual", "swift"],
    compartment: TaskCompartment? = nil,
    recentApps: [String] = ["Xcode"],
    media: EnvironmentMediaState
) -> EnvironmentActionInput {
    EnvironmentActionInput(
        activeApp: recentApps.first ?? "Xcode",
        recentApps: recentApps,
        taskCompartment: compartment,
        entityType: entityType,
        entityConfidence: 0.82,
        currentEntity: entity,
        activeTerms: terms,
        activityState: EnvironmentActivityContext(state: "typing", isActive: true, isDeepWork: false),
        generatedAction: testGeneratedAction(),
        userContext: .empty,
        mediaState: media,
        focusState: EnvironmentFocusState(isDeepWork: false, reduceInterruptionsKnownEnabled: nil, source: "test"),
        workflow: workflow,
        behavior: behavior,
        domain: domain,
        mode: .building
    )
}

import Foundation
import AppKit

public enum MusicExecutor {
    static func executionPlanForTests(
        intent: MusicIntent?,
        localPlaylistMatchExists: Bool,
        hasFirstLocalPlaylist: Bool
    ) -> String {
        // Phase 51 — no random "first local playlist" fallback. The executor only
        // plays what the intent names (or plain resume). Anything else fails honestly.
        let action = intent?.action ?? .resume
        switch action {
        case .playPlaylist, .search:
            if localPlaylistMatchExists { return "play_requested_playlist" }
            return "unavailable"
        case .resume:
            return "resume_only"
        }
    }

    /// Phase 51 — Spotify scripting is only attempted when Spotify is actually
    /// installed; otherwise osascript fails at terminology resolution
    /// ("variable playpause is not defined").
    static var isSpotifyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    @MainActor
    public static func play(intent: MusicIntent? = nil) async -> (success: Bool, status: CapabilityExecutionStatus, reason: String, playlistName: String?) {
        print("[MusicExecutor] started")
		let action = intent?.action ?? .resume
		print("[MusicExecutor] action=\(action.rawValue)")
        print("[MusicExecutor] fallback_search=no")

		if action == .resume {
            if let resumed = await tryResumeAnyPlayer() {
                print("[MusicAction] action=resume status=success reason=\(resumed.reason)")
                return resumed
            }
            // Phase 51 — resume either resumes or fails visibly. It must never
            // silently start a playlist the user did not ask for.
            print("[MusicAction] action=resume status=failed reason=no_player_resumed")
            print("[MusicSuppression] reason=low_confidence detail=resume_failed_no_named_playlist")
			return (false, .unavailable, "resume_failed_no_player", nil)
		}

        guard let requestedQuery = intent?.playlistName ?? intent?.query else {
            print("[MusicExecutor] error=no_query_or_playlist_in_intent fallback_search=no")
            print("[MusicAction] action=play status=failed reason=no_query_in_intent")
            return (false, .unavailable, "no_query_in_intent", nil)
        }
        let query = requestedQuery
        let learned = intent?.playlistName != nil
        print("[MusicExecutor] intended_query=\"\(query)\"")
        print("[MusicTarget] app=Music playlist=\"\(query)\" confidence=\(learned ? "learned" : "heuristic") learned=\(learned ? "yes" : "no")")
        if let p = intent?.playlistName { print("[MusicExecutor] playlist_name=\(p)") }

        let directPlay = await playLocalPlaylist(query: query, reason: "requested_playlist")
        if directPlay.success {
            print("[MusicAction] action=play status=success reason=requested_playlist")
            return directPlay
        }

        print("[MusicAction] action=play status=failed reason=requested_playlist_not_found")
        return (false, .unavailable, "requested_playlist_not_found", nil)
    }

	@MainActor
	public static func checkLocalPlaylist(query: String) async -> Bool {
		let script = "tell application \"Music\" to count (every playlist whose name contains \"\(query)\")"
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let countStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            return (Int(countStr) ?? 0) > 0
        } catch {
            return false
        }
	}
    
    @MainActor
	public static func pause() async -> (success: Bool, reason: String) {
        print("[MusicExecutor] started")

        let musicScript = "tell application \"Music\" to pause"
        let (mSuccess, _, _, _) = await runAppleScript(musicScript, backend: "music")

        var sSuccess = false
        if isSpotifyInstalled {
            let spotifyScript = "tell application \"Spotify\" to pause"
            (sSuccess, _, _, _) = await runAppleScript(spotifyScript, backend: "spotify")
        } else {
            print("[MusicExecutor] backend=spotify skipped reason=not_installed")
        }

        let success = mSuccess || sSuccess
        print("[MusicAction] action=pause status=\(success ? "success" : "failed") reason=\(success ? "player_paused" : "no_player_responded")")
        if success {
            return (true, "music_paused")
        }
        return (false, "no_player_responded")
	}

    @MainActor
    private static func tryResumeAnyPlayer() async -> (success: Bool, status: CapabilityExecutionStatus, reason: String, playlistName: String?)? {
        let resumeScript = """
            tell application "Music"
                play
                return player state as string
            end tell
        """
        let (musicSuccess, musicOut, _, _) = await runAppleScript(resumeScript, backend: "music")
        if musicSuccess && musicOut.lowercased().contains("playing") {
            return (true, .success, "music_resumed", nil)
        }

        // Phase 51 — `play` resumes; `playpause` would TOGGLE (pausing an already-
        // playing player). Spotify is only scripted when actually installed.
        guard isSpotifyInstalled else {
            print("[MusicExecutor] backend=spotify skipped reason=not_installed")
            return nil
        }
        let spotifyResume = """
            tell application "Spotify"
                play
                return player state as string
            end tell
        """
        let (spotifySuccess, spotifyOut, _, _) = await runAppleScript(spotifyResume, backend: "spotify")
        if spotifySuccess && spotifyOut.lowercased().contains("playing") {
            return (true, .success, "spotify_resumed", nil)
        }
        return nil
    }

    @MainActor
    private static func playLocalPlaylist(query: String, reason: String) async -> (success: Bool, status: CapabilityExecutionStatus, reason: String, playlistName: String?) {
        let escaped = query.replacingOccurrences(of: "\"", with: "\\\"")
        let musicScript = """
            tell application "Music"
                set playlistName to ""
                try
                    set matches to (every playlist whose name contains "\(escaped)")
                    if (count of matches) > 0 then
                        set p to item 1 of matches
                        set playlistName to name of p
                        play p
                    end if
                end try
                delay 1.0
                return (player state as string) & "|" & playlistName
            end tell
        """

        let (_, output, _, _) = await runAppleScript(musicScript, backend: "music")
        let components = output.components(separatedBy: "|")
        let playerState = components.first ?? "unknown"
        let foundName = components.count > 1 ? components[1] : ""

        print("[MusicExecutor] actual_query=\"\(query)\"")
        let localFound = !foundName.isEmpty && foundName != "Library"
        print("[MusicExecutor] local_playlist_found=\(localFound ? "yes" : "no") name=\"\(foundName)\"")

        if playerState.lowercased().contains("playing") && localFound {
            print("[MusicExecutor] player_state_after=\(playerState)")
            print("[MusicExecutor] playlist_name=\(foundName)")
            return (true, .success, reason, foundName)
        }
        return (false, .unavailable, "playlist_not_found", nil)
    }

    @MainActor
    private static func firstLocalPlaylistName() async -> String? {
        let script = """
            tell application "Music"
                try
                    set userPlaylists to (every user playlist whose special kind is none)
                    if (count of userPlaylists) > 0 then
                        return name of item 1 of userPlaylists
                    end if
                end try
                return ""
            end tell
        """
        let (success, stdout, _, _) = await runAppleScript(script, backend: "music")
        let name = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard success, !name.isEmpty, name != "Library" else { return nil }
        return name
    }
    
    private static func runAppleScript(_ script: String, backend: String) async -> (success: Bool, stdout: String, stderr: String, exitCode: Int32) {
        print("[MusicExecutor] backend=\(backend)")
        print("[MusicExecutor] command=osascript -e '\(script)'")
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            
            let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let exitCode = task.terminationStatus
            
            print("[MusicExecutor] exit_code=\(exitCode)")
            if !stdout.isEmpty { print("[MusicExecutor] stdout=\(stdout)") }
            if !stderr.isEmpty { print("[MusicExecutor] stderr=\(stderr)") }
            
            return (exitCode == 0, stdout, stderr, exitCode)
        } catch {
            print("[MusicExecutor] error=\(error.localizedDescription)")
            return (false, "", error.localizedDescription, -1)
        }
    }
}

// MARK: - Phase 25.9 Self Test

@MainActor
public enum Phase25_9SelfTest {
    public static func run() async -> Bool {
        print("[Phase25_9SelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase25_9SelfTest] pass case=\(name)") }
            else { print("[Phase25_9SelfTest] fail case=\(name)"); failures.append(name) }
        }

        // 1. reduce_interruptions_unwired_does_not_claim_toggle
        print("[Phase25_9SelfTest] case=reduce_interruptions_honesty")
        // Simulate deep work
        let deepWorkInput = makeInput(workflow: .coding, behavior: .coding, domain: .coding, entityType: .code_project, terms: ["swift"], media: noMusic(), deepWork: true)
        CapabilityExecutor.testHooks.focusShortcutAvailable = { false }
        let focusAction = await EnvironmentActionEngine.propose(deepWorkInput)
        check("focus_hidden_when_shortcut_missing", focusAction?.type != .enableReduceInterruptions)
        CapabilityExecutor.testHooks.focusShortcutAvailable = nil

        // 2 & 3. assistant_opened_music_ignored_by_compartment_tracker
        // (Verified by ContextEventProducer logic & logs)

        // 4. gemini_inherits_scratch_compartment
        print("[Phase25_9SelfTest] case=gemini_inherits_scratch_compartment")
        let tracker = TaskCompartmentTracker.shared
        tracker.resetForTests()
        let scratchComp = TaskCompartment(id: UUID(), workflow: .coding, label: "Advanced Scratch", dominantTerms: ["scratch"], entities: ["Scratch"], browserTabs: [], firstSeen: Date(), lastSeen: Date(), confidence: 0.9, activeScore: 1.0, staleScore: 0.0, firstActivatedAt: Date())
        tracker.registerForTesting(scratchComp)
        tracker.setCompartments([scratchComp], activeId: scratchComp.id)
        
        let geminiInherited = tracker.findBestCompartment(
            workflow: .unknown,
            title: "Gemini",
            tabs: ["Gemini"],
            cleanTokens: ["gemini"]
        )
        check("gemini_inherits_scratch", geminiInherited?.id == scratchComp.id)

        // 6. reject_review_dexter_in_dexter
        print("[Phase25_9SelfTest] case=reject_junk_titles")
        check("reject_duplicate", !JarvisSuggestionValidator.validate(title: "Review dexter in Dexter", subtitle: "test"))
        check("reject_hallucination", !JarvisSuggestionValidator.validate(title: "Review first, realism, shooter before testing", subtitle: "test"))

        // 8. workspace_action_logs_skipped_or_proposed
        print("[Phase25_9SelfTest] case=workspace_logs")
        let emptyWSInput = makeInput(workflow: .shopping, behavior: .shopping, domain: .shopping, entityType: .product, media: noMusic())
        _ = await EnvironmentActionEngine.propose(emptyWSInput)
        // Check logs for [WorkspaceAction] skipped

        let ok = failures.isEmpty
        print("[Phase25_9SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

private func makeInput(
    workflow: AmbientWorkflowType,
    behavior: BehavioralState,
    domain: DeterminerSignal.Domain,
    entityType: EntityGrounding.EntityType,
    entity: String = "Contextual project",
    terms: [String] = ["contextual", "swift"],
    compartment: TaskCompartment? = nil,
    recentApps: [String] = ["Xcode"],
    media: EnvironmentMediaState,
	deepWork: Bool = false
) -> EnvironmentActionInput {
    EnvironmentActionInput(
        activeApp: recentApps.first ?? "Xcode",
        recentApps: recentApps,
        taskCompartment: compartment,
        entityType: entityType,
        entityConfidence: 0.82,
        currentEntity: entity,
        activeTerms: terms,
        activityState: EnvironmentActivityContext(state: "typing", isActive: true, isDeepWork: deepWork),
        generatedAction: nil,
        userContext: .empty,
        mediaState: media,
        focusState: EnvironmentFocusState(isDeepWork: deepWork, reduceInterruptionsKnownEnabled: nil, source: "test"),
        workflow: workflow,
        behavior: behavior,
        domain: domain,
        mode: .building
    )
}

// MARK: - PassivePlaylistObserver self-test

enum PassivePlaylistObserverSelfTest {
    static func run() -> Bool {
        print("[PassivePlaylistObserverSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("[PassivePlaylistObserverSelfTest] pass case=\(name)")
            } else {
                print("[PassivePlaylistObserverSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        let observer = PassivePlaylistObserver.shared
        observer.reset()
        PlaylistMemory.shared.resetForTests()

        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // No music playing → no recording
        observer.tick(isMusicPlaying: false, compartment: nil, workflow: .coding, now: t0)
        check("no_music_no_record", PlaylistMemory.shared.suggest(compartment: nil, workflow: .coding) == nil)

        // Music playing but MediaStateSource.currentPlaylistName() returns nil in test
        // (no Music.app actually running) → no recording
        observer.reset()
        PlaylistMemory.shared.resetForTests()
        observer.tick(isMusicPlaying: true, compartment: nil, workflow: .coding, now: t0)
        check("no_playlist_name_no_record", PlaylistMemory.shared.suggest(compartment: nil, workflow: .coding) == nil)

        let ok = failures.isEmpty
        print("[PassivePlaylistObserverSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

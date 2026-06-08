import Foundation

// MARK: - Media Source Type

enum MediaSourceType: String, Sendable, Codable {
    case browserVideo = "browser_video"
    case nativeVideoApp = "native_video_app"
    case musicApp = "music_app"
    case unknown
}

// MARK: - Media Awareness Snapshot

struct MediaAwarenessSnapshot: Sendable {
    let foregroundMediaPresent: Bool
    let foregroundMediaConfidence: Double
    let mediaSourceType: MediaSourceType
    let foregroundMediaPlaybackState: String   // "playing", "paused", "unknown"
    let backgroundMusicState: String           // "playing", "paused", "stopped", "unknown"
    let audioConflictLikelihood: Double
    let userActivityState: String              // "working", "watching", "idle"
    let mediaPreferenceConfidence: Double
    let recentMediaFeedback: String            // "accepted_music", "dismissed_music", "none"

    func log() {
        print("[MediaAwareness] foreground_media=\(foregroundMediaPresent ? "yes" : "no") source_type=\(mediaSourceType.rawValue) confidence=\(String(format: "%.2f", foregroundMediaConfidence)) background_music=\(backgroundMusicState) conflict=\(audioConflictLikelihood > 0.5 ? "yes" : "no")")
    }
}

// MARK: - Classifier

enum MediaAwarenessClassifier {

    static func classify(
        mediaState: EnvironmentMediaState,
        activeApp: String,
        recentApps: [String],
        domain: DeterminerSignal.Domain,
        behavior: BehavioralState,
        workflow: AmbientWorkflowType,
        activityState: EnvironmentActivityContext,
        userContext: EnvironmentUserContext
    ) -> MediaAwarenessSnapshot {

        let (foregroundPresent, sourceType, fgConf, fgState) =
            classifyForeground(mediaState: mediaState, activeApp: activeApp, domain: domain, behavior: behavior, workflow: workflow)

        let backgroundMusicState: String
        if mediaState.isMusicPlaying {
            backgroundMusicState = "playing"
        } else {
            let appText = ([activeApp] + recentApps).joined(separator: " ").lowercased()
            backgroundMusicState = (appText.contains("music") || appText.contains("spotify")) ? "paused" : "stopped"
        }

        let conflictLikelihood: Double = (foregroundPresent && mediaState.isMusicPlaying) ? 0.9 :
                                         (foregroundPresent ? 0.3 : 0.0)

        let userActivityState: String
        if workflow == .watching || behavior == .watching || domain == .watching {
            userActivityState = "watching"
        } else if activityState.isActive {
            userActivityState = "working"
        } else {
            userActivityState = "idle"
        }

        let dismissed = Set(userContext.recentDismissedActions.map { $0.lowercased() })
        let accepted  = Set(userContext.recentAcceptedActions.map { $0.lowercased() })
        let recentFeedback: String
        let prefConf: Double
        let mediaKw = ["play", "music", "media", "playlist"]
        if accepted.contains(where: { a in mediaKw.contains(where: { a.contains($0) }) }) {
            recentFeedback = "accepted_music"; prefConf = 0.8
        } else if dismissed.contains(where: { d in mediaKw.contains(where: { d.contains($0) }) }) {
            recentFeedback = "dismissed_music"; prefConf = 0.2
        } else {
            recentFeedback = "none"; prefConf = 0.5
        }

        return MediaAwarenessSnapshot(
            foregroundMediaPresent: foregroundPresent,
            foregroundMediaConfidence: fgConf,
            mediaSourceType: sourceType,
            foregroundMediaPlaybackState: fgState,
            backgroundMusicState: backgroundMusicState,
            audioConflictLikelihood: conflictLikelihood,
            userActivityState: userActivityState,
            mediaPreferenceConfidence: prefConf,
            recentMediaFeedback: recentFeedback
        )
    }

    private static func classifyForeground(
        mediaState: EnvironmentMediaState,
        activeApp: String,
        domain: DeterminerSignal.Domain,
        behavior: BehavioralState,
        workflow: AmbientWorkflowType
    ) -> (Bool, MediaSourceType, Double, String) {
        // Browser video (from existing EnvironmentMediaState visual kind)
        if mediaState.visualMediaKind == .youtubeVideo || mediaState.visualMediaKind == .genericVideo {
            return (true, .browserVideo, 0.9, "playing")
        }
        if mediaState.visualMediaKind == .movieOrShow {
            return (true, .browserVideo, 0.85, "playing")
        }
        // Native video app
        let videoApps = ["QuickTime Player", "VLC", "IINA", "Infuse", "Plex"]
        if videoApps.contains(where: { activeApp.contains($0) }) {
            return (true, .nativeVideoApp, 0.9, "playing")
        }
        // Domain/behavior signal
        if domain == .watching || behavior == .watching || workflow == .watching {
            return (true, .browserVideo, 0.7, "playing")
        }
        return (false, .unknown, 0.0, "unknown")
    }
}

// MARK: - Music Usefulness Evaluator

struct MusicUsefulnessResult: Sendable {
    let eligible: Bool
    let reason: String
}

enum MusicUsefulnessEvaluator {

    static func evaluate(
        capabilityID: String,
        awareness: MediaAwarenessSnapshot,
        isMusicAlreadyPlaying: Bool,
        recentFeedbackCooldownActive: Bool,
        hasHigherPriorityTaskAction: Bool
    ) -> MusicUsefulnessResult {

        // Foreground media + no background music → don't start music
        if awareness.foregroundMediaPresent && awareness.backgroundMusicState != "playing" {
            print("[MusicSuggestion] suppressed reason=foreground_media_no_music_needed")
            print("[MediaUsefulness] capability=\(capabilityID) eligible=no reason=foreground_media_no_music_needed")
            return MusicUsefulnessResult(eligible: false, reason: "foreground_media_no_music_needed")
        }

        if isMusicAlreadyPlaying {
            print("[MusicSuggestion] suppressed reason=already_playing")
            print("[MediaUsefulness] capability=\(capabilityID) eligible=no reason=already_playing")
            return MusicUsefulnessResult(eligible: false, reason: "already_playing")
        }

        if recentFeedbackCooldownActive {
            print("[MusicSuggestion] suppressed reason=recent_feedback_cooldown")
            print("[MediaUsefulness] capability=\(capabilityID) eligible=no reason=recent_feedback_cooldown")
            return MusicUsefulnessResult(eligible: false, reason: "recent_feedback_cooldown")
        }

        if hasHigherPriorityTaskAction {
            print("[MusicSuggestion] suppressed reason=task_action_preferred")
            print("[MediaUsefulness] capability=\(capabilityID) eligible=no reason=task_action_preferred")
            return MusicUsefulnessResult(eligible: false, reason: "task_action_preferred")
        }

        // Foreground media + background music already playing → conflict action eligible
        if awareness.foregroundMediaPresent && awareness.backgroundMusicState == "playing" {
            print("[MusicSuggestion] generated capability=pause_media reason=audio_conflict_foreground_and_background_music")
            print("[MediaUsefulness] capability=\(capabilityID) eligible=yes reason=audio_conflict")
            return MusicUsefulnessResult(eligible: true, reason: "audio_conflict")
        }

        print("[MusicSuggestion] generated capability=\(capabilityID) reason=work_context_no_music")
        print("[MediaUsefulness] capability=\(capabilityID) eligible=yes reason=work_context_no_music")
        return MusicUsefulnessResult(eligible: true, reason: "work_context_no_music")
    }
}

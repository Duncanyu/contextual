import AppKit
import Foundation

struct MediaPlaybackSnapshot: Sendable, Equatable {
    let isMusicPlaying: Bool
    let detectionAvailable: Bool
    let source: String
    let reason: String
}

enum MediaStateSource {
    static func currentSnapshot() -> MediaPlaybackSnapshot {
        let checks = [
            MediaAppCheck(appName: "Spotify", bundleIdentifier: "com.spotify.client", playerStateScript: "tell application \"Spotify\" to player state as string"),
            MediaAppCheck(appName: "Music", bundleIdentifier: "com.apple.Music", playerStateScript: "tell application \"Music\" to player state as string")
        ]

        var anyRunning = false
        var sawUnavailable = false

        for check in checks {
            guard isRunning(bundleIdentifier: check.bundleIdentifier) else { continue }
            anyRunning = true
            switch runPlayerStateScript(check.playerStateScript) {
            case .success(let state):
                let normalized = state.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if normalized.contains("playing") {
                    return MediaPlaybackSnapshot(isMusicPlaying: true, detectionAvailable: true, source: "system_sources_\(check.appName.lowercased())", reason: "player_state=playing")
                }
            case .unavailable:
                sawUnavailable = true
            }
        }

        if anyRunning && sawUnavailable {
            return MediaPlaybackSnapshot(isMusicPlaying: false, detectionAvailable: false, source: "system_sources", reason: "player_state_unavailable")
        }
        return MediaPlaybackSnapshot(isMusicPlaying: false, detectionAvailable: true, source: "system_sources", reason: "no_music_player_playing")
    }

    private static func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Returns the name of the currently playing playlist, if detectable.
    /// Checks Music.app first, then Spotify. Returns nil if no playlist is active.
    static func currentPlaylistName() -> String? {
        if isRunning(bundleIdentifier: "com.apple.Music") {
            let script = "tell application \"Music\" to name of current playlist"
            if case .success(let name) = runPlayerStateScript(script) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != "Library" {
                    return trimmed
                }
            }
        }
        if isRunning(bundleIdentifier: "com.spotify.client") {
            let script = "tell application \"Spotify\" to name of current track"
            if case .success(let name) = runPlayerStateScript(script) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return "Spotify:\(trimmed)"
                }
            }
        }
        return nil
    }

    private enum ScriptResult {
        case success(String)
        case unavailable
    }

    private static func runPlayerStateScript(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else { return .unavailable }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return .unavailable }
        return .success(result.stringValue ?? "")
    }
}

private struct MediaAppCheck {
    let appName: String
    let bundleIdentifier: String
    let playerStateScript: String
}

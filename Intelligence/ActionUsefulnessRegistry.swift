import Foundation

// MARK: - Usefulness Requirement

struct ActionUsefulnessRequirement: Sendable {
    let capabilityID: String
    let requiredEvidence: [String]
    let requiredTargetState: String
    let disallowedTargetState: [String]
    let activityCompatibility: [String]
    let defaultSurface: String
    let executionPreflight: String
    let verificationMethod: String
    let fallbackAllowed: Bool

    func log() {
        print("[ActionUsefulnessRegistry] capability=\(capabilityID) default_surface=\(defaultSurface) required_target_state=\(requiredTargetState) fallback_allowed=\(fallbackAllowed ? "yes" : "no")")
    }
}

// MARK: - Registry

enum ActionUsefulnessRegistry {

    static let requirements: [String: ActionUsefulnessRequirement] = buildRegistry()

    static func requirement(for id: String) -> ActionUsefulnessRequirement? { requirements[id] }

    static func logAll() {
        for req in requirements.values.sorted(by: { $0.capabilityID < $1.capabilityID }) {
            req.log()
        }
    }

    private static func buildRegistry() -> [String: ActionUsefulnessRequirement] {
        var r: [String: ActionUsefulnessRequirement] = [:]

        r["arrange_side_by_side"] = .init(
            capabilityID: "arrange_side_by_side",
            requiredEvidence: ["active_window_pair", "work_pair_alternation"],
            requiredTargetState: "two_distinct_app_windows_present",
            disallowedTargetState: ["already_side_by_side", "single_window_only"],
            activityCompatibility: ["coding", "writing", "researching", "working"],
            defaultSurface: "floating",
            executionPreflight: "contract_target_check",
            verificationMethod: "ax_frame_check",
            fallbackAllowed: false
        )

        r["switch_to_paired_app"] = .init(
            capabilityID: "switch_to_paired_app",
            requiredEvidence: ["work_pair_alternation", "active_window"],
            requiredTargetState: "paired_app_running_background",
            disallowedTargetState: ["single_app_context", "paired_app_already_focused"],
            activityCompatibility: ["coding", "writing", "researching", "working"],
            defaultSurface: "floating",
            executionPreflight: "contract_target_check",
            verificationMethod: "frontmost_app_check",
            fallbackAllowed: false
        )

        r["play_focus_media"] = .init(
            capabilityID: "play_focus_media",
            requiredEvidence: ["work_context", "no_music_playing", "no_foreground_video"],
            requiredTargetState: "music_stopped_or_paused",
            disallowedTargetState: ["music_already_playing", "foreground_video_active", "gaming_audio_sensitive"],
            activityCompatibility: ["coding", "writing", "studying", "researching"],
            defaultSurface: "panel_only",
            executionPreflight: "media_awareness_check",
            verificationMethod: "player_state_check",
            fallbackAllowed: false
        )

        r["pause_media"] = .init(
            capabilityID: "pause_media",
            requiredEvidence: ["music_playing", "foreground_video_present"],
            requiredTargetState: "music_playing_and_foreground_media_active",
            disallowedTargetState: ["no_music_playing"],
            activityCompatibility: ["watching", "any"],
            defaultSurface: "floating",
            executionPreflight: "media_awareness_check",
            verificationMethod: "player_state_check",
            fallbackAllowed: false
        )

        r["copy_current_url"] = .init(
            capabilityID: "copy_current_url",
            requiredEvidence: ["active_browser_tab", "valid_url"],
            requiredTargetState: "browser_tab_with_url_present",
            disallowedTargetState: ["no_browser_open"],
            activityCompatibility: ["browsing", "researching", "any"],
            defaultSurface: "panel_only",
            executionPreflight: "browser_context_check",
            verificationMethod: "clipboard_check",
            fallbackAllowed: false
        )

        r["collect_references"] = .init(
            capabilityID: "collect_references",
            requiredEvidence: ["multiple_browser_tabs", "research_context"],
            requiredTargetState: "multiple_relevant_tabs_open",
            disallowedTargetState: ["single_tab", "no_browser_open"],
            activityCompatibility: ["researching", "writing", "studying"],
            defaultSurface: "panel_only",
            executionPreflight: "browser_context_check",
            verificationMethod: "clipboard_check",
            fallbackAllowed: false
        )

        r["remember_workspace"] = .init(
            capabilityID: "remember_workspace",
            requiredEvidence: ["multiple_apps_open", "stable_compartment"],
            requiredTargetState: "learnable_workspace_present",
            disallowedTargetState: ["single_app", "fresh_compartment"],
            activityCompatibility: ["any"],
            defaultSurface: "panel_only",
            executionPreflight: "workspace_inventory_check",
            verificationMethod: "workspace_memory_check",
            fallbackAllowed: false
        )

        r["open_current_task_panel"] = .init(
            capabilityID: "open_current_task_panel",
            requiredEvidence: ["task_context"],
            requiredTargetState: "task_inferred",
            disallowedTargetState: ["panel_already_open"],
            activityCompatibility: ["any"],
            defaultSurface: "panel_only",
            executionPreflight: "none",
            verificationMethod: "panel_visibility_check",
            fallbackAllowed: false
        )

        // --- Future action families (not yet implemented) ---

        r["restore_missing_workspace_member"] = .init(
            capabilityID: "restore_missing_workspace_member",
            requiredEvidence: ["durable_workspace_record", "member_app_missing"],
            requiredTargetState: "workspace_partially_missing",
            disallowedTargetState: ["workspace_fully_present"],
            activityCompatibility: ["coding", "writing", "researching"],
            defaultSurface: "floating",
            executionPreflight: "workspace_inventory_check",
            verificationMethod: "app_presence_check",
            fallbackAllowed: true
        )

        r["switch_to_present_but_backgrounded_pair"] = .init(
            capabilityID: "switch_to_present_but_backgrounded_pair",
            requiredEvidence: ["work_pair_alternation", "target_window_in_background"],
            requiredTargetState: "paired_window_backgrounded_but_present",
            disallowedTargetState: ["paired_window_frontmost", "no_paired_window"],
            activityCompatibility: ["coding", "writing", "researching"],
            defaultSurface: "floating",
            executionPreflight: "contract_target_check",
            verificationMethod: "frontmost_app_check",
            fallbackAllowed: false
        )

        r["arrange_active_work_pair"] = .init(
            capabilityID: "arrange_active_work_pair",
            requiredEvidence: ["two_work_windows_identified"],
            requiredTargetState: "two_work_windows_not_already_arranged",
            disallowedTargetState: ["already_arranged", "single_window"],
            activityCompatibility: ["coding", "writing", "researching", "working"],
            defaultSurface: "floating",
            executionPreflight: "contract_target_check",
            verificationMethod: "ax_frame_check",
            fallbackAllowed: false
        )

        r["coding_error_diagnosis"] = .init(
            capabilityID: "coding_error_diagnosis",
            requiredEvidence: ["xcode_build_errors", "error_text_visible"],
            requiredTargetState: "build_errors_present",
            disallowedTargetState: ["no_build_errors", "no_xcode_open"],
            activityCompatibility: ["debugging", "coding"],
            defaultSurface: "floating",
            executionPreflight: "error_context_check",
            verificationMethod: "error_presence_check",
            fallbackAllowed: false
        )

        r["research_reference_collection"] = .init(
            capabilityID: "research_reference_collection",
            requiredEvidence: ["multiple_relevant_sources", "research_context"],
            requiredTargetState: "multiple_sources_open",
            disallowedTargetState: ["single_source", "unrelated_tabs"],
            activityCompatibility: ["researching", "writing", "studying"],
            defaultSurface: "panel_only",
            executionPreflight: "browser_context_check",
            verificationMethod: "clipboard_check",
            fallbackAllowed: false
        )

        r["explicit_visible_capture_summary"] = .init(
            capabilityID: "explicit_visible_capture_summary",
            requiredEvidence: ["selected_text_or_ocr", "stable_context"],
            requiredTargetState: "readable_content_present",
            disallowedTargetState: ["no_content"],
            activityCompatibility: ["reading", "studying", "researching"],
            defaultSurface: "panel_only",
            executionPreflight: "content_evidence_check",
            verificationMethod: "output_presence_check",
            fallbackAllowed: false
        )

        r["media_conflict_reduction"] = .init(
            capabilityID: "media_conflict_reduction",
            requiredEvidence: ["music_playing", "foreground_video_detected"],
            requiredTargetState: "audio_conflict_present",
            disallowedTargetState: ["no_music_playing"],
            activityCompatibility: ["watching", "any"],
            defaultSurface: "floating",
            executionPreflight: "media_awareness_check",
            verificationMethod: "player_state_check",
            fallbackAllowed: false
        )

        return r
    }
}

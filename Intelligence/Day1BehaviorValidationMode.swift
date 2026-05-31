import Foundation

public struct AmbientMVPMode: Sendable {
    
    public static var isEnabled: Bool {
        return ValidationConfiguration.day1BehaviorValidationEnabled
    }
    
    public static var source: String {
        // Precedence mirrors ValidationConfiguration.day1BehaviorValidationEnabled:
        // env > explicit defaults > debug-default > none.
        if let env = ProcessInfo.processInfo.environment["CONTEXTUAL_AMBIENT_MVP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           env == "1" || env == "yes" || env == "true" {
            return "env"
        }
        if UserDefaults.standard.object(forKey: "contextual.day1BehaviorValidationMode") != nil,
           UserDefaults.standard.bool(forKey: "contextual.day1BehaviorValidationMode") {
            return "userdefaults"
        }
        #if DEBUG
        if isEnabled { return "debug_default" }
        #endif
        return "none"
    }

    public static func logStatus() {
        if isEnabled {
            print("[AmbientMVPMode] enabled=yes")
            print("[Day1ValidationMode] enabled=yes source=\(source)")
        } else {
            print("[AmbientMVPMode] enabled=no")
            print("[Day1ValidationMode] enabled=no source=none")
        }
    }
}

// Backward-compatible alias
public typealias Day1BehaviorValidationMode = AmbientMVPMode

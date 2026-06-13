import Foundation

/// Manages the unified Debug Mode for the application.
enum DebugMode {
    private static let userDefaultsKey = "contextual_debug_mode_enabled"
    
    /// Whether debug mode is currently enabled.
    static var isEnabled: Bool {
        get {
            let enabled = UserDefaults.standard.bool(forKey: userDefaultsKey)
            // It will default to false if not set.
            return enabled
        }
        set {
            UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
            print("[DebugMode] enabled=\(newValue ? "yes" : "no") source=ui")
            print("[DebugToggleSideEffectCheck] product_rebuild=no allowed=no")
            logFilterState()
        }
    }
    
    /// Initializes and logs the current debug mode state from UserDefaults.
    static func initialize() {
        let stored = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool
        if stored == nil {
            UserDefaults.standard.set(false, forKey: userDefaultsKey)
            print("[DebugModeDefault] enabled=no source=default")
        } else if stored == true {
            UserDefaults.standard.set(false, forKey: userDefaultsKey)
            print("[DebugModeDefault] enabled=no source=reset_userdefaults")
        } else {
            print("[DebugModeDefault] enabled=no source=userdefaults")
        }
        let enabled = isEnabled
        print("[DebugMode] enabled=\(enabled ? "yes" : "no") source=userdefaults")
        logFilterState()
    }
    
    private static func logFilterState() {
        let mode = isEnabled ? "debug" : "normal"
        let suppressed = isEnabled ? "none" : "action_ontology,primitive_registry,window_discovery,selftests,suppressions,capabilities"
        print("[DebugLogFilter] mode=\(mode) suppressed_categories=\(suppressed)")
    }
    
    /// Helper to log when a UI component's visibility is determined by debug mode.
    static func logUIVisibility(component: String, visible: Bool) {
        print("[DebugUIVisibility] component=\(component) visible=\(visible ? "yes" : "no") reason=\(isEnabled ? "debug_mode_on" : "debug_mode_off")")
    }
    
    /// Helper to determine if a noisy log should be suppressed in dogfood mode.
    static var shouldSuppressNoisyLogs: Bool {
        return !isEnabled
    }
}

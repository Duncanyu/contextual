import Foundation

public enum LogVerbosity: String, Sendable, Codable {
    case dogfood
    case debug
    case trace
}

public enum LogCategory: String, Sendable {
    case runtime_pair_scoring
    case menu_bar_watchdog
    case visibility_polling
    case useful_action_inventory
    case panel_inventory
    case selection_reasoning
}

public final class LogControl {
    public static let shared = LogControl()
    
    public var mode: LogVerbosity = .dogfood
    
    private let lock = NSLock()
    private var suppressionCounts: [String: Int] = [:]
    
    private init() {
        print("[LogVerbosity] mode=\(mode.rawValue)")
    }
    
    public func setMode(_ newMode: LogVerbosity) {
        mode = newMode
        print("[LogVerbosity] mode=\(mode.rawValue)")
    }
    
    public func shouldLog(category: LogCategory, level: LogVerbosity) -> Bool {
        if mode == .trace { return true }
        if mode == .debug && level != .trace { return true }
        if mode == .dogfood && level == .dogfood { return true }
        
        lock.lock()
        suppressionCounts[category.rawValue, default: 0] += 1
        let count = suppressionCounts[category.rawValue]!
        lock.unlock()
        
        // Periodically report suppression in dogfood mode
        if count % 100 == 0 && mode == .dogfood {
            print("[LogSuppression] category=\(category.rawValue) suppressed_count=\(count) mode=dogfood")
        }
        
        return false
    }
}

import Foundation

enum ContextUserActivityLevel: String, Hashable, Sendable, Codable {
	case idle
	case light
	case active
	case intense
}

struct ContextBudgetRequest: Hashable, Sendable, Codable {
	var requestedCapability: ContextCapabilityID
	var triggerSource: String

	var currentAppName: String?
	var currentBundleIdentifier: String?

	var hasSelectedText: Bool
	var selectedTextLength: Int

	var hasClipboardText: Bool
	var clipboardTextLength: Int

	var hasRecentOCR: Bool
	var hasRecentWindowSnapshot: Bool

	var isActionExecuting: Bool
	var recentExpensiveCollectionCount: Int
	var userActivityLevel: ContextUserActivityLevel
	var currentIntelligenceConfidence: Double?
	var reason: String?
}

struct ContextBudgetDecision: Hashable, Sendable, Codable {
	var allowed: Bool
	var reason: String
	var score: Double
	var requestedCapability: ContextCapabilityID

	var shouldDefer: Bool
	var suggestedRetryAfter: TimeInterval?
}


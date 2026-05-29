import Foundation

// MARK: - Event types

/// A semantically meaningful context-change moment that Phase B reasons over.
///
/// These are intentionally coarse — one event per "something interesting happened",
/// not per keystroke. The temporal buffer can carry hundreds of these without
/// pressuring the local model.
public enum ContextEventType: String, Sendable, Codable, CaseIterable {
    case activeAppChanged
    case windowTitleChanged
    case ocrAvailable
    case selectedTextChanged
    case clipboardMetadataChanged
    case typingStateChanged
    case pointerStateChanged
    case audioStateChanged
    case proposalAccepted
    case proposalDismissed
    case userIdle
    case userResumed
}

/// Privacy posture for an event. The compressor uses this to decide whether
/// any payload text may leave the process boundary in a model prompt.
public enum ContextEventPrivacy: String, Sendable, Codable {
    /// App / bundle / window title — already user-visible chrome.
    case publicMetadata
    /// Sanitized, term-level summaries (e.g. a few topic terms from OCR).
    case redactedSummary
    /// Must not be included in any prompt. (Selection / clipboard payloads.)
    case restricted
}

/// A single timestamped context-change event.
///
/// `textHints` holds at most a handful of lightweight tokens (e.g. distilled
/// OCR terms, topic words). Raw text blobs are NEVER stored here — that is a
/// privacy property, enforced by the producer.
public struct ContextEvent: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let type: ContextEventType
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String
    public let textHints: [String]
    public let sourceConfidence: Double
    public let privacyLevel: ContextEventPrivacy
    public let activityIntensity: Double

    public init(
        timestamp: Date,
        type: ContextEventType,
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String,
        textHints: [String] = [],
        sourceConfidence: Double = 0.7,
        privacyLevel: ContextEventPrivacy = .publicMetadata,
        activityIntensity: Double = 0.0
    ) {
        self.timestamp = timestamp
        self.type = type
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        // Cap text hints to keep the stream light.
        self.textHints = Array(textHints.prefix(6))
        self.sourceConfidence = sourceConfidence
        self.privacyLevel = privacyLevel
        self.activityIntensity = max(0.0, min(activityIntensity, 1.0))
    }
}

// MARK: - Stream

/// Append-only rolling temporal log of `ContextEvent`s.
///
/// Capacity is bounded so memory stays small even on long sessions; the buffer
/// is the producer for `TemporalContextBuffer`, which slices it into rolling
/// windows. There is no disk persistence — this is short-term memory only.
///
/// Logs:
///   [ContextEventStream] appended type=... app=... title="..."
///   [ContextEventStream] size=N window_s=M
public actor ContextEventStream {

    /// Maximum events retained. Roughly 30 min at one event every ~3 seconds.
    private let maxEvents: Int
    private var events: [ContextEvent] = []

    public init(maxEvents: Int = 600) {
        self.maxEvents = max(50, maxEvents)
    }

    public func append(_ event: ContextEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        let spanSeconds: Int = {
            guard let first = events.first, let last = events.last else { return 0 }
            return Int(last.timestamp.timeIntervalSince(first.timestamp))
        }()
        let titlePreview = event.windowTitle.prefix(40)
        print("[ContextEventStream] appended type=\(event.type.rawValue) app=\(event.appName) title=\"\(titlePreview)\"")
        print("[ContextEventStream] size=\(events.count) window_s=\(spanSeconds)")
    }

    public func snapshot() -> [ContextEvent] { events }

    public func events(within: TimeInterval, now: Date = Date()) -> [ContextEvent] {
        let cutoff = now.addingTimeInterval(-within)
        return events.filter { $0.timestamp >= cutoff }
    }

    public func clear() { events.removeAll() }
}

import Foundation

struct ContentSourceAvailability: Equatable {
    var metadata: Bool
    var url: Bool
    var axText: Bool
    var ocr: Bool
    var selectedText: Bool
    var clipboard: Bool
    var browserBridge: Bool
}

struct FocusEntity: Equatable {
    let id: String
    let name: String
    let type: String
    let relevanceScore: Double
}

/// A shared source of truth representing the user's current context.
/// All suggestion adapters target this to ensure a unified understanding of "what the user is looking at".
struct CurrentFocusSummary: Equatable {
    let activeApp: String?
    let activeWindowTitle: String?
    let selectedBrowserTabTitle: String?
    let selectedBrowserTabURL: String?
    let browserTabListSummary: [String]
    let currentContentType: String?
    let semanticDomain: String?
    let activity: String?
    let evidenceLevel: String
    
    let availableContentSources: ContentSourceAvailability
    let missingContentSources: [String]
    
    let relatedFocusEntities: [FocusEntity]
    let backgroundEntities: [FocusEntity]
    let staleEntities: [FocusEntity]
    
    let debugSourceTrace: [String]
    
    init(
        activeApp: String? = nil,
        activeWindowTitle: String? = nil,
        selectedBrowserTabTitle: String? = nil,
        selectedBrowserTabURL: String? = nil,
        browserTabListSummary: [String] = [],
        currentContentType: String? = nil,
        semanticDomain: String? = nil,
        activity: String? = nil,
        evidenceLevel: String = "none",
        availableContentSources: ContentSourceAvailability = ContentSourceAvailability(metadata: false, url: false, axText: false, ocr: false, selectedText: false, clipboard: false, browserBridge: false),
        missingContentSources: [String] = [],
        relatedFocusEntities: [FocusEntity] = [],
        backgroundEntities: [FocusEntity] = [],
        staleEntities: [FocusEntity] = [],
        debugSourceTrace: [String] = []
    ) {
        self.activeApp = activeApp
        self.activeWindowTitle = activeWindowTitle
        self.selectedBrowserTabTitle = selectedBrowserTabTitle
        self.selectedBrowserTabURL = selectedBrowserTabURL
        self.browserTabListSummary = browserTabListSummary
        self.currentContentType = currentContentType
        self.semanticDomain = semanticDomain
        self.activity = activity
        self.evidenceLevel = evidenceLevel
        self.availableContentSources = availableContentSources
        self.missingContentSources = missingContentSources
        self.relatedFocusEntities = relatedFocusEntities
        self.backgroundEntities = backgroundEntities
        self.staleEntities = staleEntities
        self.debugSourceTrace = debugSourceTrace
        
        print("[CurrentFocusSummary] app=\(activeApp ?? "none") window=\(activeWindowTitle ?? "none") selected_tab=\(selectedBrowserTabTitle ?? "none") url=\((selectedBrowserTabURL?.isEmpty == false) ? "yes" : "no") content_type=\(currentContentType ?? "unknown") domain=\(semanticDomain ?? "unknown") evidence=\(evidenceLevel)")
        
        for trace in debugSourceTrace {
            print("[CurrentFocusSourceTrace] source=\(trace) confidence=high used_by=unified_focus")
        }
    }
    
    /// Records when a suggestion utilizes this focus summary.
    func logUsage(suggestionId: String, source: String) {
        print("[SuggestionUsesCurrentFocus] id=\(suggestionId) selected_tab=\(selectedBrowserTabTitle ?? "none") source=\(source)")
    }
}

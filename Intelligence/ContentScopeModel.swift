import Foundation

// MARK: - Phase 51 (Rescue Sprint): Honest Content Scope Model
//
// Every acquired context result must declare what it ACTUALLY covers, derived
// from source + quality + coverage through a hard truth table. The derivation
// is intentionally pessimistic:
//
//   - AX visible text can NEVER satisfy full_page / full_document.
//   - OCR visible text can NEVER satisfy full_page / full_document.
//   - Metadata can NEVER satisfy a cognitive action.
//   - Google Docs AX editor partial text can NEVER satisfy full_document.
//   - Browser URL/title/tabs can NEVER satisfy a page summary.
//
// Scope is the single source of truth for action titles, cognitive gates,
// and result card labels.

/// What the acquired content actually covers.
public enum AcquiredContentScope: String, Sendable, CaseIterable {
    case fullPage           = "full_page"
    case fullDocument       = "full_document"
    /// Substantial main/body content, but not provably the complete page/document
    /// (e.g. readability extraction, capped PDF pages, partial export).
    case mainArticle        = "main_article"
    case visibleViewport    = "visible_viewport"
    case selectedText       = "selected_text"
    /// Visible-layer text known to be incomplete (e.g. Google Docs AX editor tiles).
    case partialVisibleText = "partial_visible_text"
    case metadataOnly       = "metadata_only"
    case failed             = "failed"

    /// True when the scope is real readable content (not metadata / failure).
    var hasReadableContent: Bool {
        switch self {
        case .metadataOnly, .failed: return false
        default: return true
        }
    }

    /// True when this scope can honestly be presented as a whole page/document.
    var satisfiesFullScope: Bool {
        self == .fullPage || self == .fullDocument
    }
}

/// What scope a capability is asking for.
enum RequestedContentScope: String, Sendable {
    case fullPage       = "full_page"
    case fullDocument   = "full_document"
    case visibleViewport = "visible_viewport"
    case selection      = "selection"
}

enum ContentScopeModel {

    /// Hard truth table: derive the actual scope from acquisition facts.
    /// Source identity wins over char counts — no amount of AX text becomes a page.
    static func derive(
        source: ContentSource,
        quality: ContentQuality,
        coverage: ContentCoverage
    ) -> AcquiredContentScope {
        switch source {
        case .none:
            return .failed

        case .browserMetadata, .windowMetadata:
            return .metadataOnly

        case .publicLookup:
            return quality == .none ? .failed : .mainArticle

        case .selectedText, .selectedTextAX, .selectedTextContextModel, .clipboardExisting:
            // clipboardExisting is only trusted when tied to a selection — same scope.
            return .selectedText

        case .ocrCapture:
            // OCR sees pixels of the visible screen. Never more.
            return .visibleViewport

        case .axTree, .browserAX:
            // AX exposes the visible/rendered layer. Never the full page or document.
            // Google Docs editor tiles report coverage=partial → partial_visible_text.
            return coverage == .partial ? .partialVisibleText : .visibleViewport

        case .pdfKit, .fileBacked:
            switch quality {
            case .fullDocumentText:    return .fullDocument
            case .partialDocumentText: return .mainArticle
            default:                   return .partialVisibleText
            }

        case .clipboardCapture, .clipboardCaptureUserApproved:
            // Select-all capture of the focused document, with user approval.
            switch quality {
            case .fullDocumentText:    return .fullDocument
            case .partialDocumentText: return .mainArticle
            default:                   return .partialVisibleText
            }
        }
    }

    /// What scope each capability is implicitly requesting.
    static func requestedScope(for capabilityId: String) -> RequestedContentScope {
        switch capabilityId {
        case "summarize_full_document", "extract_action_items", "create_checklist":
            return .fullDocument
        case "explicit_visible_capture_summary", "summarize_full_page", "summarize_article":
            return .fullPage
        case "summarize_visible_content", "explain_context", "diagnose_error", "summarize_thread", "draft_reply":
            return .visibleViewport
        case "rewrite_text", "improve_text", "summarize_selected_text":
            return .selection
        default:
            // Phase 53 — liquid ontology actions declare their own scope floor.
            if let liquid = WorkflowActionOntology.byId[capabilityId] {
                if liquid.executionKind == .selectionTransform { return .selection }
                if let minScope = liquid.minScope, minScope.satisfiesFullScope {
                    return minScope == .fullDocument ? .fullDocument : .fullPage
                }
            }
            return .visibleViewport
        }
    }

    /// Approximate 0–1 coverage estimate for logging.
    static func coverageEstimate(scope: AcquiredContentScope, coverage: ContentCoverage) -> Double {
        switch scope {
        case .fullPage, .fullDocument: return 1.0
        case .mainArticle:             return 0.75
        case .visibleViewport:         return 0.5
        case .selectedText:            return 0.4
        case .partialVisibleText:      return 0.3
        case .metadataOnly:            return 0.05
        case .failed:                  return 0.0
        }
    }

    /// Emit the canonical `[ContentScope]` log line.
    static func logContentScope(
        requested: RequestedContentScope,
        actual: AcquiredContentScope,
        source: ContentSource,
        chars: Int,
        coverage: ContentCoverage
    ) {
        let est = coverageEstimate(scope: actual, coverage: coverage)
        print("[ContentScope] requested=\(requested.rawValue) actual=\(actual.rawValue) source=\(source.rawValue) chars=\(chars) coverage=\(String(format: "%.2f", est))")
    }
}

// MARK: - Content Scope Gate

struct ContentScopeGateDecision: Sendable {
    let allowed: Bool
    /// Scope the action is downgraded to when the requested scope isn't met
    /// but a weaker honest action is still possible. nil when fully blocked.
    let downgrade: AcquiredContentScope?
    let reason: String
}

enum ContentScopeGate {

    /// Decide whether a capability may run at its requested scope given the actual scope.
    /// A downgrade means: the action may run, but must present itself at the actual scope.
    static func evaluate(
        capabilityId: String,
        requested: RequestedContentScope,
        actual: AcquiredContentScope,
        chars: Int
    ) -> ContentScopeGateDecision {
        let decision = evaluateInternal(requested: requested, actual: actual, chars: chars)
        print("[ContentScopeGate] capability=\(capabilityId) requested=\(requested.rawValue) actual=\(actual.rawValue) allowed=\(decision.allowed ? "yes" : "no") downgrade=\(decision.downgrade?.rawValue ?? "none") reason=\(decision.reason)")
        return decision
    }

    private static func evaluateInternal(
        requested: RequestedContentScope,
        actual: AcquiredContentScope,
        chars: Int
    ) -> ContentScopeGateDecision {
        // No readable content → cognitive actions are never allowed.
        guard actual.hasReadableContent else {
            return ContentScopeGateDecision(allowed: false, downgrade: nil,
                reason: actual == .metadataOnly ? "metadata_cannot_satisfy_cognitive_action" : "no_content_acquired")
        }
        // Too little real text to transform meaningfully.
        guard chars >= 80 else {
            return ContentScopeGateDecision(allowed: false, downgrade: nil, reason: "too_little_text chars=\(chars)")
        }

        switch requested {
        case .fullPage, .fullDocument:
            if actual.satisfiesFullScope {
                return ContentScopeGateDecision(allowed: true, downgrade: nil, reason: "full_scope_available")
            }
            // Honest downgrade: run at the actual (weaker) scope, never claim the page.
            return ContentScopeGateDecision(allowed: true, downgrade: actual,
                reason: "downgraded_to_actual_scope")
        case .visibleViewport:
            return ContentScopeGateDecision(allowed: true,
                downgrade: actual == .visibleViewport ? nil : actual,
                reason: "visible_scope_satisfied")
        case .selection:
            if actual == .selectedText {
                return ContentScopeGateDecision(allowed: true, downgrade: nil, reason: "selection_available")
            }
            return ContentScopeGateDecision(allowed: false, downgrade: nil, reason: "selection_required_but_unavailable")
        }
    }
}

// MARK: - Scope-Truth Titles

enum ScopeTruthTitles {

    /// The honest title for a summarize-family capability at a given actual scope.
    /// Titles may only claim what the scope proves.
    static func summarizeTitle(for scope: AcquiredContentScope) -> String {
        switch scope {
        case .fullPage:           return "Summarize this page"
        case .fullDocument:       return "Summarize this document"
        case .mainArticle:        return "Summarize main content"
        case .visibleViewport:    return "Summarize visible content"
        case .partialVisibleText: return "Summarize visible content"
        case .selectedText:       return "Summarize selected text"
        case .metadataOnly:       return "Capture visible page"
        case .failed:             return "Enable page access"
        }
    }

    /// Honest result-card title for a summarize result at a given actual scope.
    static func summaryCardTitle(for scope: AcquiredContentScope) -> String {
        switch scope {
        case .fullPage:           return "Page Summary"
        case .fullDocument:       return "Document Summary"
        case .mainArticle:        return "Main Content Summary"
        case .visibleViewport:    return "Visible Content Summary"
        case .partialVisibleText: return "Visible Content Summary (partial)"
        case .selectedText:       return "Selected Text Summary"
        case .metadataOnly:       return "Capture Needed"
        case .failed:             return "Content Unavailable"
        }
    }

    /// Title for any cognitive capability with scope truth applied. Falls back to
    /// the static product title for non-summarize capabilities.
    static func title(capabilityId: String, scope: AcquiredContentScope) -> String {
        let title: String
        switch capabilityId {
        case "explicit_visible_capture_summary", "summarize_visible_content",
             "summarize_full_page", "summarize_full_document", "summarize_article",
             "summarize_selected_text":
            title = summarizeTitle(for: scope)
        case "extract_action_items":
            title = scope.hasReadableContent ? "Extract action items" : "Capture visible page"
        case "create_checklist":
            title = scope.hasReadableContent ? "Make a checklist" : "Capture visible page"
        default:
            title = SuggestionTitleRewriter.cognitiveProductTitle(for: capabilityId) ?? capabilityId
        }
        print("[ActionTitle] capability=\(capabilityId) title=\"\(title)\" source=scope_truth")
        return title
    }

    /// Short user-facing scope label for result cards ("full page", "visible content", …).
    static func scopeLabel(_ scope: AcquiredContentScope) -> String {
        switch scope {
        case .fullPage:           return "full page"
        case .fullDocument:       return "full document"
        case .mainArticle:        return "main content"
        case .visibleViewport:    return "visible content"
        case .partialVisibleText: return "partial visible text"
        case .selectedText:       return "selected text"
        case .metadataOnly:       return "metadata only"
        case .failed:             return "no content"
        }
    }
}

import Foundation
import AppKit
import ApplicationServices
import PDFKit
import Vision

// MARK: - Phase 45/46: Universal Content Reader
//
// One content acquisition service, independent of app or source type.
// Routes are tried in priority order; the first that meets minimum quality wins.
// All route attempts are logged for dogfood route-matrix debugging.

// MARK: - Public API types

struct UniversalContentRequest {
    let goal: ContentGoal
    let scope: ContentScope
    let minimumQuality: ContentQuality
    let privacyMode: PrivacyMode
    let allowUserApprovedClipboardCapture: Bool
    let allowOCR: Bool
    let allowVision: Bool

    static func forGoal(_ goal: ContentGoal, scope: ContentScope = .visibleContent) -> UniversalContentRequest {
        UniversalContentRequest(
            goal: goal,
            scope: scope,
            minimumQuality: goal.minimumRequired,
            privacyMode: .standard,
            allowUserApprovedClipboardCapture: false,
            allowOCR: true,
            allowVision: false
        )
    }
}

enum ContentGoal: String {
    case summarize           = "summarize"
    case extractActionItems  = "extract_action_items"
    case createChecklist     = "create_checklist"
    case compare             = "compare"
    case draftReply          = "draft_reply"
    case explain             = "explain"
    case rewrite             = "rewrite"
    case diagnose            = "diagnose"

    var minimumRequired: ContentQuality {
        switch self {
        case .summarize, .extractActionItems, .createChecklist, .explain, .diagnose, .compare:
            return .axVisibleText
        case .draftReply, .rewrite:
            return .selectedText
        }
    }
}

enum ContentScope: String {
    case selectedText       = "selected_text"
    case visibleContent     = "visible_content"
    case currentDocument    = "current_document"
    case currentPage        = "current_page"
    case currentThread      = "current_thread"
    case currentTask        = "current_task"
}

enum ContentQuality: Int, Comparable {
    case none               = 0
    case metadataOnly       = 1
    case visibleOCR         = 2
    case axVisibleText      = 3
    case selectedText       = 4
    case partialDocumentText = 5
    case fullDocumentText   = 6

    static func < (lhs: ContentQuality, rhs: ContentQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .none:               return "none"
        case .metadataOnly:       return "metadata_only"
        case .visibleOCR:         return "visible_ocr"
        case .axVisibleText:      return "ax_visible_text"
        case .selectedText:       return "selected_text"
        case .partialDocumentText: return "partial_document_text"
        case .fullDocumentText:   return "full_document_text"
        }
    }
}

enum PrivacyMode: String {
    case standard   = "standard"
    case strict     = "strict"
}

enum ContentCoverage: String {
    case full           = "full"
    case visible        = "visible"
    case partial        = "partial"
    case minimal        = "minimal"
    case unknown        = "unknown"
}

enum ContentSource: String {
    case selectedText           = "selected_text"
    case selectedTextAX         = "selected_text_ax"
    case selectedTextContextModel = "selected_text_context_model"
    case axTree                 = "ax_tree"
    case browserAX              = "browser_ax"
    case fileBacked             = "file_backed"
    case pdfKit                 = "pdf_kit"
    case clipboardExisting      = "clipboard_existing"
    case clipboardCapture       = "clipboard_capture"
    case clipboardCaptureUserApproved = "clipboard_capture_user_approved"
    case ocrCapture             = "ocr_capture"
    case browserMetadata        = "browser_metadata"
    case windowMetadata         = "window_metadata"
    case none                   = "none"
}

enum ResolvedActionScope: String {
    case page
    case visibleSnippet
    case selection
    case clipboard
    case metadata
    case captureNeeded
}

struct ActionScopeResolution {
    let requestedScope: ResolvedActionScope
    let resolvedScope: ResolvedActionScope
    let titleAdjusted: Bool
    let title: String
    let allowed: Bool
    let reason: String
}

struct ContentRouteAttempt {
    let route: String
    let available: Bool
    let status: String   // "success" | "failed" | "skipped"
    let reason: String
    let chars: Int
    let quality: ContentQuality
    let coverage: ContentCoverage
}

enum ContentNextStep: String {
    case none                   = "none"
    case requestPermission      = "request_permission"
    case captureVisible         = "capture_visible"
    case selectText             = "select_text"
    case openFile               = "open_file"
    case exportDocument         = "export_document"
    case enableAccessibility    = "enable_accessibility"
    case allowClipboardCapture  = "allow_clipboard_capture"
    case enableScreenRecording  = "enable_screen_recording"
}

struct UniversalContentResult {
    let text: String
    let quality: ContentQuality
    let coverage: ContentCoverage
    let source: ContentSource
    let confidence: Double
    let attemptedRoutes: [ContentRouteAttempt]
    let missingReason: String?
    let nextStep: ContentNextStep?

    /// Phase 51 — Honest scope derived from source/quality/coverage truth table.
    /// AX and OCR can never yield full_page/full_document.
    var actualScope: AcquiredContentScope {
        ContentScopeModel.derive(source: source, quality: quality, coverage: coverage)
    }

    func isEnough(for goal: ContentGoal) -> Bool {
        quality >= goal.minimumRequired
    }

    static let empty = UniversalContentResult(
        text: "",
        quality: .none,
        coverage: .unknown,
        source: .none,
        confidence: 0,
        attemptedRoutes: [],
        missingReason: "no_routes_succeeded",
        nextStep: .enableAccessibility
    )
}

private struct SummarizePageGateEvaluation {
    let allowedAsPage: Bool
    let allowedAsVisibleSnippet: Bool
    let actualChars: Int
    let downgrade: String
    let reason: String
}

// MARK: - Known browser bundles

private enum BrowserFamily: String {
    case safari  = "com.apple.Safari"
    case chrome  = "com.google.Chrome"
    case firefox = "org.mozilla.firefox"
    case arc     = "company.thebrowser.Browser"
    case edge    = "com.microsoft.edgemac"
    case brave   = "com.brave.Browser"
    case unknown

    init(bundleId: String) {
        switch bundleId {
        case "com.apple.Safari":             self = .safari
        case "com.google.Chrome":            self = .chrome
        case "org.mozilla.firefox":          self = .firefox
        case "company.thebrowser.Browser":   self = .arc
        case "com.microsoft.edgemac":        self = .edge
        case "com.brave.Browser":            self = .brave
        default:                             self = .unknown
        }
    }

    var isBrowser: Bool { self != .unknown }

    var displayName: String {
        switch self {
        case .safari:  return "safari"
        case .chrome:  return "chrome"
        case .firefox: return "firefox"
        case .arc:     return "arc"
        case .edge:    return "edge"
        case .brave:   return "brave"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Main Reader

enum UniversalContentReader {

    static func read(request: UniversalContentRequest) -> UniversalContentResult {
        let app = NSWorkspace.shared.frontmostApplication
        let appName  = app?.localizedName ?? "unknown"
        let bundleId = app?.bundleIdentifier ?? "unknown"
        let titleHash = String(abs((app?.localizedName ?? "").hashValue % 99999))
        let browser   = BrowserFamily(bundleId: bundleId)
        let selectionScoped = request.scope == .selectedText

        // Part A: Route matrix header
        print("[UCRRouteMatrix] app=\(appName) bundle=\(bundleId) title_hash=\(titleHash) goal=\(request.goal.rawValue)")

        var attempts: [ContentRouteAttempt] = []
        let selectedTextAXResult = routeSelectedTextAX(app: app, request: request, attempts: &attempts)
        let selectedTextContextResult = routeSelectedTextContextModel(appBundleID: bundleId, request: request, attempts: &attempts)
        let clipboardExistingResult = routeClipboardExisting(app: app, request: request, attempts: &attempts)

        if selectionScoped {
            if let selection = bestSelectionFallback(axResult: selectedTextAXResult, contextResult: selectedTextContextResult),
               selection.quality >= request.minimumQuality {
                return finalizeResult(selection, goal: request.goal, attempts: attempts)
            }
            if let clipboardExistingResult, clipboardExistingResult.quality >= request.minimumQuality {
                return finalizeResult(clipboardExistingResult, goal: request.goal, attempts: attempts)
            }
        }

        // 1. File-backed (PDF, text, DOCX, RTF, HTML)
        let fileResult = routeFileBacked(app: app, request: request, attempts: &attempts)
        if let r = fileResult, r.quality >= request.minimumQuality {
            return finalizeResult(r, goal: request.goal, attempts: attempts)
        }

        // 2. Browser-specific route (Firefox/Safari/Chrome/Arc)
        if browser.isBrowser {
            let browserResult = routeBrowser(app: app, browser: browser, request: request, attempts: &attempts)
            if let r = browserResult, r.quality >= request.minimumQuality {
                return finalizeResult(r, goal: request.goal, attempts: attempts)
            }
        } else {
            attempts.append(attempt("browser_ax", available: false, status: "skipped",
                reason: "not_a_browser bundle=\(bundleId)", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=browser_ax available=no status=skipped reason=not_a_browser")
        }

        // 3. Generic app AX
        let axResult = routeAppAX(request: request, attempts: &attempts)
        if let r = axResult, r.quality >= request.minimumQuality {
            return finalizeResult(r, goal: request.goal, attempts: attempts)
        }

        // 4. User-approved clipboard capture
        if request.allowUserApprovedClipboardCapture {
            let clipResult = routeClipboardCapture(app: app, request: request, attempts: &attempts)
            if let r = clipResult, r.quality >= request.minimumQuality {
                return finalizeResult(r, goal: request.goal, attempts: attempts)
            }
        } else {
            attempts.append(attempt("clipboard_capture_user_approved", available: false, status: "skipped",
                reason: "not_user_approved", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=clipboard_capture_user_approved available=no status=skipped reason=not_user_approved")
        }

        // 5. OCR (visible region via Vision)
        if request.allowOCR && request.privacyMode != .strict {
            let ocrResult = routeOCR(request: request, attempts: &attempts)
            if let r = ocrResult, r.quality >= request.minimumQuality {
                return finalizeResult(r, goal: request.goal, attempts: attempts)
            }
        } else {
            let reason = request.privacyMode == .strict ? "privacy_strict" : "ocr_not_allowed"
            attempts.append(attempt("ocr_visible", available: false, status: "skipped",
                reason: reason, chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=ocr_visible available=no status=skipped reason=\(reason)")
        }

        // 6. Selection fallback for page/current-document requests.
        if let selectionFallback = bestSelectionFallback(axResult: selectedTextAXResult, contextResult: selectedTextContextResult) {
            return finalizeResult(selectionFallback, goal: request.goal, attempts: attempts)
        }

        if let clipboardExistingResult, selectionScoped {
            return finalizeResult(clipboardExistingResult, goal: request.goal, attempts: attempts)
        }

        // 7. Metadata (last resort — clearly labeled)
        let metaResult = routeMetadata(app: app, request: request, attempts: &attempts)
        if let r = metaResult {
            return finalizeResult(r, goal: request.goal, attempts: attempts)
        }

        // Nothing worked
        let next = defaultNextStep(goal: request.goal, bundleId: bundleId)
        let empty = UniversalContentResult(
            text: "", quality: .none, coverage: .unknown, source: .none,
            confidence: 0, attemptedRoutes: attempts, missingReason: "all_routes_failed",
            nextStep: next
        )
        print("[UCRFinal] selected_route=none quality=none chars=0 enough_for_goal=no next_step=\(next.rawValue)")
        return empty
    }

    // MARK: - Route 1: Selected Text

    private static func bestSelectionFallback(
        axResult: UniversalContentResult?,
        contextResult: UniversalContentResult?
    ) -> UniversalContentResult? {
        if let axResult { return axResult }
        return contextResult
    }

    private static func routeSelectedTextAX(
        app: NSRunningApplication?,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let app else {
            attempts.append(attempt("selected_text_ax", available: false, status: "skipped", reason: "no_app", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=selected_text_ax available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = axFocusedWindow(axApp),
              let text = axFindSelectedText(in: window, depth: 0, maxDepth: 7)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 10 else {
            attempts.append(attempt("selected_text_ax", available: false, status: "failed", reason: "no_selection_found", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=selected_text_ax available=no status=failed reason=no_selection_found chars=0 quality=none coverage=unknown")
            return nil
        }

        let quality: ContentQuality = text.count >= 50 ? .selectedText : .axVisibleText
        attempts.append(attempt("selected_text_ax", available: true, status: "success", reason: "ax_selection_found", chars: text.count, quality: quality, coverage: .partial))
        print("[UCRRouteAttempt] route=selected_text_ax available=yes status=success reason=ax_selection_found chars=\(text.count) quality=\(quality.label) coverage=partial")
        return ucResult(text: text, quality: quality, coverage: .partial, source: .selectedTextAX, confidence: 0.95)
    }

    private static func routeSelectedTextContextModel(
        appBundleID: String,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let snapshot = ContentTrustStore.shared.latestSelection(frontmostBundleID: appBundleID) else {
            attempts.append(attempt("selected_text_context_model", available: false, status: "failed", reason: "no_recent_selection_snapshot", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=selected_text_context_model available=no status=failed reason=no_recent_selection_snapshot chars=0 quality=none coverage=unknown")
            return nil
        }
        let age = Date().timeIntervalSince(snapshot.capturedAt)
        guard age <= 20 else {
            attempts.append(attempt("selected_text_context_model", available: true, status: "failed", reason: "selection_snapshot_stale", chars: snapshot.text.count, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=selected_text_context_model available=yes status=failed reason=selection_snapshot_stale chars=\(snapshot.text.count) quality=none coverage=unknown")
            return nil
        }

        let text = snapshot.text
        let quality: ContentQuality = text.count >= 50 ? .selectedText : .axVisibleText
        attempts.append(attempt("selected_text_context_model", available: true, status: "success", reason: "selection_snapshot_fresh", chars: text.count, quality: quality, coverage: .partial))
        print("[UCRRouteAttempt] route=selected_text_context_model available=yes status=success reason=selection_snapshot_fresh chars=\(text.count) quality=\(quality.label) coverage=partial")
        return ucResult(text: text, quality: quality, coverage: .partial, source: .selectedTextContextModel, confidence: 0.82)
    }

    private static func routeClipboardExisting(
        app: NSRunningApplication?,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let app else {
            attempts.append(attempt("clipboard_existing", available: false, status: "skipped", reason: "no_app", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=clipboard_existing available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }

        guard let snapshot = ContentTrustStore.shared.latestClipboard() else {
            print("[ClipboardTrust] available=no age_s=-1 app_changed_since_write=no tied_to_selection=no trusted_for_goal=no reason=no_clipboard_snapshot")
            attempts.append(attempt("clipboard_existing", available: false, status: "blocked", reason: "source_unknown", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=clipboard_existing available=no status=blocked chars=0 quality=none reason=source_unknown")
            return nil
        }

        let age = Date().timeIntervalSince(snapshot.capturedAt)
        let appChangedSinceWrite = snapshot.bundleID != (app.bundleIdentifier ?? "unknown")
        let isFresh = age >= 0 && age <= 20
        let selectionScoped = request.scope == .selectedText
        let trustedForGoal = selectionScoped && isFresh && !appChangedSinceWrite && snapshot.tiedToSelection
        let reason: String = {
            if !isFresh { return "stale" }
            if appChangedSinceWrite { return "app_changed" }
            if !snapshot.tiedToSelection { return "not_goal_safe" }
            return "trusted"
        }()

        print("[ClipboardTrust] available=yes age_s=\(Int(age.rounded())) app_changed_since_write=\(appChangedSinceWrite ? "yes" : "no") tied_to_selection=\(snapshot.tiedToSelection ? "yes" : "no") trusted_for_goal=\(trustedForGoal ? "yes" : "no") reason=\(reason)")

        guard trustedForGoal else {
            attempts.append(attempt("clipboard_existing", available: true, status: "blocked", reason: reason, chars: snapshot.text.count, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=clipboard_existing status=blocked chars=\(snapshot.text.count) quality=clipboard_text reason=\(reason)")
            return nil
        }

        attempts.append(attempt("clipboard_existing", available: true, status: "success", reason: "trusted", chars: snapshot.text.count, quality: .selectedText, coverage: .partial))
        print("[UCRRouteAttempt] route=clipboard_existing status=success chars=\(snapshot.text.count) quality=clipboard_text reason=trusted")
        return ucResult(text: snapshot.text, quality: .selectedText, coverage: .partial, source: .clipboardExisting, confidence: 0.72)
    }

    // MARK: - Route 2: File-Backed

    private static func routeFileBacked(
        app: NSRunningApplication?,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let app = app else {
            attempts.append(attempt("file_backed", available: false, status: "skipped", reason: "no_app", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=file_backed available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = axFocusedWindow(axApp) else {
            attempts.append(attempt("file_backed", available: false, status: "skipped", reason: "no_ax_window", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=file_backed available=no status=skipped reason=no_ax_window chars=0 quality=none coverage=unknown")
            return nil
        }

        var docRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
              let docStr = docRef as? String,
              let fileURL = URL(string: docStr), fileURL.isFileURL else {
            attempts.append(attempt("file_backed", available: false, status: "skipped", reason: "no_ax_document_url", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=file_backed available=no status=skipped reason=no_ax_document_url chars=0 quality=none coverage=unknown")
            return nil
        }

        let ext = fileURL.pathExtension.lowercased()
        print("[FileBackedRoute] file_type=\(ext) path_resolved=yes")

        let result: UniversalContentResult?
        switch ext {
        case "pdf":
            result = fileReadPDF(url: fileURL)
        case "txt", "md", "markdown", "text", "swift", "py", "js", "ts", "java", "c", "h", "cpp", "go", "rs", "sh", "rb", "php", "css", "html", "htm":
            result = fileReadPlainText(url: fileURL, ext: ext)
        case "rtf", "rtfd":
            result = fileReadRTF(url: fileURL)
        case "docx":
            result = fileReadDOCX(url: fileURL)
        default:
            print("[FileBackedRoute] extraction=unsupported chars=0 quality=none")
            attempts.append(attempt("file_backed", available: true, status: "skipped", reason: "unsupported_format_\(ext)", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=file_backed available=yes status=skipped reason=unsupported_format_\(ext) chars=0 quality=none coverage=unknown")
            return nil
        }

        guard let r = result else {
            attempts.append(attempt("file_backed", available: true, status: "failed", reason: "extraction_failed_\(ext)", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=file_backed available=yes status=failed reason=extraction_failed ext=\(ext) chars=0 quality=none coverage=unknown")
            return nil
        }
        attempts.append(attempt("file_backed", available: true, status: "success", reason: "extraction_\(ext)", chars: r.text.count, quality: r.quality, coverage: r.coverage))
        print("[UCRRouteAttempt] route=file_backed available=yes status=success reason=extraction_\(ext) chars=\(r.text.count) quality=\(r.quality.label) coverage=\(r.coverage.rawValue)")
        return r
    }

    private static func fileReadPDF(url: URL) -> UniversalContentResult? {
        guard let doc = PDFDocument(url: url) else {
            print("[FileBackedRoute] extraction=pdfkit chars=0 quality=none reason=open_failed")
            return nil
        }
        let pageCount = doc.pageCount
        var texts: [String] = []
        var totalChars = 0
        let maxPages = min(pageCount, 30)
        for i in 0..<maxPages {
            if let page = doc.page(at: i), let t = page.string, t.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 {
                texts.append(t); totalChars += t.count
            }
        }
        // Scanned PDF detection: if total text is tiny despite having pages
        let scanned = pageCount > 0 && totalChars < 50
        print("[FileBackedRoute] scanned_pdf_detected=\(scanned ? "yes" : "no") reason=\(scanned ? "text_per_page_near_zero" : "has_embedded_text") pages=\(pageCount) chars=\(totalChars)")
        if scanned {
            print("[FileBackedRoute] extraction=pdfkit chars=0 quality=none reason=scanned_pdf_no_embedded_text")
            return nil  // Caller will try OCR
        }
        guard totalChars >= 50 else { return nil }
        let combined = texts.joined(separator: "\n\n")
        let capped = String(combined.prefix(60000))
        let quality: ContentQuality = maxPages >= pageCount ? .fullDocumentText : .partialDocumentText
        print("[FileBackedRoute] extraction=pdfkit chars=\(capped.count) quality=\(quality.label) coverage=\(quality == .fullDocumentText ? "full" : "partial")")
        return ucResult(text: capped, quality: quality, coverage: quality == .fullDocumentText ? .full : .partial, source: .pdfKit, confidence: 0.92)
    }

    private static func fileReadPlainText(url: URL, ext: String) -> UniversalContentResult? {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
              text.count >= 5 else {
            print("[FileBackedRoute] extraction=plain chars=0 quality=none reason=read_failed")
            return nil
        }
        let capped = String(text.prefix(60000))
        let q: ContentQuality = text.count <= 60000 ? .fullDocumentText : .partialDocumentText
        let isCode = ["swift","py","js","ts","java","c","h","cpp","go","rs","sh","rb","php"].contains(ext)
        print("[FileBackedRoute] extraction=\(isCode ? "code" : "plain") chars=\(capped.count) quality=\(q.label) coverage=\(q == .fullDocumentText ? "full" : "partial")")
        return ucResult(text: capped, quality: q, coverage: q == .fullDocumentText ? .full : .partial, source: .fileBacked, confidence: 0.97)
    }

    private static func fileReadRTF(url: URL) -> UniversalContentResult? {
        guard let data = try? Data(contentsOf: url),
              let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
              attr.string.count >= 5 else {
            print("[FileBackedRoute] extraction=rtf chars=0 quality=none reason=read_failed")
            return nil
        }
        let capped = String(attr.string.prefix(60000))
        let q: ContentQuality = attr.string.count <= 60000 ? .fullDocumentText : .partialDocumentText
        print("[FileBackedRoute] extraction=rtf chars=\(capped.count) quality=\(q.label) coverage=\(q == .fullDocumentText ? "full" : "partial")")
        return ucResult(text: capped, quality: q, coverage: q == .fullDocumentText ? .full : .partial, source: .fileBacked, confidence: 0.92)
    }

    private static func fileReadDOCX(url: URL) -> UniversalContentResult? {
        guard let data = try? Data(contentsOf: url) else {
            print("[FileBackedRoute] extraction=docx_xml chars=0 quality=none reason=open_failed")
            return nil
        }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ucr_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let zipPath = tmpDir.appendingPathComponent("d.zip")
            try data.write(to: zipPath)
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            task.arguments = ["-o", zipPath.path, "word/document.xml", "-d", tmpDir.path]
            task.standardOutput = Pipe(); task.standardError = Pipe()
            try task.run(); task.waitUntilExit()
            let xmlURL = tmpDir.appendingPathComponent("word/document.xml")
            guard let xmlData = try? Data(contentsOf: xmlURL) else {
                print("[FileBackedRoute] extraction=docx_xml chars=0 quality=none reason=xml_not_found")
                return nil
            }
            let stripped = stripXMLTags(String(data: xmlData, encoding: .utf8) ?? "")
            guard stripped.count >= 20 else {
                print("[FileBackedRoute] extraction=docx_xml chars=0 quality=none reason=no_text_content")
                return nil
            }
            let capped = String(stripped.prefix(60000))
            let q: ContentQuality = stripped.count <= 60000 ? .fullDocumentText : .partialDocumentText
            print("[FileBackedRoute] extraction=docx_xml chars=\(capped.count) quality=\(q.label) coverage=\(q == .fullDocumentText ? "full" : "partial")")
            return ucResult(text: capped, quality: q, coverage: q == .fullDocumentText ? .full : .partial, source: .fileBacked, confidence: 0.87)
        } catch {
            print("[FileBackedRoute] extraction=docx_xml chars=0 quality=none reason=unzip_error")
            return nil
        }
    }

    // MARK: - Route 3: Browser Route

    private static func routeBrowser(
        app: NSRunningApplication?,
        browser: BrowserFamily,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let app = app else {
            attempts.append(attempt("browser_ax", available: false, status: "skipped", reason: "no_app", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=browser_ax available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }

        guard AXIsProcessTrusted() else {
            attempts.append(attempt("browser_ax", available: false, status: "skipped", reason: "ax_not_trusted", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=browser_ax available=no status=skipped reason=ax_not_trusted chars=0 quality=none coverage=unknown")
            print("[BrowserRoute] browser=\(browser.displayName) selected_strategy=metadata reason=no_ax_trust")
            return nil
        }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        // Get current page URL for Google Docs detection
        let browserCtx = BrowserContextExtractor.extract(appName: app.localizedName ?? "", activeAppPID: pid)
        let pageURL = browserCtx?.selectedURL ?? browserCtx?.currentURL
        let urlString = pageURL?.absoluteString ?? ""
        let isGoogleDocs = urlString.contains("docs.google.com/document")
        let isGmail = urlString.contains("mail.google.com") || urlString.contains("gmail.com")

        print("[BrowserRoute] browser=\(browser.displayName) url_present=\(urlString.isEmpty ? "no" : "yes") title_present=\(browserCtx?.selectedTitle != nil ? "yes" : "no")")

        // Google Docs special route (Part E)
        if isGoogleDocs {
            print("[GoogleDocsRoute] detected=yes url=\(urlString.prefix(50).hashValue)")
            let gdResult = routeGoogleDocs(app: app, pid: pid, axApp: axApp, request: request, attempts: &attempts)
            if let r = gdResult { return r }
        }

        // Gmail/webmail route — try AX for email body
        if isGmail {
            print("[BrowserRoute] browser=\(browser.displayName) selected_strategy=ax gmail_detected=yes")
        }

        // Browser AX text extraction — try AXWebArea descendants
        guard let window = axFocusedWindow(axApp) else {
            attempts.append(attempt("browser_ax", available: false, status: "failed", reason: "no_focused_window", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=browser_ax available=yes status=failed reason=no_focused_window chars=0 quality=none coverage=unknown")
            print("[BrowserRoute] browser=\(browser.displayName) selected_strategy=metadata reason=no_focused_window text_chars=0 quality=none")
            return nil
        }

        // Walk AX tree to find AXWebArea, then extract text from its subtree
        let (text, axNodes, rejectedChrome) = extractBrowserText(from: window, browser: browser)
        print("[AXTextRoute] root=window nodes_visited=\(axNodes) text_nodes=\(rejectedChrome + max(0, axNodes - rejectedChrome)) chars=\(text.count) rejected_ui_chrome=\(rejectedChrome)")

        guard text.count >= 30 else {
            let reason = text.isEmpty ? "no_text_in_webarea" : "text_too_short chars=\(text.count)"
            attempts.append(attempt("browser_ax", available: true, status: "failed", reason: reason, chars: text.count, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=browser_ax available=yes status=failed reason=\(reason) chars=\(text.count) quality=none coverage=unknown")
            print("[BrowserRoute] browser=\(browser.displayName) selected_strategy=ax text_chars=\(text.count) quality=none bridge_available=no reason=\(reason)")
            return nil
        }

        let quality: ContentQuality = text.count >= 300 ? .axVisibleText : .axVisibleText
        let coverage: ContentCoverage = .visible
        attempts.append(attempt("browser_ax", available: true, status: "success", reason: "webarea_ax_text", chars: text.count, quality: quality, coverage: coverage))
        print("[UCRRouteAttempt] route=browser_ax available=yes status=success reason=webarea_ax_text chars=\(text.count) quality=\(quality.label) coverage=\(coverage.rawValue)")
        print("[AXTextRoute] quality=\(quality.label) reason=webarea_text_extracted")
        print("[BrowserRoute] browser=\(browser.displayName) selected_strategy=ax text_chars=\(text.count) quality=\(quality.label) bridge_available=no reason=ax_succeeded")
        return ucResult(text: text, quality: quality, coverage: coverage, source: .browserAX, confidence: 0.78)
    }

    /// Walk AX tree for a browser window and extract text from the web content area.
    private static func extractBrowserText(
        from window: AXUIElement,
        browser: BrowserFamily
    ) -> (text: String, nodesVisited: Int, rejectedChrome: Int) {
        var fragments: [String] = []
        var nodesVisited = 0
        var rejectedChrome = 0
        let maxFragments = 120
        let maxChars = 12000
        var totalChars = 0
        let maxDepth = 10
        let maxNodes = 400
        let start = Date()

        // Known UI chrome roles to reject (not page content)
        let chromeRoles: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem",
                                         "AXTabGroup", "AXTab", "AXButton", "AXCheckBox",
                                         "AXRadioButton", "AXPopUpButton", "AXComboBox",
                                         "AXStatusBar", "AXSplitter", "AXProgressIndicator"]

        // Content roles that hold text
        let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField",
                                       "AXHeading", "AXParagraph", "AXListItem",
                                       "AXCell", "AXRow"]

        func addFragment(_ s: String) {
            guard fragments.count < maxFragments, totalChars < maxChars else { return }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3 else { return }
            // Simple dedup: skip if very similar to last fragment
            if fragments.last == t { return }
            let toAdd = t.count > 300 ? String(t.prefix(300)) : t
            fragments.append(toAdd)
            totalChars += toAdd.count
        }

        // DFS — prioritise AXWebArea, AXScrollArea subtrees
        var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]  // (element, depth, inWebContent)

        while let (node, depth, inWebContent) = stack.popLast() {
            if nodesVisited >= maxNodes || fragments.count >= maxFragments || Date().timeIntervalSince(start) > 0.35 { break }
            if depth > maxDepth { continue }
            nodesVisited += 1

            let role = axString(node, kAXRoleAttribute as CFString) ?? "unknown"

            // Skip hidden nodes
            if let hidden = axBool(node, "AXHidden" as CFString), hidden { continue }

            // If inside web content, extract text roles
            if inWebContent {
                if chromeRoles.contains(role) { rejectedChrome += 1; continue }
                if textRoles.contains(role) {
                    if let v = axString(node, kAXValueAttribute as CFString) { addFragment(v) }
                    // AXHeading often has its text as title
                    if let t = axString(node, kAXTitleAttribute as CFString) { addFragment(t) }
                }
            }

            // Get children
            var childRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childRef) == .success,
                  let children = childRef as? [AXUIElement] else { continue }

            let enterWeb = inWebContent || role == "AXWebArea" || role == "AXScrollArea"
            // Push children in reverse order (so we process first child first with popLast)
            for child in children.reversed() {
                stack.append((child, depth + 1, enterWeb))
            }
        }

        return (fragments.joined(separator: "\n"), nodesVisited, rejectedChrome)
    }

    // MARK: - Google Docs Route (Part E)

    private static func routeGoogleDocs(
        app: NSRunningApplication,
        pid: pid_t,
        axApp: AXUIElement,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        // Strategy 1: User-approved clipboard capture — the only route that can
        // honestly produce the FULL document today. Tried first when approved.
        if request.allowUserApprovedClipboardCapture {
            print("[GoogleDocsRoute] strategy=clipboard_capture status=attempting scope=full_document")
            let clipResult = performClipboardCapture(app: app, pid: pid)
            if let text = clipResult, text.count >= 30 {
                let quality: ContentQuality = text.count >= 500 ? .fullDocumentText : .partialDocumentText
                let scope = quality == .fullDocumentText ? "full_document" : "partial"
                print("[GoogleDocsRoute] strategy=clipboard_capture status=success chars=\(text.count) scope=\(scope)")
                attempts.append(attempt("clipboard_capture_user_approved", available: true, status: "success",
                    reason: "google_docs_clipboard_capture", chars: text.count, quality: quality,
                    coverage: quality == .fullDocumentText ? .full : .partial))
                print("[UCRRouteAttempt] route=clipboard_capture_user_approved available=yes status=success reason=google_docs_clipboard_capture chars=\(text.count) quality=\(quality.label) coverage=\(quality == .fullDocumentText ? "full" : "partial")")
                return ucResult(text: text, quality: quality,
                    coverage: quality == .fullDocumentText ? .full : .partial,
                    source: .clipboardCaptureUserApproved, confidence: 0.82)
            }
            print("[GoogleDocsRoute] strategy=clipboard_capture status=failed chars=0 scope=partial")
        } else {
            print("[GoogleDocsRoute] strategy=clipboard_capture status=permission_needed chars=0 scope=full_document")
            print("[GoogleDocsSetupRequired] requirement=allow_clipboard_capture")
        }

        // Strategy 2: AX focused editor — FALLBACK ONLY. The Docs canvas only
        // exposes rendered tiles, so this is partial visible text by definition
        // and can never satisfy full_document.
        if let window = axFocusedWindow(axApp) {
            let (text, _, _) = extractBrowserText(from: window, browser: .chrome)
            if text.count >= 50 {
                print("[GoogleDocsRoute] strategy=ax_visible status=success chars=\(text.count) scope=partial")
                attempts.append(attempt("browser_ax", available: true, status: "success",
                    reason: "google_docs_ax_editor_partial", chars: text.count, quality: .axVisibleText, coverage: .partial))
                print("[UCRRouteAttempt] route=browser_ax available=yes status=success reason=google_docs_ax_editor_partial chars=\(text.count) quality=ax_visible_text coverage=partial")
                return ucResult(text: text, quality: .axVisibleText, coverage: .partial, source: .browserAX, confidence: 0.7)
            }
            print("[GoogleDocsRoute] strategy=ax_visible status=failed chars=\(text.count) scope=partial")
        }

        // Strategy 3: OCR visible section
        // (falls through to OCR route in main flow — visible_viewport scope at best)

        // Strategy 4: metadata — show setup/capture-needed card
        print("[GoogleDocsRoute] strategy=metadata status=failed chars=0 scope=partial")
        print("[GoogleDocsSetupRequired] requirement=allow_clipboard_capture")
        print("[CaptureNeededCard] shown reason=google_docs_text_unavailable next_step=allow_clipboard_capture_or_visible_ocr")
        // Don't return a result — let caller show capture-needed
        return nil
    }

    // MARK: - Route 4: Generic App AX (Part C)

    private static func routeAppAX(
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard AXWindowContentSource.shared.hasAccessibilityPermission() else {
            attempts.append(attempt("app_ax", available: false, status: "skipped", reason: "no_accessibility_permission", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=app_ax available=no status=skipped reason=no_accessibility_permission chars=0 quality=none coverage=unknown")
            print("[AXTextRoute] root=none nodes_visited=0 text_nodes=0 chars=0 rejected_ui_chrome=0")
            print("[AXTextRoute] quality=none reason=no_accessibility_permission")
            return nil
        }

        guard let ctx = AXWindowContentSource.shared.extractActiveWindowContent() else {
            attempts.append(attempt("app_ax", available: true, status: "failed", reason: "ax_extraction_nil", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=app_ax available=yes status=failed reason=ax_extraction_nil chars=0 quality=none coverage=unknown")
            print("[AXTextRoute] root=window nodes_visited=0 text_nodes=0 chars=0 rejected_ui_chrome=0")
            print("[AXTextRoute] quality=none reason=ax_extraction_returned_nil")
            return nil
        }

        let fragments = ctx.visibleTextFragments.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }
        let text = fragments.prefix(100).joined(separator: "\n")
        let chars = text.count
        let nodesHint = ctx.hierarchyDepthEstimate * 10  // approximate
        print("[AXTextRoute] root=focused_window nodes_visited=~\(nodesHint) text_nodes=\(fragments.count) chars=\(chars) rejected_ui_chrome=0")

        guard chars >= 30 else {
            attempts.append(attempt("app_ax", available: true, status: "failed", reason: "ax_text_too_short", chars: chars, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=app_ax available=yes status=failed reason=ax_text_too_short chars=\(chars) quality=none coverage=unknown")
            print("[AXTextRoute] quality=none reason=text_below_minimum_threshold")
            return nil
        }

        let quality: ContentQuality = .axVisibleText
        let coverage: ContentCoverage = ctx.containsScrollableRegion ? .partial : .visible
        attempts.append(attempt("app_ax", available: true, status: "success", reason: "ax_visible_text", chars: chars, quality: quality, coverage: coverage))
        print("[UCRRouteAttempt] route=app_ax available=yes status=success reason=ax_visible_text chars=\(chars) quality=\(quality.label) coverage=\(coverage.rawValue)")
        print("[AXTextRoute] quality=\(quality.label) reason=ax_text_extracted confidence=\(String(format: "%.2f", ctx.extractionConfidence))")
        return ucResult(text: text, quality: quality, coverage: coverage, source: .axTree, confidence: ctx.extractionConfidence)
    }

    // MARK: - Route 5: Clipboard Capture (Part F)

    private static func routeClipboardCapture(
        app: NSRunningApplication?,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let app = app else {
            attempts.append(attempt("clipboard_capture_user_approved", available: false, status: "skipped", reason: "no_app", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=clipboard_capture_user_approved available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "app"
        print("[ClipboardCapture] requested app=\(appName) goal=\(request.goal.rawValue) approved=yes")

        guard let text = performClipboardCapture(app: app, pid: pid), text.count >= 30 else {
            let reason = "capture_empty_or_insufficient"
            attempts.append(attempt("clipboard_capture_user_approved", available: true, status: "failed", reason: reason, chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=clipboard_capture_user_approved available=yes status=failed reason=\(reason) chars=0 quality=none coverage=unknown")
            return nil
        }
        let capped = String(text.prefix(60000))
        let quality: ContentQuality = text.count <= 60000 ? .fullDocumentText : .partialDocumentText
        let coverage: ContentCoverage = quality == .fullDocumentText ? .full : .partial
        attempts.append(attempt("clipboard_capture_user_approved", available: true, status: "success", reason: "select_all_copy_succeeded", chars: capped.count, quality: quality, coverage: coverage))
        print("[UCRRouteAttempt] route=clipboard_capture_user_approved available=yes status=success reason=select_all_copy_succeeded chars=\(capped.count) quality=\(quality.label) coverage=\(coverage.rawValue)")
        return ucResult(text: capped, quality: quality, coverage: coverage, source: .clipboardCaptureUserApproved, confidence: 0.82)
    }

    /// Perform Select All + Copy, read clipboard, restore original. Returns captured text or nil.
    static func performClipboardCapture(app: NSRunningApplication, pid: pid_t) -> String? {
        let appName = app.localizedName ?? "app"
        // Save original clipboard
        let savedText = NSPasteboard.general.string(forType: .string)
        let savedChangeCount = NSPasteboard.general.changeCount
        print("[ClipboardCapture] saved_original=yes app=\(appName)")
        NSPasteboard.general.clearContents()

        // Cmd+A (select all), Cmd+C (copy)
        let src = CGEventSource(stateID: .combinedSessionState)
        func post(keyCode: CGKeyCode) {
            let dn = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
            dn?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
            up?.flags = .maskCommand
            dn?.postToPid(pid); up?.postToPid(pid)
        }
        post(keyCode: 0x00)  // 'a' → Select All
        Thread.sleep(forTimeInterval: 0.15)
        print("[ClipboardCapture] performed_select_all=yes")
        post(keyCode: 0x08)  // 'c' → Copy
        Thread.sleep(forTimeInterval: 0.28)
        print("[ClipboardCapture] performed_copy=yes")

        let captured = NSPasteboard.general.string(forType: .string) ?? ""
        let newCount = NSPasteboard.general.changeCount
        let changed = newCount != savedChangeCount
        print("[ClipboardCapture] captured_chars=\(captured.count) validation=\(captured.count >= 10 && changed ? "pass" : "fail")")

        // Restore original clipboard
        NSPasteboard.general.clearContents()
        if let saved = savedText { NSPasteboard.general.setString(saved, forType: .string) }
        print("[ClipboardWrite] capability=clipboard_capture_user_approved reason=temporary_capture_restore")
        print("[ClipboardCapture] restored_original=yes")
        let success = captured.count >= 10 && changed
        print("[ClipboardCapture] completed status=\(success ? "success" : "failed") reason=\(success ? "captured_and_restored" : "insufficient_content")")
        return success ? captured : nil
    }

    // MARK: - Route 6: OCR (Part B)

    private static func routeOCR(
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard ScreenCaptureSource.isScreenRecordingAuthorized() else {
            attempts.append(attempt("ocr_visible", available: false, status: "skipped", reason: "screen_recording_permission_missing", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=ocr_visible available=no status=skipped reason=screen_recording_permission_missing chars=0 quality=none coverage=unknown")
            print("[OCRRoute] skipped reason=permission_missing")
            return nil
        }
        guard let frame = ScreenCaptureSource.captureSingleFrame() else {
            attempts.append(attempt("ocr_visible", available: true, status: "failed", reason: "capture_frame_nil", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=ocr_visible available=yes status=failed reason=capture_frame_nil chars=0 quality=none coverage=unknown")
            print("[OCRRoute] skipped reason=budget_blocked")
            return nil
        }
        print("[OCRRoute] started source=window_snapshot allowed=yes")

        // Run OCR synchronously via semaphore (bounded to 3 seconds)
        let semaphore = DispatchSemaphore(value: 0)
        var ocrResult: OCRResult?
        Task.detached(priority: .utility) {
            ocrResult = await OCRProcessor.shared.recognizeText(from: frame.image)
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: .now() + 3.0) == .timedOut
        if timedOut {
            attempts.append(attempt("ocr_visible", available: true, status: "failed", reason: "ocr_timeout", chars: 0, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=ocr_visible available=yes status=failed reason=ocr_timeout chars=0 quality=none coverage=unknown")
            print("[OCRRoute] skipped reason=budget_blocked reason=timeout")
            return nil
        }
        guard let result = ocrResult, result.text.count >= 30 else {
            let chars = ocrResult?.text.count ?? 0
            attempts.append(attempt("ocr_visible", available: true, status: "failed", reason: "ocr_insufficient_text chars=\(chars)", chars: chars, quality: .none, coverage: .unknown))
            print("[UCRRouteAttempt] route=ocr_visible available=yes status=failed reason=ocr_insufficient_text chars=\(chars) quality=none coverage=unknown")
            print("[OCRRoute] completed chars=\(chars) quality=none coverage=visible_region")
            return nil
        }
        let chars = result.text.count
        print("[OCRRoute] completed chars=\(chars) quality=visibleOCR coverage=visible_region")
        attempts.append(attempt("ocr_visible", available: true, status: "success", reason: "ocr_vision_extracted", chars: chars, quality: .visibleOCR, coverage: .visible))
        print("[UCRRouteAttempt] route=ocr_visible available=yes status=success reason=ocr_vision_extracted chars=\(chars) quality=visible_ocr coverage=visible")
        return ucResult(text: result.text, quality: .visibleOCR, coverage: .visible, source: .ocrCapture, confidence: Double(result.confidenceAverage ?? 0.7))
    }

    // MARK: - Route 7: Metadata

    private static func routeMetadata(
        app: NSRunningApplication?,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        let appName = app?.localizedName ?? "unknown"
        let pid = app?.processIdentifier
        let browserCtx = BrowserContextExtractor.extract(appName: appName, activeAppPID: pid)
        let title = browserCtx?.selectedTitle ?? browserCtx?.recentTabTitles.first ?? ""
        let url   = browserCtx?.selectedURL?.absoluteString ?? browserCtx?.currentURL?.absoluteString ?? ""
        let tabs  = browserCtx?.recentTabTitles ?? []
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if !url.isEmpty   { parts.append(url) }
        let unique = Array(Set(tabs).subtracting([title])).prefix(4)
        if !unique.isEmpty { parts.append("Related: " + unique.joined(separator: "; ")) }
        let text = parts.joined(separator: "\n")
        let chars = text.count
        let available = chars > 0
        attempts.append(attempt("metadata", available: available, status: available ? "success" : "failed",
            reason: available ? "browser_window_metadata" : "no_metadata_available", chars: chars, quality: .metadataOnly, coverage: .minimal))
        print("[UCRRouteAttempt] route=metadata available=\(available ? "yes" : "no") status=\(available ? "success" : "failed") reason=\(available ? "browser_window_metadata" : "no_metadata_available") chars=\(chars) quality=metadata_only coverage=minimal")
        guard available else { return nil }
        let nextStep = defaultNextStep(goal: request.goal, bundleId: app?.bundleIdentifier ?? "")
        return UniversalContentResult(
            text: text, quality: .metadataOnly, coverage: .minimal, source: .browserMetadata,
            confidence: 0.3, attemptedRoutes: [], missingReason: "only_metadata_available",
            nextStep: nextStep
        )
    }

    // MARK: - Finalize + UCRGoalGate

    private static func finalizeResult(
        _ result: UniversalContentResult,
        goal: ContentGoal,
        attempts: [ContentRouteAttempt]
    ) -> UniversalContentResult {
        let allAttempts = attempts + result.attemptedRoutes
        let gate = goal == .summarize ? summarizePageGate(result: result) : nil
        let enough = gate?.allowedAsPage ?? result.isEnough(for: goal)
        let selectedRoute = allAttempts.last(where: { $0.status == "success" })?.route ?? result.source.rawValue
        // Phase 51 — declare actual scope for every acquisition.
        ContentScopeModel.logContentScope(
            requested: goal == .summarize ? .fullPage : .visibleViewport,
            actual: result.actualScope,
            source: result.source,
            chars: result.text.count,
            coverage: result.coverage
        )
        print("[UCRFinal] selected_route=\(selectedRoute) quality=\(result.quality.label) chars=\(result.text.count) enough_for_goal=\(enough ? "yes" : "no") next_step=\(result.nextStep?.rawValue ?? "none")")
        if let gate {
            print("[UCRGoalGate] goal=summarize_page required_chars=500 actual_chars=\(gate.actualChars) quality=\(result.quality.label) allowed=\(gate.allowedAsPage ? "yes" : "no") downgrade=\(gate.allowedAsPage ? "none" : gate.downgrade)")
        } else {
            print("[UCRGoalGate] goal=\(goal.rawValue) required=\(goal.minimumRequired.label) actual=\(result.quality.label) chars=\(result.text.count) allowed=\(enough ? "yes" : "no") downgrade=\(enough ? "none" : (result.nextStep?.rawValue ?? "capture_visible"))")
        }
        return UniversalContentResult(
            text: result.text, quality: result.quality, coverage: result.coverage,
            source: result.source, confidence: result.confidence,
            attemptedRoutes: allAttempts, missingReason: result.missingReason,
            nextStep: result.nextStep
        )
    }

    // MARK: - Cognitive Action Gate (public)

    static func gate(capabilityId: String, goal: ContentGoal, result: UniversalContentResult) -> Bool {
        if capabilityId == "explicit_visible_capture_summary" {
            let summaryGate = summarizePageGate(result: result)
            let allowed = summaryGate.allowedAsPage || summaryGate.allowedAsVisibleSnippet
            print("[CognitiveActionGate] capability=\(capabilityId) required_quality=\(goal.minimumRequired.label) actual_quality=\(result.quality.label) allowed=\(allowed ? "yes" : "no") reason=\(summaryGate.reason)")
            if !allowed {
                print("[CognitiveActionDowngrade] from=\(capabilityId) to=\(summaryGate.downgrade) reason=\(summaryGate.reason)")
            }
            return allowed
        }
        let required = goal.minimumRequired
        let actual = result.quality
        let allowed = actual >= required
        print("[CognitiveActionGate] capability=\(capabilityId) required_quality=\(required.label) actual_quality=\(actual.label) allowed=\(allowed ? "yes" : "no") reason=\(allowed ? "quality_sufficient" : "quality_below_required")")
        if !allowed {
            let to = result.nextStep?.rawValue ?? "capture_visible"
            print("[CognitiveActionDowngrade] from=\(capabilityId) to=\(to) reason=\(result.missingReason ?? "quality_too_low")")
        }
        return allowed
    }

    // MARK: - AX Helpers

    private static func axFocusedWindow(_ axApp: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] as [CFString] {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attr, &val) == .success, let v = val {
                return (v as! AXUIElement)
            }
        }
        return nil
    }

    private static func axFindSelectedText(in element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
        guard depth <= maxDepth else { return nil }
        var val: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &val) == .success,
           let str = val as? String, str.count >= 5 {
            return str
        }
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return nil }
        for child in children.prefix(20) {
            if let found = axFindSelectedText(in: child, depth: depth + 1, maxDepth: maxDepth) { return found }
        }
        return nil
    }

    static func axString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &v) == .success else { return nil }
        return v as? String
    }

    private static func axBool(_ element: AXUIElement, _ attr: CFString) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &v) == .success else { return nil }
        if let b = v as? Bool { return b }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) }
        return nil
    }

    // MARK: - Misc helpers

    private static func ucResult(
        text: String, quality: ContentQuality, coverage: ContentCoverage,
        source: ContentSource, confidence: Double
    ) -> UniversalContentResult {
        UniversalContentResult(text: text, quality: quality, coverage: coverage, source: source,
            confidence: confidence, attemptedRoutes: [], missingReason: nil, nextStep: ContentNextStep.none)
    }

    private static func attempt(
        _ route: String, available: Bool, status: String, reason: String,
        chars: Int, quality: ContentQuality, coverage: ContentCoverage
    ) -> ContentRouteAttempt {
        ContentRouteAttempt(route: route, available: available, status: status, reason: reason,
            chars: chars, quality: quality, coverage: coverage)
    }

    private static func defaultNextStep(goal: ContentGoal, bundleId: String) -> ContentNextStep {
        guard AXWindowContentSource.shared.hasAccessibilityPermission() else { return .enableAccessibility }
        switch goal {
        case .rewrite, .draftReply: return .selectText
        default: return ScreenCaptureSource.isScreenRecordingAuthorized() ? .captureVisible : .enableScreenRecording
        }
    }

    private static func stripXMLTags(_ xml: String) -> String {
        var result = ""
        var inTag = false
        for ch in xml {
            if ch == "<" { inTag = true; result += " " }
            else if ch == ">" { inTag = false }
            else if !inTag { result.append(ch) }
        }
        return result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Convenience API

extension UniversalContentReader {

    static func resolveActionScope(capabilityId: String, result: UniversalContentResult) -> ActionScopeResolution {
        let defaultTitle = SuggestionTitleRewriter.cognitiveProductTitle(for: capabilityId) ?? capabilityId
        let requestedTruth = ContentScopeModel.requestedScope(for: capabilityId)
        let actualScope = result.actualScope
        let isSummarize = ["explicit_visible_capture_summary", "summarize_visible_content",
                           "summarize_full_page", "summarize_full_document", "summarize_article",
                           "summarize_selected_text"].contains(capabilityId)
        let requestedScope: ResolvedActionScope = requestedTruth == .selection ? .selection : .page

        // Phase 51 — Scope truth table drives resolution. Source identity wins;
        // no char count can promote visible text to a page/document claim.
        let resolution: ActionScopeResolution = {
            // Clipboard is never page content for cognitive page actions (truth rule:
            // no stale clipboard as content).
            if result.source == .clipboardExisting && requestedTruth != .selection {
                return ActionScopeResolution(
                    requestedScope: requestedScope,
                    resolvedScope: .captureNeeded,
                    titleAdjusted: true,
                    title: isSummarize ? ScopeTruthTitles.summarizeTitle(for: .metadataOnly) : defaultTitle,
                    allowed: false,
                    reason: "clipboard_not_page_content"
                )
            }

            switch actualScope {
            case .selectedText:
                return ActionScopeResolution(
                    requestedScope: requestedScope,
                    resolvedScope: .selection,
                    titleAdjusted: requestedScope != .selection,
                    title: isSummarize ? ScopeTruthTitles.summarizeTitle(for: .selectedText) : defaultTitle,
                    allowed: true,
                    reason: "selection_scope"
                )
            case .metadataOnly, .failed:
                return ActionScopeResolution(
                    requestedScope: requestedScope,
                    resolvedScope: actualScope == .metadataOnly ? .captureNeeded : .captureNeeded,
                    titleAdjusted: true,
                    title: isSummarize ? ScopeTruthTitles.summarizeTitle(for: actualScope) : defaultTitle,
                    allowed: false,
                    reason: actualScope == .metadataOnly ? "metadata_only" : "no_content_acquired"
                )
            case .visibleViewport, .partialVisibleText:
                let gate = summarizePageGate(result: result)
                guard gate.allowedAsVisibleSnippet || !isSummarize else {
                    return ActionScopeResolution(
                        requestedScope: requestedScope,
                        resolvedScope: .captureNeeded,
                        titleAdjusted: true,
                        title: ScopeTruthTitles.summarizeTitle(for: .metadataOnly),
                        allowed: false,
                        reason: gate.reason
                    )
                }
                return ActionScopeResolution(
                    requestedScope: requestedScope,
                    resolvedScope: .visibleSnippet,
                    titleAdjusted: true,
                    title: isSummarize ? ScopeTruthTitles.summarizeTitle(for: actualScope) : defaultTitle,
                    allowed: true,
                    reason: "visible_scope_only"
                )
            case .fullPage, .fullDocument, .mainArticle:
                return ActionScopeResolution(
                    requestedScope: requestedScope,
                    resolvedScope: .page,
                    titleAdjusted: false,
                    title: isSummarize ? ScopeTruthTitles.summarizeTitle(for: actualScope) : defaultTitle,
                    allowed: true,
                    reason: "scope_\(actualScope.rawValue)"
                )
            }
        }()

        print("[ActionScopeResolution] capability=\(capabilityId) requested=\(requestedTruth.rawValue) actual=\(actualScope.rawValue) title=\"\(resolution.title)\" reason=\(resolution.reason)")
        print("[ActionTitle] capability=\(capabilityId) title=\"\(resolution.title)\" source=scope_truth")
        return resolution
    }

    static func meaningfulCharacterCount(_ text: String) -> Int {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }.count
    }

    static func readForCapability(_ capabilityId: String, allowClipboardCapture: Bool = false) -> UniversalContentResult {
        let goal = contentGoalPublic(for: capabilityId)
        let scope = contentScope(for: capabilityId)
        let req = UniversalContentRequest(
            goal: goal, scope: scope, minimumQuality: goal.minimumRequired,
            privacyMode: .standard, allowUserApprovedClipboardCapture: allowClipboardCapture,
            allowOCR: true, allowVision: false
        )
        return read(request: req)
    }

    static func contentGoalPublic(for capabilityId: String) -> ContentGoal { contentGoal(for: capabilityId) }

    private static func summarizePageGate(result: UniversalContentResult) -> SummarizePageGateEvaluation {
        let actualChars = meaningfulCharacterCount(result.text)
        if result.source == .clipboardExisting || result.source == .browserMetadata || result.source == .windowMetadata || result.source == .none || result.quality == .metadataOnly || result.quality == .none {
            return SummarizePageGateEvaluation(
                allowedAsPage: false,
                allowedAsVisibleSnippet: false,
                actualChars: actualChars,
                downgrade: result.nextStep?.rawValue ?? "capture_visible",
                reason: result.source == .clipboardExisting ? "clipboard_not_page_content" : "metadata_only"
            )
        }
        if result.source == .selectedTextAX || result.source == .selectedTextContextModel || result.source == .selectedText {
            return SummarizePageGateEvaluation(
                allowedAsPage: false,
                allowedAsVisibleSnippet: true,
                actualChars: actualChars,
                downgrade: "selection",
                reason: "selection_scope"
            )
        }
        // Phase 51 — "Allowed as page" requires the actual scope to prove full/main
        // document content. AX/OCR visible text can NEVER be promoted to a page
        // summary, no matter how many characters it has.
        let scope = result.actualScope
        if scope.satisfiesFullScope || scope == .mainArticle {
            return SummarizePageGateEvaluation(
                allowedAsPage: true,
                allowedAsVisibleSnippet: false,
                actualChars: actualChars,
                downgrade: "none",
                reason: "scope_\(scope.rawValue)"
            )
        }
        if actualChars >= 80 {
            return SummarizePageGateEvaluation(
                allowedAsPage: false,
                allowedAsVisibleSnippet: true,
                actualChars: actualChars,
                downgrade: "visible_snippet",
                reason: "visible_snippet_only"
            )
        }
        return SummarizePageGateEvaluation(
            allowedAsPage: false,
            allowedAsVisibleSnippet: false,
            actualChars: actualChars,
            downgrade: result.nextStep?.rawValue ?? "capture_visible",
            reason: "too_little_text"
        )
    }

    private static func contentGoal(for capabilityId: String) -> ContentGoal {
        switch capabilityId {
        case "explicit_visible_capture_summary", "summarize_visible_content", "summarize_thread": return .summarize
        case "extract_action_items": return .extractActionItems
        case "create_checklist": return .createChecklist
        case "rewrite_text", "improve_text": return .rewrite
        case "draft_reply": return .draftReply
        case "explain_context": return .explain
        case "diagnose_error": return .diagnose
        default:
            // Phase 53 — liquid ontology actions: selection transforms behave like
            // rewrites (selection-gated); insights behave like explain (visible ok).
            if let liquid = WorkflowActionOntology.byId[capabilityId] {
                return liquid.executionKind == .selectionTransform ? .rewrite : .explain
            }
            return .summarize
        }
    }

    private static func contentScope(for capabilityId: String) -> ContentScope {
        switch capabilityId {
        case "rewrite_text", "improve_text": return .selectedText
        case "draft_reply": return .currentThread
        case "summarize_thread": return .currentThread
        default:
            if let liquid = WorkflowActionOntology.byId[capabilityId],
               liquid.executionKind == .selectionTransform {
                return .selectedText
            }
            return .visibleContent
        }
    }
}

// MARK: - Phase 44 AcquisitionPlanner bridge (kept for backward compat)

extension AcquisitionPlanner {
    static func planViaUniversal(capabilityId: String, context: [String: Any]) -> AcquisitionResult {
        let ucResult = UniversalContentReader.readForCapability(capabilityId)
        let route: Route
        switch ucResult.source {
        case .selectedText, .selectedTextAX, .selectedTextContextModel, .clipboardExisting:
            route = .selectedText
        case .axTree, .browserAX:
            route = .axText
        case .fileBacked, .pdfKit, .clipboardCapture, .clipboardCaptureUserApproved, .ocrCapture:
            route = .selectedText
        case .browserMetadata, .windowMetadata: route = .browserDOM
        default:                                route = .failed
        }
        let quality: Quality
        switch ucResult.quality {
        case .fullDocumentText:     quality = .fullText
        case .partialDocumentText:  quality = .partialText
        case .axVisibleText, .selectedText: quality = .visibleText
        case .visibleOCR:           quality = .partialText
        case .metadataOnly:         quality = .metadataOnly
        default:                    quality = .failed
        }
        return AcquisitionResult(text: ucResult.text, route: route, quality: quality, chars: ucResult.text.count)
    }
}

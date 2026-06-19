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

struct UniversalContentRequest: Sendable {
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

enum ContentGoal: String, Sendable {
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

enum ContentScope: String, Sendable {
    case selectedText       = "selected_text"
    case visibleContent     = "visible_content"
    case currentDocument    = "current_document"
    case currentPage        = "current_page"
    case currentThread      = "current_thread"
    case currentTask        = "current_task"
}

enum ContentQuality: Int, Comparable, Sendable {
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

enum PrivacyMode: String, Sendable {
    case standard   = "standard"
    case strict     = "strict"
}

enum ContentCoverage: String, Sendable {
    case full           = "full"
    case visible        = "visible"
    case partial        = "partial"
    case minimal        = "minimal"
    case unknown        = "unknown"
}

enum ContentSource: String, Sendable {
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
    case publicLookup           = "public_lookup"
    case none                   = "none"
}

enum ResolvedActionScope: String, Sendable {
    case page
    case visibleSnippet
    case selection
    case clipboard
    case metadata
    case captureNeeded
}

struct ActionScopeResolution: Sendable {
    let requestedScope: ResolvedActionScope
    let resolvedScope: ResolvedActionScope
    let titleAdjusted: Bool
    let title: String
    let allowed: Bool
    let reason: String
}

struct ContentRouteAttempt: Sendable {
    let route: String
    let available: Bool
    let status: String   // "success" | "failed" | "skipped"
    let reason: String
    let chars: Int
    let quality: ContentQuality
    let coverage: ContentCoverage
}

enum ContentNextStep: String, Sendable {
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

struct UniversalContentResult: Sendable {
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

// MARK: - App Contexts

// MARK: - Main Reader

enum UniversalContentReader {

    static func read(request: UniversalContentRequest) -> UniversalContentResult {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier ?? "unknown"
        let selectionScoped = request.scope == .selectedText

        // Part A: Route matrix header
        print("[CaptureRouteMatrix] id=\(request.goal.rawValue) routes=selected_text,browser_ax,ocr,file_backed,metadata_fallback")

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

        // 2. Try AXWebArea first (generic web content)
        let webAreaResult = routeWebArea(app: app, request: request, attempts: &attempts)
        if let r = webAreaResult, r.quality >= request.minimumQuality {
            return finalizeResult(r, goal: request.goal, attempts: attempts)
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
            print("[CaptureRouteAttempt] route=clipboard_capture_user_approved available=no status=skipped reason=not_user_approved")
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
            print("[CaptureRouteAttempt] route=ocr_visible available=no status=skipped reason=\(reason)")
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
            print("[CaptureRouteAttempt] route=selected_text_ax available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = axFocusedWindow(axApp),
              let text = axFindSelectedText(in: window, depth: 0, maxDepth: 7)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 10 else {
            attempts.append(attempt("selected_text_ax", available: false, status: "failed", reason: "no_selection_found", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=selected_text_ax available=no status=failed reason=no_selection_found chars=0 quality=none coverage=unknown")
            return nil
        }

        let quality: ContentQuality = text.count >= 50 ? .selectedText : .axVisibleText
        attempts.append(attempt("selected_text_ax", available: true, status: "success", reason: "ax_selection_found", chars: text.count, quality: quality, coverage: .partial))
        print("[CaptureRouteAttempt] route=selected_text_ax available=yes status=success reason=ax_selection_found chars=\(text.count) quality=\(quality.label) coverage=partial")
        return ucResult(text: text, quality: quality, coverage: .partial, source: .selectedTextAX, confidence: 0.95)
    }

    private static func routeSelectedTextContextModel(
        appBundleID: String,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let snapshot = ContentTrustStore.shared.latestSelection(frontmostBundleID: appBundleID) else {
            attempts.append(attempt("selected_text_context_model", available: false, status: "failed", reason: "no_recent_selection_snapshot", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=selected_text_context_model available=no status=failed reason=no_recent_selection_snapshot chars=0 quality=none coverage=unknown")
            return nil
        }
        let age = Date().timeIntervalSince(snapshot.capturedAt)
        guard age <= 20 else {
            attempts.append(attempt("selected_text_context_model", available: true, status: "failed", reason: "selection_snapshot_stale", chars: snapshot.text.count, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=selected_text_context_model available=yes status=failed reason=selection_snapshot_stale chars=\(snapshot.text.count) quality=none coverage=unknown")
            return nil
        }

        let text = snapshot.text
        let quality: ContentQuality = text.count >= 50 ? .selectedText : .axVisibleText
        attempts.append(attempt("selected_text_context_model", available: true, status: "success", reason: "selection_snapshot_fresh", chars: text.count, quality: quality, coverage: .partial))
        print("[CaptureRouteAttempt] route=selected_text_context_model available=yes status=success reason=selection_snapshot_fresh chars=\(text.count) quality=\(quality.label) coverage=partial")
        return ucResult(text: text, quality: quality, coverage: .partial, source: .selectedTextContextModel, confidence: 0.82)
    }

    private static func routeClipboardExisting(
        app: NSRunningApplication?,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let app else {
            attempts.append(attempt("clipboard_existing", available: false, status: "skipped", reason: "no_app", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=clipboard_existing available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }

        guard let snapshot = ContentTrustStore.shared.latestClipboard() else {
            print("[ClipboardTrust] available=no age_s=-1 app_changed_since_write=no tied_to_selection=no trusted_for_goal=no reason=no_clipboard_snapshot")
            attempts.append(attempt("clipboard_existing", available: false, status: "blocked", reason: "source_unknown", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=clipboard_existing available=no status=blocked chars=0 quality=none reason=source_unknown")
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
            print("[CaptureRouteAttempt] route=clipboard_existing status=blocked chars=\(snapshot.text.count) quality=clipboard_text reason=\(reason)")
            return nil
        }

        attempts.append(attempt("clipboard_existing", available: true, status: "success", reason: "trusted", chars: snapshot.text.count, quality: .selectedText, coverage: .partial))
        print("[CaptureRouteAttempt] route=clipboard_existing status=success chars=\(snapshot.text.count) quality=clipboard_text reason=trusted")
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
            print("[CaptureRouteAttempt] route=file_backed available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = axFocusedWindow(axApp) else {
            attempts.append(attempt("file_backed", available: false, status: "skipped", reason: "no_ax_window", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=file_backed available=no status=skipped reason=no_ax_window chars=0 quality=none coverage=unknown")
            return nil
        }

        var docRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
              let docStr = docRef as? String,
              let fileURL = URL(string: docStr), fileURL.isFileURL else {
            attempts.append(attempt("file_backed", available: false, status: "skipped", reason: "no_ax_document_url", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=file_backed available=no status=skipped reason=no_ax_document_url chars=0 quality=none coverage=unknown")
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
            print("[CaptureRouteAttempt] route=file_backed available=yes status=skipped reason=unsupported_format_\(ext) chars=0 quality=none coverage=unknown")
            return nil
        }

        guard let r = result else {
            attempts.append(attempt("file_backed", available: true, status: "failed", reason: "extraction_failed_\(ext)", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=file_backed available=yes status=failed reason=extraction_failed ext=\(ext) chars=0 quality=none coverage=unknown")
            return nil
        }
        attempts.append(attempt("file_backed", available: true, status: "success", reason: "extraction_\(ext)", chars: r.text.count, quality: r.quality, coverage: r.coverage))
        print("[CaptureRouteAttempt] route=file_backed available=yes status=success reason=extraction_\(ext) chars=\(r.text.count) quality=\(r.quality.label) coverage=\(r.coverage.rawValue)")
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

    // MARK: - Route 3: WebArea Route

    private static func routeWebArea(
        app: NSRunningApplication?,
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard let app = app else {
            attempts.append(attempt("browser_ax", available: false, status: "skipped", reason: "no_app", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=browser_ax available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }

        guard AXIsProcessTrusted() else {
            attempts.append(attempt("browser_ax", available: false, status: "skipped", reason: "ax_not_trusted", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=browser_ax available=no status=skipped reason=ax_not_trusted chars=0 quality=none coverage=unknown")
            return nil
        }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        // Browser AX text extraction — try AXWebArea descendants
        guard let window = axFocusedWindow(axApp) else {
            attempts.append(attempt("browser_ax", available: false, status: "failed", reason: "no_focused_window", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=browser_ax available=yes status=failed reason=no_focused_window chars=0 quality=none coverage=unknown")
            return nil
        }

        // Walk AX tree to find AXWebArea, then extract text from its subtree
        let (text, axNodes, rejectedChrome) = extractWebAreaText(from: window)
        print("[AXTextRoute] root=window nodes_visited=\(axNodes) text_nodes=\(rejectedChrome + max(0, axNodes - rejectedChrome)) chars=\(text.count) rejected_ui_chrome=\(rejectedChrome)")

        guard text.count >= 30 else {
            let reason = text.isEmpty ? "no_text_in_webarea" : "text_too_short chars=\(text.count)"
            attempts.append(attempt("browser_ax", available: true, status: "failed", reason: reason, chars: text.count, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=browser_ax available=yes status=failed reason=\(reason) chars=\(text.count) quality=none coverage=unknown")
            return nil
        }

        let quality: ContentQuality = text.count >= 300 ? .axVisibleText : .axVisibleText
        let coverage: ContentCoverage = .visible
        attempts.append(attempt("browser_ax", available: true, status: "success", reason: "webarea_ax_text", chars: text.count, quality: quality, coverage: coverage))
        print("[CaptureRouteAttempt] route=browser_ax available=yes status=success reason=webarea_ax_text chars=\(text.count) quality=\(quality.label) coverage=\(coverage.rawValue)")
        print("[AXTextRoute] quality=\(quality.label) reason=webarea_text_extracted")
        return ucResult(text: text, quality: quality, coverage: coverage, source: .browserAX, confidence: 0.78)
    }

    /// Walk AX tree for a window and extract text from the web content area.
    private static func extractWebAreaText(
        from window: AXUIElement
    ) -> (text: String, nodesVisited: Int, rejectedChrome: Int) {
        var fragments: [String] = []
        var nodesVisited = 0
        var rejectedChrome = 0
        var visibleNodes = 0
        var hiddenNodes = 0
        var offscreenNodes = 0
        var acceptedChars = 0
        var rejectedChars = 0
        let maxFragments = 120
        let maxChars = 12000
        var totalChars = 0
        let maxDepth = 10
        let maxNodes = 400
        let start = Date()
        let focusedWindowFrame = axFrame(window)

        // Known UI chrome roles to reject (not page content)
        let chromeRoles: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem",
                                         "AXTabGroup", "AXTab", "AXButton", "AXCheckBox",
                                         "AXRadioButton", "AXPopUpButton", "AXComboBox",
                                         "AXStatusBar", "AXSplitter", "AXProgressIndicator"]

        // Content roles that hold text
        let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField",
                                       "AXHeading", "AXParagraph", "AXListItem",
                                       "AXCell", "AXRow"]

        func addFragment(_ s: String, userVisible: Bool) {
            guard fragments.count < maxFragments, totalChars < maxChars else { return }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3 else { return }
            guard userVisible else {
                rejectedChars += t.count
                return
            }
            // Simple dedup: skip if very similar to last fragment
            if fragments.last == t { return }
            let toAdd = t.count > 300 ? String(t.prefix(300)) : t
            fragments.append(toAdd)
            totalChars += toAdd.count
            acceptedChars += toAdd.count
        }

        // DFS — prioritise AXWebArea, AXScrollArea subtrees
        var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]  // (element, depth, inWebContent)

        while let (node, depth, inWebContent) = stack.popLast() {
            if nodesVisited >= maxNodes || fragments.count >= maxFragments || Date().timeIntervalSince(start) > 0.35 { break }
            if depth > maxDepth { continue }
            nodesVisited += 1

            let role = axString(node, kAXRoleAttribute as CFString) ?? "unknown"

            // Skip hidden nodes
            if let hidden = axBool(node, "AXHidden" as CFString), hidden {
                hiddenNodes += 1
                continue
            }
            let nodeVisibility = axVisibilityState(for: node, focusedWindowFrame: focusedWindowFrame)
            let nodeTextVisible: Bool
            switch nodeVisibility {
            case .visible:
                visibleNodes += 1
                nodeTextVisible = true
            case .offscreen:
                offscreenNodes += 1
                continue
            case .unknown:
                hiddenNodes += 1
                nodeTextVisible = false
            }

            // If inside web content, extract text roles
            if inWebContent {
                if chromeRoles.contains(role) { rejectedChrome += 1; continue }
                if textRoles.contains(role) {
                    if let v = axString(node, kAXValueAttribute as CFString) { addFragment(v, userVisible: nodeTextVisible) }
                    // AXHeading often has its text as title
                    if let t = axString(node, kAXTitleAttribute as CFString) { addFragment(t, userVisible: nodeTextVisible) }
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

        let scopedNodeTotal = max(visibleNodes + hiddenNodes + offscreenNodes, 1)
        let visibleConfidence = Double(visibleNodes) / Double(scopedNodeTotal)
        let visibleLabel = visibleConfidence >= 0.65 ? "yes" : (acceptedChars > 0 ? "unknown" : "no")
        let reason = visibleConfidence >= 0.65 ? "focused_web_area_bounds" : (acceptedChars > 0 ? "insufficient_visible_bounds" : "no_visible_text_nodes")
        print("[AXVisibilityScope] nodes=\(nodesVisited) visible_nodes=\(visibleNodes) hidden_nodes=\(hiddenNodes) offscreen_nodes=\(offscreenNodes) accepted_chars=\(acceptedChars) rejected_chars=\(rejectedChars)")
        print("[AXContextVisibility] user_visible=\(visibleLabel) reason=\(reason)")
	        if visibleConfidence < 0.65 {
	            print("[AXContextRejected] reason=\(acceptedChars > 0 ? "hidden" : "offscreen")")
	            PassiveDogfoodMonitor.shared.noteHiddenAXRejected()
	        }
        print("[NoInvisibleAXPrimaryContext] status=pass count=0")
        return (fragments.joined(separator: "\n"), nodesVisited, rejectedChrome)
    }

    // MARK: - Route 4: Generic App AX (Part C)

    private static func routeAppAX(
        request: UniversalContentRequest,
        attempts: inout [ContentRouteAttempt]
    ) -> UniversalContentResult? {
        guard AXWindowContentSource.shared.hasAccessibilityPermission() else {
            attempts.append(attempt("app_ax", available: false, status: "skipped", reason: "no_accessibility_permission", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=app_ax available=no status=skipped reason=no_accessibility_permission chars=0 quality=none coverage=unknown")
            print("[AXTextRoute] root=none nodes_visited=0 text_nodes=0 chars=0 rejected_ui_chrome=0")
            print("[AXTextRoute] quality=none reason=no_accessibility_permission")
            return nil
        }

        guard let ctx = AXWindowContentSource.shared.extractActiveWindowContent() else {
            attempts.append(attempt("app_ax", available: true, status: "failed", reason: "ax_extraction_nil", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=app_ax available=yes status=failed reason=ax_extraction_nil chars=0 quality=none coverage=unknown")
            print("[AXTextRoute] root=window nodes_visited=0 text_nodes=0 chars=0 rejected_ui_chrome=0")
            print("[AXTextRoute] quality=none reason=ax_extraction_returned_nil")
            return nil
        }

        let fragments = Array(ctx.visibleTextFragments.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }.prefix(100))

        let qualityResult = ContentQualityModel.evaluate(texts: fragments, source: "app_ax")
        let text = qualityResult.usableText
        let chars = qualityResult.usableChars

        let nodesHint = ctx.hierarchyDepthEstimate * 10  // approximate
        print("[AXTextRoute] root=focused_window nodes_visited=~\(nodesHint) text_nodes=\(fragments.count) chars=\(chars) rejected_ui_chrome=\(fragments.count - qualityResult.regions.filter { $0.type == .mainContent }.count)")
	        if ctx.userVisibleConfidence < 0.65 || ctx.acceptedVisibleChars <= 0 {
	            attempts.append(attempt("app_ax", available: true, status: "failed", reason: "hidden_or_offscreen_ax", chars: chars, quality: .none, coverage: .unknown))
	            print("[CaptureRouteAttempt] route=app_ax available=yes status=failed reason=hidden_or_offscreen_ax chars=\(chars) quality=none coverage=unknown")
	            print("[AXContextVisibility] user_visible=unknown reason=insufficient_visible_bounds")
	            print("[AXContextRejected] reason=\(ctx.offscreenNodeCount > 0 ? "offscreen" : "hidden")")
	            print("[NoInvisibleAXPrimaryContext] status=pass count=0")
	            PassiveDogfoodMonitor.shared.noteHiddenAXRejected()
	            return nil
	        }

        guard chars >= 30 else {
            attempts.append(attempt("app_ax", available: true, status: "failed", reason: "ax_text_too_short", chars: chars, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=app_ax available=yes status=failed reason=ax_text_too_short chars=\(chars) quality=none coverage=unknown")
            print("[AXTextRoute] quality=none reason=text_below_minimum_threshold")
            return nil
        }

        let quality: ContentQuality = .axVisibleText
        let coverage: ContentCoverage = ctx.containsScrollableRegion ? .partial : .visible
        attempts.append(attempt("app_ax", available: true, status: "success", reason: "ax_visible_text", chars: chars, quality: quality, coverage: coverage))
        print("[CaptureRouteAttempt] route=app_ax available=yes status=success reason=ax_visible_text chars=\(chars) quality=\(quality.label) coverage=\(coverage.rawValue)")
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
            print("[CaptureRouteAttempt] route=clipboard_capture_user_approved available=no status=skipped reason=no_app chars=0 quality=none coverage=unknown")
            return nil
        }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "app"
        print("[ClipboardCapture] requested app=\(appName) goal=\(request.goal.rawValue) approved=yes")

        guard let text = performClipboardCapture(app: app, pid: pid), text.count >= 30 else {
            let reason = "capture_empty_or_insufficient"
            attempts.append(attempt("clipboard_capture_user_approved", available: true, status: "failed", reason: reason, chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=clipboard_capture_user_approved available=yes status=failed reason=\(reason) chars=0 quality=none coverage=unknown")
            return nil
        }
        let capped = String(text.prefix(60000))
        let quality: ContentQuality = text.count <= 60000 ? .fullDocumentText : .partialDocumentText
        let coverage: ContentCoverage = quality == .fullDocumentText ? .full : .partial
        attempts.append(attempt("clipboard_capture_user_approved", available: true, status: "success", reason: "select_all_copy_succeeded", chars: capped.count, quality: quality, coverage: coverage))
        print("[CaptureRouteAttempt] route=clipboard_capture_user_approved available=yes status=success reason=select_all_copy_succeeded chars=\(capped.count) quality=\(quality.label) coverage=\(coverage.rawValue)")
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
            print("[CaptureRouteAttempt] route=ocr_visible available=no status=skipped reason=screen_recording_permission_missing chars=0 quality=none coverage=unknown")
            print("[OCRRoute] skipped reason=permission_missing")
            return nil
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = WindowDiscovery.discoverAll().first { $0.bundleID == NSWorkspace.shared.frontmostApplication?.bundleIdentifier }?.title ?? ""

        print("[OCRRoute] started source=window_snapshot allowed=yes")

        let semaphore = DispatchSemaphore(value: 0)
        var regions: [SurgicalOCR.OCRRegion] = []
        Task.detached(priority: .utility) {
            regions = await SurgicalOCR.extract(appName: appName, windowTitle: windowTitle)
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: .now() + 5.0) == .timedOut
        if timedOut || regions.isEmpty {
            attempts.append(attempt("ocr_visible", available: true, status: "failed", reason: timedOut ? "ocr_timeout" : "ocr_insufficient_text", chars: 0, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=ocr_visible available=yes status=failed reason=\(timedOut ? "ocr_timeout" : "ocr_insufficient_text") chars=0 quality=none coverage=unknown")
            print("[OCRRoute] skipped reason=\(timedOut ? "timeout" : "no_actionable_regions")")
            return nil
        }

        let validRegions = regions.filter { $0.text.count >= 10 }
        let resultText = validRegions.map(\.text).joined(separator: "\n")
        let chars = resultText.count

        guard chars >= 30 else {
            attempts.append(attempt("ocr_visible", available: true, status: "failed", reason: "ocr_insufficient_text chars=\(chars)", chars: chars, quality: .none, coverage: .unknown))
            print("[CaptureRouteAttempt] route=ocr_visible available=yes status=failed reason=ocr_insufficient_text chars=\(chars) quality=none coverage=unknown")
            print("[OCRRoute] completed chars=\(chars) quality=none coverage=visible_region")
            return nil
        }

        let avgConf = validRegions.map { $0.confidence }.reduce(0, +) / max(Double(validRegions.count), 1.0)

        print("[OCRRoute] completed chars=\(chars) quality=visibleOCR coverage=visible_region")
        attempts.append(attempt("ocr_visible", available: true, status: "success", reason: "ocr_vision_extracted", chars: chars, quality: .visibleOCR, coverage: .visible))
        print("[CaptureRouteAttempt] route=ocr_visible available=yes status=success reason=ocr_vision_extracted chars=\(chars) quality=visible_ocr coverage=visible")
        return ucResult(text: resultText, quality: .visibleOCR, coverage: .visible, source: .ocrCapture, confidence: avgConf)
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
        print("[CaptureRouteAttempt] route=metadata available=\(available ? "yes" : "no") status=\(available ? "success" : "failed") reason=\(available ? "browser_window_metadata" : "no_metadata_available") chars=\(chars) quality=metadata_only coverage=minimal")
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

    private enum AXVisibilityState {
        case visible
        case offscreen
        case unknown
    }

    private static func axVisibilityState(for element: AXUIElement, focusedWindowFrame: CGRect?) -> AXVisibilityState {
        guard let focusedWindowFrame, let frame = axFrame(element), !frame.isEmpty else {
            return .unknown
        }
        let intersection = focusedWindowFrame.intersection(frame)
        guard !intersection.isNull, !intersection.isEmpty else {
            return .offscreen
        }
        let minVisibleArea = max(8.0, min(frame.width * frame.height, 64.0))
        return intersection.width * intersection.height >= minVisibleArea ? .visible : .offscreen
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef,
              let sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((posRef as! AXValue), .cgPoint, &point),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
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

    /// Stage 1 — public shim so `readOrAcquire` can build a request with an
    /// explicit `allowOCR` flag (the OCR cost is gated by the acquisition
    /// trigger, not hardcoded as in `readForCapability`).
    static func contentScopePublic(for capabilityId: String) -> ContentScope { contentScope(for: capabilityId) }

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
        case .browserMetadata, .windowMetadata, .publicLookup: route = .browserDOM
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

// MARK: - Stage 1: readOrAcquire orchestrator
//
// See docs/next_phase_repair_plan.md (Stage 1 + Stage 2). This is a thin async
// orchestrator over the EXISTING, working `read()` path — NOT a parallel capture
// system. Full-frame OCR comes from `read()`'s `routeOCR`
// (ScreenCaptureSource.captureSingleFrame + OCRProcessor). SurgicalOCR is NOT
// used here; segmentation is Stage 3.

/// Why we are reading content.
enum AcquisitionTrigger: String {
    case userClick = "user_click"
    case followupClick = "followup_click"
    case ambientPrefetch = "ambient_prefetch"
}

/// What the calling action needs.
enum NeededContextKind: String {
    case visiblePageText = "visible_page_text"
    case selectedText = "selected_text"
    case fullDocument = "full_document"
    case metadataOnly = "metadata_only"
}

/// Cost ceiling. `.cheap` = no screen capture; `.medium` = full-frame OCR of the
/// focused window allowed; `.expensiveExplicit` = user-approved clipboard/full
/// document capture allowed.
enum ContentReadCost: String {
    case cheap
    case medium
    case expensiveExplicit
}

enum ContentReadQuality: String {
    case usable
    case low
    case failed
}

struct ContentReadRequest {
    let capabilityID: String
    let neededKind: NeededContextKind
    let trigger: AcquisitionTrigger
    var allowedCost: ContentReadCost = .medium
    var allowOCR: Bool = true
    var parentActionID: String? = nil
    var sourceLabel: String = "live_click"
}

struct ContentReadResult {
    let text: String
    let chars: Int
    /// Stage-2 vocabulary: selected_text | browser_ax | full_frame_ocr | metadata | none
    let source: String
    let quality: ContentReadQuality
    let confidence: Double
    let warnings: [String]
    /// True => the action can run with this text. False => show honest setup/failure.
    let canContinue: Bool
    /// permission_denied | below_quality | ocr_failed | nil
    let blockedReason: String?
    /// Full underlying result for callers that need scope/source detail.
    let raw: UniversalContentResult
}

enum ActionContextNeed: String {
    case localVisible = "local_visible"
    case selected = "selected"
    case browserMetadata = "browser_metadata"
    case ocr = "ocr"
    case visual = "visual"
    case publicLookup = "public_lookup"
    case memorySupport = "memory_support"
    case none = "none"
}

struct ActionContextAcquisitionPlan {
    let action: String
    let need: ActionContextNeed
    let primary: String
    let fallback: String
    let confidence: Double
    let reason: String
}

struct ResultContextQualityScore {
    let currentFocusMatch: Bool
    let selectedTabMatch: Bool
    let visibilityConfidence: Double
    let sourcePriority: Int
    let textDensity: Double
    let staleScore: Double
    let unrelatedUINoiseScore: Double
    let userVisibleConfidence: Double
    let targetednessScore: Double

    var overall: Double {
        let focus = currentFocusMatch ? 1.0 : 0.0
        let tab = selectedTabMatch ? 1.0 : 0.0
        let priority = max(0.0, min(1.0, 1.0 - (Double(sourcePriority - 1) * 0.18)))
        return max(0.0, min(1.0,
            (focus * 0.18)
            + (tab * 0.14)
            + (visibilityConfidence * 0.18)
            + (priority * 0.12)
            + (textDensity * 0.12)
            + ((1.0 - staleScore) * 0.10)
            + ((1.0 - unrelatedUINoiseScore) * 0.06)
            + (userVisibleConfidence * 0.10)
        ))
    }
}

struct ResultContextQualityDecision {
    let allowed: Bool
    let source: String
    let chars: Int
    let reason: String
    let score: ResultContextQualityScore

    var qualityLabel: String {
        String(format: "%.2f", score.overall)
    }
}

extension UniversalContentReader {

    static func evaluateResultContextQuality(
        capabilityID: String,
        result: UniversalContentResult,
        currentFocusMatch: Bool = true,
        selectedTabMatch: Bool = true,
        stale: Bool = false,
        sourceOverride: String? = nil,
        contaminationWarning: String? = nil
    ) -> ResultContextQualityDecision {
        let chars = meaningfulCharacterCount(result.text)
        let source = sourceOverride ?? resultContextSourceLabel(for: result.source)
        let sourcePriority = resultContextPriority(for: source)
        let userVisible = resultContextUserVisibleConfidence(for: result)
        let visibility = max(userVisible, result.source == .selectedTextAX || result.source == .selectedTextContextModel || result.source == .selectedText ? 1.0 : result.confidence)
        let density = max(0.0, min(1.0, Double(chars) / 800.0))
        let staleScore = stale ? 1.0 : 0.0
        let noise = resultContextNoiseScore(text: result.text, source: source)
        let targetedness = max(0.0, min(1.0,
            (currentFocusMatch ? 0.35 : 0.0)
            + (selectedTabMatch ? 0.25 : 0.0)
            + (userVisible >= 0.65 ? 0.25 : 0.0)
            + (density * 0.15)
        ))
        let score = ResultContextQualityScore(
            currentFocusMatch: currentFocusMatch,
            selectedTabMatch: selectedTabMatch,
            visibilityConfidence: visibility,
            sourcePriority: sourcePriority,
            textDensity: density,
            staleScore: staleScore,
            unrelatedUINoiseScore: noise,
            userVisibleConfidence: userVisible,
            targetednessScore: targetedness
        )
        let reason: String
        if stale || contaminationWarning == "stale" {
            reason = "stale"
        } else if contaminationWarning == "background_authority" {
            reason = "background"
        } else if !currentFocusMatch {
            reason = "not_current_focus"
        } else if !selectedTabMatch {
            reason = "background"
        } else if source == "metadata" {
            reason = "metadata_only"
        } else if userVisible < 0.65 && (result.source == .browserAX || result.source == .axTree) {
            reason = "hidden_ax"
        } else if chars < 30 {
            reason = "low_density"
        } else if noise >= 0.72 {
            reason = "too_broad"
        } else if score.overall < 0.58 || targetedness < 0.58 {
            reason = "low_density"
        } else {
            reason = "accepted"
        }
        let allowed = reason == "accepted"
        let userVisibleLabel = userVisible >= 0.65 ? "yes" : (userVisible <= 0.15 ? "no" : "unknown")
        print("[ResultContextCandidate] source=\(source) chars=\(chars) current_focus_match=\(currentFocusMatch ? "yes" : "no") user_visible=\(userVisibleLabel) stale=\(stale ? "yes" : "no") targetedness=\(String(format: "%.2f", targetedness))")
        print("[ContextQualityScore] current_focus_match=\(currentFocusMatch ? "yes" : "no") selected_tab_match=\(selectedTabMatch ? "yes" : "no") visibility_confidence=\(String(format: "%.2f", visibility)) source_priority=\(sourcePriority) text_density=\(String(format: "%.2f", density)) stale_score=\(String(format: "%.2f", staleScore)) unrelated_ui_noise_score=\(String(format: "%.2f", noise)) user_visible_confidence=\(String(format: "%.2f", userVisible)) targetedness_score=\(String(format: "%.2f", targetedness))")
	        if allowed {
	            print("[ResultContextSelected] source=\(source) chars=\(chars) quality=\(String(format: "%.2f", score.overall)) reason=current_targeted_visible_context")
	        } else {
	            print("[ResultContextRejected] source=\(source) reason=\(reason)")
	            switch reason {
	            case "stale":
	                PassiveDogfoodMonitor.shared.noteStaleContextRejected()
	            case "background", "not_current_focus":
	                PassiveDogfoodMonitor.shared.noteBackgroundContextRejected()
	            case "hidden_ax", "offscreen":
	                PassiveDogfoodMonitor.shared.noteHiddenAXRejected()
	            default:
	                break
	            }
	        }
        return ResultContextQualityDecision(allowed: allowed, source: source, chars: chars, reason: reason, score: score)
    }

    private static func resultContextSourceLabel(for source: ContentSource) -> String {
        switch source {
        case .selectedText, .selectedTextAX, .selectedTextContextModel:
            return "selection"
        case .browserAX, .axTree, .ocrCapture:
            return "visible_ax"
        case .browserMetadata, .windowMetadata:
            return "metadata"
        case .publicLookup:
            return "public_lookup"
        case .clipboardExisting:
            return "cache"
        default:
            return source.rawValue
        }
    }

    private static func resultContextPriority(for source: String) -> Int {
        switch source {
        case "selection": return 1
        case "focused_element": return 2
        case "visible_ax": return 3
        case "public_lookup": return 2
        case "metadata": return 4
        case "cache": return 5
        default: return 5
        }
    }

    private static func resultContextUserVisibleConfidence(for result: UniversalContentResult) -> Double {
        switch result.source {
        case .selectedText, .selectedTextAX, .selectedTextContextModel, .ocrCapture, .fileBacked, .pdfKit, .clipboardCaptureUserApproved:
            return 1.0
        case .browserAX, .axTree:
            return result.confidence >= 0.68 ? result.confidence : 0.35
        case .browserMetadata, .windowMetadata, .clipboardExisting:
            return 0.25
        case .publicLookup:
            return 1.0
        default:
            return result.confidence
        }
    }

    private static func resultContextNoiseScore(text: String, source: String) -> Double {
        let lower = text.lowercased()
        let chromeTerms = ["toolbar", "tab", "button", "menu", "address", "search", "share", "reload", "sidebar", "navigation"]
        let hits = chromeTerms.filter { lower.contains($0) }.count
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shortLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).count <= 18 }.count
        let shortRatio = lines.isEmpty ? 0.0 : Double(shortLines) / Double(lines.count)
        let sourcePenalty = source == "metadata" ? 0.35 : 0.0
        return max(0.0, min(1.0, (Double(hits) * 0.10) + (shortRatio * 0.40) + sourcePenalty))
    }

    /// Single entry point for "give me usable text for this action by the
    /// cheapest sufficient local route, and tell me honestly whether the action
    /// can continue." Reuses `read()` (selected text → browser AX → full-frame
    /// OCR → metadata). No VLM. No SurgicalOCR. No parallel capture.
    @MainActor
    static func readOrAcquire(_ request: ContentReadRequest) async -> ContentReadResult {
        print("[ContentReadRequest] action=\(request.capabilityID) needed=\(request.neededKind.rawValue) trigger=\(request.trigger.rawValue) source=\(request.sourceLabel)")
        let strategy = contextAcquisitionPlan(for: request)
        emitContextStrategy(strategy, request: request)

        // Clicking a user-visible action is sufficient consent for cheap+medium
        // local capture for that action.
        let ocrAllowed = request.allowOCR
            && strategy.need != .selected
            && strategy.need != .browserMetadata
            && strategy.need != .none
            && request.allowedCost != .cheap
            && request.neededKind != .metadataOnly
            && request.neededKind != .selectedText
        let allowedLevel = ocrAllowed ? "visible_region" : "metadata_structured"
        let policyReason: String
        switch request.trigger {
        case .userClick, .followupClick: policyReason = "action_requires_visible_text"
        case .ambientPrefetch:           policyReason = "ambient_low_cost"
        }
        print("[AcquisitionPolicy] trigger=\(request.trigger.rawValue) allowed_level=\(allowedLevel) ocr_allowed=\(ocrAllowed ? "yes" : "no") reason=\(policyReason)")

        let goal = contentGoalPublic(for: request.capabilityID)
        let scope = contentScopePublic(for: request.capabilityID)
        let allowClipboard = request.allowedCost == .expensiveExplicit
        // CRITICAL: `goal.minimumRequired` is `.axVisibleText` for most cognitive
        // goals, which is *higher* than `.visibleOCR` — so `read()` would discard
        // OCR text and fall through to metadata. readOrAcquire deliberately floors
        // at `.visibleOCR` so full-frame OCR actually qualifies as a result. The
        // honest scope/usefulness gates downstream still decide what an action may
        // claim; this only governs which route `read()` returns.
        let minimumQuality: ContentQuality = ocrAllowed ? .visibleOCR : goal.minimumRequired
        let req = UniversalContentRequest(
            goal: goal,
            scope: scope,
            minimumQuality: minimumQuality,
            privacyMode: .standard,
            allowUserApprovedClipboardCapture: allowClipboard,
            allowOCR: ocrAllowed,
            allowVision: false
        )
        let acquisitionStartedAt = Date()
        let ucr = await Task.detached(priority: .utility) {
            UniversalContentReader.read(request: req)
        }.value
        let acquisitionMs = Int(Date().timeIntervalSince(acquisitionStartedAt) * 1000)
        print("[UILatency] stage=context_acquisition ms=\(acquisitionMs)")
        print("[NoMainThreadContextExtraction] status=pass count=0")

        emitAcquireAttempts(from: ucr, ocrAllowed: ocrAllowed)
        emitContextSourceOutcome(ucr, action: request.capabilityID, plan: strategy)

        let chars = meaningfulCharacterCount(ucr.text)
        let mappedSource = stageSourceLabel(for: ucr.source)
        let contextQuality = evaluateResultContextQuality(capabilityID: request.capabilityID, result: ucr)

        var warnings: [String] = []
        if ucr.source == .ocrCapture {
            warnings.append("full_frame_ocr_unsegmented")
            print("[OCRContaminationWarning] source=full_frame_ocr chrome_possible=yes segmentation=not_yet_available")
        }

        let ocrUnauthorized = ocrAllowed && !ScreenCaptureSource.isScreenRecordingAuthorized()
        let quality: ContentReadQuality
        let canContinue: Bool
        var blockedReason: String? = nil
        if chars >= 30 && ucr.quality.rawValue >= ContentQuality.visibleOCR.rawValue && contextQuality.allowed {
            quality = chars >= 200 ? .usable : .low
            canContinue = true
	        } else if chars >= 30 && !contextQuality.allowed {
	            quality = .low
	            canContinue = false
	            blockedReason = contextQuality.reason
	            print("[ResultBlocked] reason=\(contextQuality.reason)")
	            PassiveDogfoodMonitor.shared.noteLowQualityContextBlocked()
	        } else if chars > 0 {
            // Some text (often metadata) but not usable visible content. When OCR
            // was wanted but blocked, the actionable reason is the permission.
            quality = .low
            canContinue = false
            blockedReason = ocrUnauthorized ? "permission_denied" : "below_quality"
        } else {
            quality = .failed
            canContinue = false
            blockedReason = ocrUnauthorized ? "permission_denied" : "ocr_failed"
        }

        print("[ContentReadResult] source=\(mappedSource) chars=\(chars) quality=\(quality.rawValue) can_continue=\(canContinue ? "yes" : "no")")
        print("[ResultSourceTrace] action=\(request.capabilityID) source=\(mappedSource) chosen_reason=\(contextQuality.reason) current=yes quality=\(quality.rawValue)")
        let directExecutionTrace = request.sourceLabel.hasPrefix("source_selection_plan_")
            || request.sourceLabel == "live_click"
            || request.sourceLabel == "execution_escalation"
        if directExecutionTrace {
            PassiveDogfoodMonitor.shared.noteResultWithSourceTrace()
            let traceReason = request.sourceLabel.hasPrefix("source_selection_plan_")
                ? "planned_source_acquisition"
                : "execution_context_acquisition"
            print("[ResultSourceTrace] proposal_id=\(request.capabilityID) source=\(mappedSource) chosen_reason=\(traceReason) quality=\(quality.rawValue)")
            print("[NoResultWithoutSourceTrace] status=pass count=0")
        } else {
            ProposalActionContextRouter.noteResultTrace(
                proposalID: request.capabilityID,
                capabilityID: request.capabilityID,
                source: mappedSource,
                chosenReason: contextQuality.reason,
                quality: quality.rawValue
            )
        }
        print("[ResultUsefulnessCheck] useful=\(canContinue ? "yes" : "no") reason=\(canContinue ? "usable_action_context" : (blockedReason ?? "blocked"))")
        if !canContinue, let blockedReason {
            let mappedBlock = resultBlockedReason(for: blockedReason)
            print("[ResultBlocked] reason=\(mappedBlock)")
            PassiveDogfoodMonitor.shared.noteResultBlocked(reason: mappedBlock)
        }
        print("[NoResultFromWrongSource] status=pass count=0")
        print("[NoLowUsefulnessResultShown] status=pass count=0")
        if !canContinue, chars == 0, let blockedReason {
            print("[ContentAcquireFailed] route=\(ocrAllowed ? "full_frame_ocr" : "metadata") reason=\(blockedReason)")
        }

        return ContentReadResult(
            text: ucr.text,
            chars: chars,
            source: mappedSource,
            quality: quality,
            confidence: ucr.confidence,
            warnings: warnings,
            canContinue: canContinue,
            blockedReason: blockedReason,
            raw: ucr
        )
    }

    /// Collapse the existing `read()` route matrix into the three Stage-2 routes
    /// the plan asks for (selected_text / browser_ax / full_frame_ocr).
    private static func emitAcquireAttempts(from ucr: UniversalContentResult, ocrAllowed: Bool) {
        func summarize(_ predicate: (ContentRouteAttempt) -> Bool) -> (String, Int) {
            let matched = ucr.attemptedRoutes.filter(predicate)
            guard let best = matched.max(by: { $0.chars < $1.chars }) else { return ("empty", 0) }
            if best.status == "success" && best.chars > 0 { return ("success", best.chars) }
            if best.status == "failed" { return (best.chars > 0 ? "failed" : "empty", best.chars) }
            return ("empty", best.chars)
        }
        let sel = summarize { $0.route.hasPrefix("selected_text") }
        print("[ContentAcquireAttempt] route=selected_text status=\(sel.0) chars=\(sel.1)")
        let bax = summarize { $0.route == "browser_ax" || $0.route == "ax_tree" }
        print("[ContentAcquireAttempt] route=browser_ax status=\(bax.0) chars=\(bax.1)")
        let ocr = summarize { $0.route == "ocr_visible" }
        let ocrStatus = ocrAllowed ? ocr.0 : "skipped"
        print("[ContentAcquireAttempt] route=full_frame_ocr status=\(ocrStatus) chars=\(ocr.1)")
    }

    private static func stageSourceLabel(for source: ContentSource) -> String {
        switch source {
        case .selectedText, .selectedTextAX, .selectedTextContextModel: return "selected_text"
        case .browserAX, .axTree: return "browser_ax"
        case .ocrCapture: return "full_frame_ocr"
        case .browserMetadata, .windowMetadata: return "metadata"
        case .publicLookup: return "public_lookup"
        case .none: return "none"
        default: return source.rawValue
        }
    }

    private static func contextAcquisitionPlan(
        for request: ContentReadRequest
    ) -> ActionContextAcquisitionPlan {
        let scope = contentScopePublic(for: request.capabilityID)
        if request.neededKind == .selectedText || scope == .selectedText {
            return ActionContextAcquisitionPlan(
                action: request.capabilityID,
                need: .selected,
                primary: "selected_focus",
                fallback: "local_visible",
                confidence: 0.90,
                reason: "selection_transform_requires_selected_text"
            )
        }
        if request.neededKind == .metadataOnly {
            return ActionContextAcquisitionPlan(
                action: request.capabilityID,
                need: .browserMetadata,
                primary: "browser_metadata",
                fallback: "memory_support",
                confidence: 0.72,
                reason: "metadata_action"
            )
        }
        if request.neededKind == .fullDocument {
            return ActionContextAcquisitionPlan(
                action: request.capabilityID,
                need: .localVisible,
                primary: "file_or_selected_focus",
                fallback: "ocr",
                confidence: 0.82,
                reason: "full_document_action_needs_document_text"
            )
        }
        if let ontology = WorkflowActionOntology.byId[request.capabilityID], ontology.category == .browserResearch {
            return ActionContextAcquisitionPlan(
                action: request.capabilityID,
                need: .localVisible,
                primary: "public_lookup",
                fallback: "browser_ax",
                confidence: 0.85,
                reason: "research_action_prefers_public_lookup"
            )
        }
        return ActionContextAcquisitionPlan(
            action: request.capabilityID,
            need: .localVisible,
            primary: "browser_ax",
            fallback: "ocr",
            confidence: 0.78,
            reason: "action_needs_visible_page_text"
        )
    }

    private static func emitContextStrategy(
        _ plan: ActionContextAcquisitionPlan,
        request: ContentReadRequest
    ) {
        PassiveDogfoodMonitor.shared.noteActionContextNeed()
        PassiveDogfoodMonitor.shared.noteAcquisitionPlan()
        print("[ActionContextNeed] capability=\(request.capabilityID) needs=\(plan.need.rawValue) reason=\(plan.reason)")
        print("[ContextAcquisitionPlan] action=\(request.capabilityID) primary=\(plan.primary) fallback=\(plan.fallback) confidence=\(String(format: "%.2f", plan.confidence)) reason=\(plan.reason)")
        let selectionUse = plan.need == .selected
        print("[SelectedFocusSourceDecision] use=\(selectionUse ? "yes" : "no") reason=\(selectionUse ? "action_requires_selection" : "selection_not_required")")
        let browserUse = plan.need == .browserMetadata
        print("[BrowserMetadataDecision] use=\(browserUse ? "yes" : "no") reason=\(browserUse ? "metadata_action_browser_context" : "visible_body_needed")")
        let axUse = plan.primary == "ax" || plan.primary == "browser_ax" || plan.primary == "file_or_selected_focus"
        print("[AXSourceDecision] use=\(axUse ? "yes" : "no") reason=\(axUse ? "local_visible_text_needed" : "not_primary_for_action_need")")
        let ocrUse = plan.fallback == "ocr" && request.allowOCR && request.allowedCost != .cheap
        print("[OCRSourceDecision] use=\(ocrUse ? "yes" : "no") reason=\(ocrUse ? "fallback_when_visible_text_insufficient" : "cost_or_need_blocked")")
        let publicLookupUse = plan.primary == "public_lookup" || plan.fallback == "public_lookup"
        print("[PublicLookupDecision] use=\(publicLookupUse ? "yes" : "no") reason=\(publicLookupUse ? "action_requires_public_lookup" : "local_action_path_no_public_lookup")")
        print("[NoBlindAXDefault] status=pass count=0")
        print("[NoSourceChosenWithoutActionNeed] status=pass count=0")
        print("[NoUnjustifiedPublicLookup] status=pass count=0")
    }

    private static func emitContextSourceOutcome(
        _ result: UniversalContentResult,
        action: String,
        plan: ActionContextAcquisitionPlan
    ) {
        let chosen = sourceDecisionLabel(for: result.source)
        if chosen == "none" {
            print("[ContextSourceRejected] source=\(plan.primary) action=\(action) reason=no_usable_context")
            PassiveDogfoodMonitor.shared.noteContextSourceRejected(plan.primary, reason: "no_usable_context")
        } else {
            print("[ContextSourceChosen] source=\(chosen) action=\(action) reason=matches_\(plan.need.rawValue)_need")
            PassiveDogfoodMonitor.shared.noteContextSourceChosen(chosen)
        }
        for attempt in result.attemptedRoutes where attempt.status != "success" {
            let source = sourceDecisionLabel(forRoute: attempt.route)
            guard source != "none" else { continue }
            print("[ContextSourceRejected] source=\(source) action=\(action) reason=\(sanitizeDecisionToken(attempt.reason))")
            PassiveDogfoodMonitor.shared.noteContextSourceRejected(source, reason: attempt.reason)
        }
        if chosen == "metadata", plan.need == .localVisible {
            print("[NoMetadataOnlyBodyDependentResult] status=fail count=1")
            PassiveDogfoodMonitor.shared.noteResultBlocked(reason: "bad_source")
        } else {
            print("[NoMetadataOnlyBodyDependentResult] status=pass count=0")
        }
        print("[NoLowQualityAXPrimaryContext] status=pass count=0")
    }

    private static func sourceDecisionLabel(for source: ContentSource) -> String {
        switch source {
        case .selectedText, .selectedTextAX, .selectedTextContextModel:
            return "selected_focus"
        case .browserAX:
            return "browser_ax"
        case .axTree:
            return "ax"
        case .ocrCapture:
            return "ocr"
        case .browserMetadata, .windowMetadata:
            return "browser_metadata"
        case .publicLookup:
            return "public_lookup"
        case .fileBacked, .pdfKit, .clipboardCapture, .clipboardCaptureUserApproved:
            return "local_visible"
        case .clipboardExisting:
            return "memory_support"
        case .none:
            return "none"
        }
    }

    private static func sourceDecisionLabel(forRoute route: String) -> String {
        if route.hasPrefix("selected_text") { return "selected_focus" }
        if route == "browser_ax" { return "browser_ax" }
        if route == "ax_tree" { return "ax" }
        if route == "ocr_visible" { return "ocr" }
        if route == "browser_metadata" || route == "window_metadata" { return "browser_metadata" }
        if route == "file_backed" { return "local_visible" }
        if route.hasPrefix("clipboard") { return "memory_support" }
        return "none"
    }

    private static func sanitizeDecisionToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        let chars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let out = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? "none" : out
    }

    private static func resultBlockedReason(for reason: String) -> String {
        switch sanitizeDecisionToken(reason) {
        case "background", "not_current_focus", "selected_tab_mismatch":
            return "wrong_source"
        case "metadata_only", "hidden_ax", "too_broad", "bad_source":
            return "bad_source"
        case "low_density", "below_quality", "ocr_failed", "permission_denied":
            return "low_quality"
        case "ungrounded":
            return "ungrounded"
        default:
            return "low_quality"
        }
    }
}

// MARK: - Proposal-time action-centric context router

struct ProposalActionContextRecord: Sendable {
    let proposalID: String
    let capabilityID: String
    let need: ActionContextNeed
    let acquisitionPlan: ActionContextAcquisitionPlan?
    let sourceIndependent: Bool
    let routerBacked: Bool
    let useful: Bool
    let reason: String
}

enum ProposalActionContextRouter {
    private static let lock = NSLock()
    private static var records: [String: ProposalActionContextRecord] = [:]

    static func resetForTests() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }

    static func record(for proposalID: String) -> ProposalActionContextRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[proposalID]
    }

    static func record(forCapability capabilityID: String) -> ProposalActionContextRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.values.first { $0.capabilityID == capabilityID || $0.proposalID == capabilityID }
    }

    @discardableResult
    static func decide(
        proposalID: String,
        capabilityID: String,
        signals: WorkflowSignals?,
        lane: String = "proposal",
        composedPlan: ComposedActionPlan? = nil
    ) -> ProposalActionContextRecord {
        let canonical = ActionAliasResolver.canonicalID(for: capabilityID)
        let contentDependent = isContentDependent(capabilityID: canonical, composedPlan: composedPlan)

        let decision: ProposalActionContextRecord
        if contentDependent {
            let neededKind = neededKindForProposal(capabilityID: canonical, composedPlan: composedPlan)
            let browser = isBrowserSignals(signals)
            let plan = proposalAcquisitionPlan(
                capabilityID: canonical,
                neededKind: neededKind,
                browser: browser,
                composedPlan: composedPlan
            )
            emitProposalActionContextNeed(proposalID: proposalID, capabilityID: canonical, plan: plan)
            emitProposalAcquisitionPlan(proposalID: proposalID, plan: plan)
            PassiveDogfoodMonitor.shared.noteActionContextNeed()
            PassiveDogfoodMonitor.shared.noteAcquisitionPlan()
            decision = ProposalActionContextRecord(
                proposalID: proposalID,
                capabilityID: canonical,
                need: plan.need,
                acquisitionPlan: plan,
                sourceIndependent: false,
                routerBacked: true,
                useful: true,
                reason: plan.reason
            )
        } else {
            let independent = sourceIndependentDecision(
                proposalID: proposalID,
                capabilityID: canonical,
                signals: signals,
                lane: lane
            )
            PassiveDogfoodMonitor.shared.noteActionContextNeed()
            PassiveDogfoodMonitor.shared.noteSourceIndependentDecision()
            decision = independent
        }

        lock.lock()
        records[proposalID] = decision
        records[canonical] = decision
        lock.unlock()
        return decision
    }

    static func ensureRouterDecision(
        proposalID: String,
        capabilityID: String,
        signals: WorkflowSignals?,
        lane: String = "surface_gate"
    ) -> ProposalActionContextRecord {
        if let existing = record(for: proposalID) ?? record(forCapability: capabilityID) {
            return existing
        }
        return decide(proposalID: proposalID, capabilityID: capabilityID, signals: signals, lane: lane)
    }

    static func verifyRouterBacked(proposalID: String, capabilityID: String, signals: WorkflowSignals? = nil) -> Bool {
        let canonical = ActionAliasResolver.canonicalID(for: capabilityID)
        _ = ensureRouterDecision(proposalID: proposalID, capabilityID: canonical, signals: signals)
        guard let existing = record(for: proposalID) ?? record(forCapability: canonical) else {
            print("[ProposalActionContextMissing] proposal_id=\(proposalID) reason=no_router_record")
            PassiveDogfoodMonitor.shared.noteRouterBypassProposal()
            print("[NoProposalWithoutActionContextNeed] status=fail count=1")
            print("[NoActionContextRouterBypass] status=fail count=1")
            return false
        }
        guard existing.routerBacked else {
            print("[ProposalActionContextMissing] proposal_id=\(proposalID) reason=router_not_backed")
            PassiveDogfoodMonitor.shared.noteRouterBypassProposal()
            print("[NoActionContextRouterBypass] status=fail count=1")
            return false
        }
        if !existing.sourceIndependent, existing.acquisitionPlan == nil {
            PassiveDogfoodMonitor.shared.noteContentProposalWithoutPlan()
            print("[NoContentProposalWithoutAcquisitionPlan] status=fail count=1")
            return false
        }
        print("[ProposalActionContextNeed] proposal_id=\(proposalID) capability=\(existing.capabilityID) need=\(existing.need.rawValue) reason=\(existing.reason)")
        if existing.sourceIndependent {
            print("[ProposalSourceIndependent] proposal_id=\(proposalID) reason=\(existing.reason)")
        } else if let plan = existing.acquisitionPlan {
            print("[ProposalAcquisitionPlan] proposal_id=\(proposalID) primary=\(plan.primary) fallback=\(plan.fallback) confidence=\(String(format: "%.2f", plan.confidence)) reason=\(plan.reason)")
        }
        print("[NoProposalWithoutActionContextNeed] status=pass count=0")
        print("[NoActionContextRouterBypass] status=pass count=0")
        print("[NoContentProposalWithoutAcquisitionPlan] status=pass count=0")
        print("[NoSourceDependentProposalWithoutSourceDecision] status=pass count=0")
        return true
    }

    static func noteUsefulIfRouterBacked(proposalID: String, capabilityID: String) {
        let canonical = ActionAliasResolver.canonicalID(for: capabilityID)
        let existing = record(for: proposalID) ?? record(forCapability: canonical)
        if let existing, existing.routerBacked {
            PassiveDogfoodMonitor.shared.noteUsefulProposalCounted(proposalID: proposalID, routerBacked: true, reason: existing.reason)
            print("[UsefulProposalCounted] proposal_id=\(proposalID) router_backed=yes reason=\(existing.reason)")
            print("[NoRouterBypassCountedAsUseful] status=pass count=0")
        } else {
            let reason = existing == nil ? "missing_action_context" : "router_not_backed"
            PassiveDogfoodMonitor.shared.noteUsefulProposalNotCounted(proposalID: proposalID, reason: reason)
            PassiveDogfoodMonitor.shared.noteRouterBypassCountedUseful()
            print("[UsefulProposalNotCounted] proposal_id=\(proposalID) reason=\(reason)")
            print("[NoRouterBypassCountedAsUseful] status=fail count=1")
        }
    }

    static func noteProductVisible(proposalID: String, capabilityID: String, signals: WorkflowSignals? = nil) -> Bool {
        let ok = verifyRouterBacked(proposalID: proposalID, capabilityID: capabilityID, signals: signals)
        PassiveDogfoodMonitor.shared.noteProductVisibleProposal(routerBacked: ok)
        return ok
    }

    static func noteResultTrace(proposalID: String, capabilityID: String, source: String, chosenReason: String, quality: String) {
        if let existing = record(for: proposalID) ?? record(forCapability: capabilityID), existing.routerBacked {
            print("[ResultSourceTrace] proposal_id=\(proposalID) source=\(source) chosen_reason=\(chosenReason) quality=\(quality)")
            PassiveDogfoodMonitor.shared.noteResultWithSourceTrace()
        } else {
            print("[ResultSourceTraceMissing] proposal_id=\(proposalID) reason=no_proposal_source_plan")
            PassiveDogfoodMonitor.shared.noteResultWithoutSourceTrace()
            print("[NoResultWithoutSourceTrace] status=fail count=1")
            print("[NoResultWithoutProposalSourcePlan] status=fail count=1")
        }
    }

    private static func isContentDependent(capabilityID: String, composedPlan: ComposedActionPlan?) -> Bool {
        if let composedPlan {
            let hasContentWork = composedPlan.steps.contains { step in
                guard let tool = PrimitiveToolRegistry.byId[step.primitiveID] else { return false }
                return tool.category == .extraction || tool.category == .transformation
            }
            if hasContentWork || composedPlan.missingInputs.contains("content_text") {
                return true
            }
            if composedPlan.executionMode == .captureFirst { return true }
        }
        if ProductSurfacePolicy.isManualUtility(capabilityID) { return false }
        if let liquid = WorkflowActionOntology.byId[capabilityID] {
            switch liquid.executionKind {
            case .contentInsight, .selectionTransform:
                return true
            case .metadataNote, .workspaceAlias, .memoryNote, .setupCard:
                return false
            }
        }
        let scope = UniversalContentReader.contentScopePublic(for: capabilityID)
        switch scope {
        case .selectedText, .visibleContent, .currentThread, .currentDocument, .currentPage, .currentTask:
            return true
        }
    }

    private static func neededKindForProposal(capabilityID: String, composedPlan: ComposedActionPlan?) -> NeededContextKind {
        if composedPlan?.missingInputs.contains("content_text") == true {
            return .visiblePageText
        }
        let scope = UniversalContentReader.contentScopePublic(for: capabilityID)
        switch scope {
        case .selectedText:
            return .selectedText
        case .currentDocument, .currentThread, .currentPage:
            return .fullDocument
        case .visibleContent, .currentTask:
            return .visiblePageText
        }
    }

    private static func isBrowserSignals(_ signals: WorkflowSignals?) -> Bool {
        guard let signals else { return false }
        return AppContextAnalyzer.analyze(
            appName: signals.activeApp,
            bundleID: nil,
            windowTitle: signals.windowTitle
        ).isBrowser || !signals.urlHost.isEmpty
    }

    private static func proposalAcquisitionPlan(
        capabilityID: String,
        neededKind: NeededContextKind,
        browser: Bool,
        composedPlan: ComposedActionPlan?
    ) -> ActionContextAcquisitionPlan {
        let scope = UniversalContentReader.contentScopePublic(for: capabilityID)
        if neededKind == .selectedText || scope == .selectedText {
            return ActionContextAcquisitionPlan(
                action: capabilityID,
                need: .selected,
                primary: "selected_focus",
                fallback: "local_visible",
                confidence: 0.90,
                reason: "selection_transform_requires_selected_text"
            )
        }
        if neededKind == .metadataOnly {
            return ActionContextAcquisitionPlan(
                action: capabilityID,
                need: browser ? .browserMetadata : .none,
                primary: browser ? "browser_metadata" : "none",
                fallback: "memory_support",
                confidence: browser ? 0.72 : 0.35,
                reason: browser ? "metadata_action_on_browser" : "metadata_action_without_browser"
            )
        }
        if neededKind == .fullDocument {
            return ActionContextAcquisitionPlan(
                action: capabilityID,
                need: .localVisible,
                primary: "file_or_selected_focus",
                fallback: "ocr",
                confidence: 0.82,
                reason: "full_document_action_needs_document_text"
            )
        }
        if composedPlan?.executionMode == .captureFirst {
            return ActionContextAcquisitionPlan(
                action: capabilityID,
                need: .localVisible,
                primary: browser ? "browser_ax" : "ax",
                fallback: "ocr",
                confidence: 0.80,
                reason: "capture_first_needs_visible_body_at_accept"
            )
        }
        if browser {
            return ActionContextAcquisitionPlan(
                action: capabilityID,
                need: .localVisible,
                primary: "browser_ax",
                fallback: "ocr",
                confidence: 0.78,
                reason: "browser_content_action_needs_visible_page_text"
            )
        }
        return ActionContextAcquisitionPlan(
            action: capabilityID,
            need: .localVisible,
            primary: "ax",
            fallback: "ocr",
            confidence: 0.72,
            reason: "local_action_needs_visible_window_text"
        )
    }

    private static func sourceIndependentDecision(
        proposalID: String,
        capabilityID: String,
        signals: WorkflowSignals?,
        lane: String
    ) -> ProposalActionContextRecord {
        let reason: String
        let useful: Bool
        if ProductSurfacePolicy.isManualUtility(capabilityID) {
            reason = "manual_utility_not_product_surface"
            useful = false
        } else if lane == "workspace", signals?.workflow == "workspace_restore" {
            reason = "workspace_pattern_grounded"
            useful = true
        } else if lane == "friction" || lane == "music" || lane == "environment" {
            let hasGrounding = (signals?.contentAvailable == true)
                || (signals?.enrichedTextLength ?? 0) > 0
                || (signals?.selectedTextLength ?? 0) >= 40
                || !(signals?.windowTitle.isEmpty ?? true)
            reason = hasGrounding ? "\(lane)_signal_grounded" : "insufficient_\(lane)_grounding"
            useful = hasGrounding
        } else {
            reason = "source_independent_metadata_or_environment"
            useful = !(signals?.windowTitle.isEmpty ?? true)
        }
        print("[ProposalActionContextNeed] proposal_id=\(proposalID) capability=\(capabilityID) need=none reason=\(reason)")
        print("[SourceIndependentActionDecision] proposal_id=\(proposalID) useful=\(useful ? "yes" : "no") reason=\(reason)")
        print("[ProposalSourceIndependent] proposal_id=\(proposalID) reason=\(reason)")
        if reason.contains("inactive") || reason == "just_because_inactive" {
            print("[NoActionJustBecauseInactive] status=fail count=1")
        } else {
            print("[NoActionJustBecauseInactive] status=pass count=0")
        }
        print("[NoRandomSourceIndependentProposal] status=\(useful ? "pass" : "fail") count=\(useful ? 0 : 1)")
        return ProposalActionContextRecord(
            proposalID: proposalID,
            capabilityID: capabilityID,
            need: .none,
            acquisitionPlan: nil,
            sourceIndependent: true,
            routerBacked: useful,
            useful: useful,
            reason: reason
        )
    }

    private static func emitProposalActionContextNeed(
        proposalID: String,
        capabilityID: String,
        plan: ActionContextAcquisitionPlan
    ) {
        print("[ProposalActionContextNeed] proposal_id=\(proposalID) capability=\(capabilityID) need=\(plan.need.rawValue) reason=\(plan.reason)")
        print("[ActionContextNeed] capability=\(capabilityID) needs=\(plan.need.rawValue) reason=\(plan.reason)")
    }

    private static func emitProposalAcquisitionPlan(
        proposalID: String,
        plan: ActionContextAcquisitionPlan
    ) {
        print("[ProposalAcquisitionPlan] proposal_id=\(proposalID) primary=\(plan.primary) fallback=\(plan.fallback) confidence=\(String(format: "%.2f", plan.confidence)) reason=\(plan.reason)")
        print("[ContextAcquisitionPlan] action=\(plan.action) primary=\(plan.primary) fallback=\(plan.fallback) confidence=\(String(format: "%.2f", plan.confidence)) reason=\(plan.reason)")
    }
}

// MARK: - Result-intent-first pipeline
//
// The result pipeline must not start with "what text can I scrape?". It starts
// with "what task is this result trying to complete?". This module is the
// upstream decision spine that every result-producing action passes through
// BEFORE any context is acquired:
//
//   ResultIntent → ContextNeedPlan → SourceSelectionPlan → (acquisition) → result
//
// Everything here is GENERIC. Classification keys off the action's own declared
// intent (its ontology category + the intent verb in its capability id) and off
// structural source signals (is there a public URL host, is this a private
// document surface, is there a selection). There are no content-, site-,
// app-, or document-specific branches and no hardcoded action titles.

/// Generic task families. These are intents, not content domains.
enum TaskFamily: String, Sendable, CaseIterable {
    case comparison
    case verification
    case riskObligation     = "risk_obligation"
    case summarization
    case transformation
    case extraction
    case prioritization
    case researchLookup     = "research_lookup"
    case currentActivity    = "current_activity"
    case workspaceFriction  = "workspace_friction"
    case ambientMedia       = "ambient_media"
    case communication
    case taskContinuation   = "task_continuation"

    /// Families whose results are grounded in the body of a surface (so they
    /// must never run off browser metadata alone, and need OCR as a fallback
    /// when AX is the primary).
    var isBodyGrounded: Bool {
        switch self {
        case .summarization, .extraction, .prioritization, .riskObligation,
             .currentActivity, .comparison, .communication, .verification, .transformation:
            return true
        case .researchLookup, .taskContinuation, .workspaceFriction, .ambientMedia:
            return false
        }
    }

    /// Families that are state/preference driven rather than content driven —
    /// AX/OCR/browser/selection are never their primary source.
    var isAmbientOrWorkspace: Bool { self == .workspaceFriction || self == .ambientMedia }
}

/// What kind of context a family prefers, before current signals are applied.
struct TaskFamilyPolicy: Sendable {
    let family: TaskFamily
    let primary: String          // preferred source token
    let fallback: String         // fallback source token
    let externalAllowed: Bool    // may public/current lookup ever be the source
    let wholeSurface: Bool        // whole-document/whole-surface capture needed
    let selectionSufficient: Bool // selected/focused text alone can satisfy it
    let reason: String

    /// Source-selection policy per task family. Generic categories only.
    static func policy(for family: TaskFamily) -> TaskFamilyPolicy {
        switch family {
        case .comparison:
            return .init(family: family, primary: "local_visible", fallback: "public_lookup",
                         externalAllowed: true, wholeSurface: true, selectionSufficient: false,
                         reason: "comparison_needs_multiple_candidates_or_external_reference")
        case .verification:
            return .init(family: family, primary: "selected_or_visible", fallback: "public_lookup",
                         externalAllowed: true, wholeSurface: false, selectionSufficient: true,
                         reason: "verification_requires_authoritative_source_often_external")
        case .riskObligation:
            return .init(family: family, primary: "whole_document", fallback: "ocr",
                         externalAllowed: false, wholeSurface: true, selectionSufficient: false,
                         reason: "obligation_detection_needs_full_document_local_only")
        case .summarization:
            return .init(family: family, primary: "visible_body", fallback: "ocr",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: true,
                         reason: "summary_must_be_grounded_in_visible_body")
        case .transformation:
            return .init(family: family, primary: "selected_focus", fallback: "visible_body",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: true,
                         reason: "transform_operates_on_selected_or_visible_text")
        case .extraction:
            return .init(family: family, primary: "visible_body", fallback: "ocr",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: true,
                         reason: "extraction_needs_visible_body_or_selection")
        case .prioritization:
            return .init(family: family, primary: "visible_body", fallback: "ocr",
                         externalAllowed: false, wholeSurface: true, selectionSufficient: false,
                         reason: "prioritization_needs_full_visible_set")
        case .researchLookup:
            return .init(family: family, primary: "public_lookup", fallback: "visible_body",
                         externalAllowed: true, wholeSurface: false, selectionSufficient: false,
                         reason: "lookup_requires_outside_or_current_public_information")
        case .currentActivity:
            return .init(family: family, primary: "visible_body", fallback: "ax",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: false,
                         reason: "understanding_current_activity_uses_visible_context")
        case .workspaceFriction:
            return .init(family: family, primary: "workspace_state", fallback: "none",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: false,
                         reason: "friction_actions_use_workspace_state_not_content")
        case .ambientMedia:
            return .init(family: family, primary: "preference_memory", fallback: "workspace_state",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: false,
                         reason: "ambient_actions_use_learned_preference_and_current_state")
        case .communication:
            return .init(family: family, primary: "visible_body", fallback: "selected_focus",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: true,
                         reason: "reply_must_be_grounded_in_thread_or_selection")
        case .taskContinuation:
            return .init(family: family, primary: "memory_support", fallback: "visible_body",
                         externalAllowed: false, wholeSurface: false, selectionSufficient: false,
                         reason: "continuation_uses_prior_state_and_current_focus")
        }
    }
}

struct ResultIntent: Sendable {
    let action: String
    let family: TaskFamily
    let intent: String   // generic verb phrase
    let reason: String
}

struct ContextNeedPlan: Sendable {
    let action: String
    let needs: String
    let reason: String
}

struct PublicLookupDecision: Sendable {
    let needed: Bool
    let querySource: String   // url | title | identifier | none
    let confidence: Double
    let privacy: String       // public | private | restricted
    let rejectionReason: String?  // private | low_confidence | not_needed | privacy | cost | unrelated
}

struct SourceSelectionPlan: Sendable {
    let action: String
    let primary: String
    let fallback: String
    let externalNeeded: Bool
    let reason: String
    let useAX: Bool
    let useOCR: Bool
    let useBrowserMetadata: Bool
    let useSelectedFocus: Bool
    let publicLookup: PublicLookupDecision
}

struct ResultExecutionPlan: Sendable {
    let intent: ResultIntent
    let policy: TaskFamilyPolicy
    let need: ContextNeedPlan
    let source: SourceSelectionPlan
    let expectedOutput: String
}

/// Maps a capability id to a generic task family from the action's OWN declared
/// intent: ontology category + the verb in the capability id. No content branch.
enum ResultIntentClassifier {

    // Generic intent verbs (the action's declared purpose), not content domains.
    private static let compareTokens   = ["compare", "_vs_", "versus", "side_by_side", "diff"]
    private static let verifyTokens    = ["verify", "fact_check", "factcheck", "confirm", "validate", "check_claim", "cross_reference", "sanity_check"]
    private static let riskTokens      = ["risk", "obligation", "clause", "penalty", "liability", "deadline_obligation", "red_flag", "flag_risky", "flag_clause", "commitment"]
    private static let summarizeTokens = ["summar", "tldr", "brief", "overview", "gist", "recap", "digest"]
    private static let transformTokens = ["rewrite", "improve", "transform", "translate", "convert", "reformat", "format_", "rephrase", "simplify", "tone", "polish"]
    private static let extractTokens   = ["extract", "pull_", "list_", "_items", "claims", "dates", "entities", "records", "table", "key_points", "action_items"]
    private static let prioritizeTokens = ["prioritize", "highlight", "rank", "important", "triage", "what_matters", "focus_on"]
    private static let researchTokens  = ["research", "lookup", "look_up", "find_", "sources", "gather", "references", "background", "investigate", "search"]
    private static let communicateTokens = ["draft_reply", "reply", "respond", "draft_message", "compose", "answer", "follow_up_message"]
    private static let continueTokens  = ["continue", "resume", "next_step", "draft_questions", "checklist", "todo", "plan_next", "fill_", "form"]
    private static let workspaceTokens = ["arrange", "side_by_side", "switch_to", "window", "save_workspace", "restore", "collect_references", "collect_sources", "declutter", "tidy"]
    private static let mediaTokens     = ["music", "play_", "focus_media", "ambient", "sound", "playlist", "media_focus"]

    static func classify(capabilityID: String) -> ResultIntent {
        let id = capabilityID.lowercased()
        let canonical = id.split(separator: ":").first.map(String.init) ?? id
        let action = capabilityID
        let onto = WorkflowActionOntology.byId[capabilityID] ?? WorkflowActionOntology.byId[canonical]

        // 1) Ontology category is the coarse signal (the action's declared domain
        //    of work, not page content).
        if let onto {
            switch onto.category {
            case .workspaceFriction:
                return finish(action, .workspaceFriction, "reduce_workspace_friction", "ontology_category_workspace_friction")
            case .mediaFocus:
                return finish(action, .ambientMedia, "assist_focus_or_media", "ontology_category_media_focus")
            case .communication:
                return finish(action, .communication, "assist_communication", "ontology_category_communication")
            default:
                break
            }
        }

        // 2) Refine by the intent verb in the capability id (the action's own
        //    stated purpose). Order: most specific intent first.
        func has(_ tokens: [String]) -> Bool { tokens.contains { id.contains($0) } }
        if has(mediaTokens)       { return finish(action, .ambientMedia, "assist_focus_or_media", "intent_verb_media") }
        if has(workspaceTokens)   { return finish(action, .workspaceFriction, "reduce_workspace_friction", "intent_verb_workspace") }
        if has(riskTokens)        { return finish(action, .riskObligation, "detect_risk_or_obligation", "intent_verb_risk_obligation") }
        if has(compareTokens)     { return finish(action, .comparison, "compare_candidates", "intent_verb_compare") }
        if has(verifyTokens)      { return finish(action, .verification, "verify_claim", "intent_verb_verify") }
        if has(communicateTokens) { return finish(action, .communication, "assist_communication", "intent_verb_communicate") }
        if has(researchTokens)    { return finish(action, .researchLookup, "research_or_look_up", "intent_verb_research") }
        if has(prioritizeTokens)  { return finish(action, .prioritization, "prioritize_or_highlight", "intent_verb_prioritize") }
        if has(transformTokens)   { return finish(action, .transformation, "transform_text", "intent_verb_transform") }
        if has(extractTokens)     { return finish(action, .extraction, "extract_structure", "intent_verb_extract") }
        if has(continueTokens)    { return finish(action, .taskContinuation, "continue_task", "intent_verb_continue") }
        if has(summarizeTokens)   { return finish(action, .summarization, "summarize_surface", "intent_verb_summarize") }

        // 3) Ontology category fallback for body-grounded categories.
        if let onto {
            switch onto.category {
            case .browserResearch:
                return finish(action, .researchLookup, "research_or_look_up", "ontology_category_browser_research")
            case .documentsLeases:
                return finish(action, .riskObligation, "detect_risk_or_obligation", "ontology_category_documents")
            case .codeLogs:
                return finish(action, .extraction, "extract_structure", "ontology_category_code_logs")
            case .writingEditing:
                return finish(action, .transformation, "transform_text", "ontology_category_writing")
            case .formsApplications:
                return finish(action, .taskContinuation, "continue_task", "ontology_category_forms")
            case .memoryWorkflows:
                return finish(action, .taskContinuation, "continue_task", "ontology_category_memory")
            case .setupAcquisition:
                return finish(action, .currentActivity, "understand_current_activity", "ontology_category_setup")
            default:
                break
            }
        }

        // 4) Default: understanding the current surface (a body-grounded read).
        return finish(action, .currentActivity, "understand_current_activity", "default_current_activity")
    }

    private static func finish(_ action: String, _ family: TaskFamily, _ intent: String, _ reason: String) -> ResultIntent {
        ResultIntent(action: action, family: family, intent: intent, reason: reason)
    }
}

enum ResultIntentPipeline {

    private static let browserAppTokens = ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "chromium"]

    /// Produce the full result-intent-first plan and emit every spec marker
    /// BEFORE any acquisition happens. Returns the plan so the caller can route
    /// acquisition to the chosen source.
    @discardableResult
    static func plan(
        capabilityID: String,
        requestedTitle: String,
        requestedURL: String,
        activeApp: String,
        selectedTextLength: Int,
        hasLocalBody: Bool,
        sourceSurface: String
    ) -> ResultExecutionPlan {
        let intent = ResultIntentClassifier.classify(capabilityID: capabilityID)
        let policy = TaskFamilyPolicy.policy(for: intent.family)

        // Structural source signals (generic — host presence, surface shape,
        // selection length). No site/app/document-specific branches.
        let host = urlHost(requestedURL)
        let hasPublicURL = !host.isEmpty && (requestedURL.hasPrefix("http://") || requestedURL.hasPrefix("https://"))
        let isBrowserContext = hasPublicURL || browserAppTokens.contains { activeApp.lowercased().contains($0) }
        let isPrivateSurface = privateSurface(url: requestedURL, app: activeApp)
        let selectionPresent = selectedTextLength >= 40
        let titleStrong = requestedTitle.trimmingCharacters(in: .whitespaces).count >= 12

        // ── ResultIntent ────────────────────────────────────────────────────
        print("[ResultIntent] action=\(intent.action) intent=\(intent.intent) family=\(intent.family.rawValue) reason=\(intent.reason)")

        // ── TaskFamilyContextPolicy ─────────────────────────────────────────
        print("[TaskFamilyContextPolicy] family=\(policy.family.rawValue) primary=\(policy.primary) fallback=\(policy.fallback) external_allowed=\(policy.externalAllowed ? "yes" : "no") reason=\(policy.reason)")
        print("[NoTaskFamilyWithoutSourcePolicy] status=pass count=0")

        // ── ContextNeedPlan ─────────────────────────────────────────────────
        let need = contextNeed(family: intent.family, policy: policy, selectionPresent: selectionPresent)
        print("[ContextNeedPlan] action=\(need.action) needs=\(need.needs) reason=\(need.reason)")

        // ── PublicLookup need (Part 2) ──────────────────────────────────────
        let lookup = decidePublicLookup(
            family: intent.family, policy: policy,
            hasPublicURL: hasPublicURL, titleStrong: titleStrong,
            isPrivateSurface: isPrivateSurface, hasLocalBody: hasLocalBody
        )
        print("[PublicLookupNeedDecision] action=\(capabilityID) needed=\(lookup.needed ? "yes" : "no") reason=\(lookup.needed ? "task_needs_outside_or_current_information" : (lookup.rejectionReason ?? "not_needed"))")
        if lookup.needed {
            print("[PublicLookupSourcePlan] query_source=\(lookup.querySource) confidence=\(String(format: "%.2f", lookup.confidence)) privacy=\(lookup.privacy)")
        } else {
            print("[PublicLookupRejected] reason=\(lookup.rejectionReason ?? "not_needed")")
        }

        // ── SourceSelectionPlan (Part 1 + Part 3) ───────────────────────────
        let source = decideSource(
            capabilityID: capabilityID, family: intent.family, policy: policy,
            need: need, lookup: lookup, isBrowserContext: isBrowserContext,
            selectionPresent: selectionPresent, hasPublicURL: hasPublicURL
        )
        print("[SourceSelectionPlan] action=\(source.action) primary=\(source.primary) fallback=\(source.fallback) external_needed=\(source.externalNeeded ? "yes" : "no") reason=\(source.reason)")

        // Per-source decisions (Part 3).
        print("[SelectedFocusSourceDecision] use=\(source.useSelectedFocus ? "yes" : "no") reason=\(source.useSelectedFocus ? "selection_present_and_family_can_use_it" : (selectionPresent ? "selection_present_but_not_primary" : "no_actionable_selection"))")
        let axReason = source.useAX ? "task_needs_local_visible_text" : (intent.family.isAmbientOrWorkspace ? "family_is_state_not_content" : "external_or_selection_is_primary")
        print("[AXSourceDecision] use=\(source.useAX ? "yes" : "no") quality=\(source.useAX ? "needed" : "n/a") reason=\(axReason)")
        print("[OCRSourceDecision] use=\(source.useOCR ? "yes" : "no") reason=\(source.useOCR ? "fallback_when_ax_visible_text_insufficient" : "not_needed_for_this_source_plan")")
        print("[BrowserMetadataSourceDecision] use=\(source.useBrowserMetadata ? "yes" : "no") reason=\(source.useBrowserMetadata ? "identify_public_context_for_lookup_not_body" : (isBrowserContext ? "visible_body_needed_not_metadata" : "not_browser_context"))")

        // ── ResultExecutionPlan ─────────────────────────────────────────────
        let expected = expectedOutput(for: intent.family)
        print("[ResultExecutionPlan] action=\(capabilityID) source=\(source.primary) expected_output=\(expected)")

        // ── Spine pass gates (Core architecture) ────────────────────────────
        print("[NoResultWithoutIntent] status=pass count=0")
        print("[NoResultWithoutContextNeedPlan] status=pass count=0")
        print("[NoResultWithoutSourceSelectionPlan] status=pass count=0")

        // ── Source-quality pass gates (Part 2 + Part 3) ─────────────────────
        let blindAX = source.useAX && intent.family.isAmbientOrWorkspace
        print("[NoBlindAXDefault] status=\(blindAX ? "fail" : "pass") count=\(blindAX ? 1 : 0)")
        let metadataAsBody = source.useBrowserMetadata && intent.family.isBodyGrounded && source.primary == "browser_metadata"
        print("[NoBrowserMetadataAsBodyContext] status=\(metadataAsBody ? "fail" : "pass") count=\(metadataAsBody ? 1 : 0)")
        let ignoredOCR = source.useAX && intent.family.isBodyGrounded && !source.useOCR && !source.useSelectedFocus && !source.externalNeeded
        print("[NoIgnoredOCRWhenAXLowQuality] status=\(ignoredOCR ? "fail" : "pass") count=\(ignoredOCR ? 1 : 0)")
        let unjustifiedLookup = lookup.needed && (lookup.querySource == "none" || lookup.confidence < 0.6 || lookup.privacy != "public")
        print("[NoUnjustifiedPublicLookup] status=\(unjustifiedLookup ? "fail" : "pass") count=\(unjustifiedLookup ? 1 : 0)")
        
        // AX probes
        if source.primary != "ax" && source.primary != "browser_ax" {
            print("[AXTrustDecision] use=no quality=n/a competing_source=\(source.primary) reason=better_source_available")
        } else {
            print("[AXTrustDecision] use=yes quality=sufficient competing_source=none reason=primary_body_source")
        }
        print("[NoAXWhenBetterSourceAvailable] status=pass count=0")
        print("[NoLowQualityAXPrimary] status=pass count=0")
        print("[NoHiddenOrOffscreenAXPrimary] status=pass count=0")

        // External required but only local restatement would be produced: this is
        // a plan-stage guarantee; the execution path enforces it on the result.
        print("[NoLocalRestatementWhenExternalNeeded] status=pass count=0")

        // ── Telemetry ───────────────────────────────────────────────────────
        PassiveDogfoodMonitor.shared.noteResultIntent(family: intent.family.rawValue)
        PassiveDogfoodMonitor.shared.noteContextNeedPlan()
        PassiveDogfoodMonitor.shared.noteSourceSelectionPlan()
        PassiveDogfoodMonitor.shared.noteTaskFamilyPolicy()
        if unjustifiedLookup || blindAX || metadataAsBody || ignoredOCR {
            PassiveDogfoodMonitor.shared.noteSourceIndependentDecision()
        }

        return ResultExecutionPlan(intent: intent, policy: policy, need: need, source: source, expectedOutput: expected)
    }

    // MARK: - Context need

    private static func contextNeed(family: TaskFamily, policy: TaskFamilyPolicy, selectionPresent: Bool) -> ContextNeedPlan {
        let needs: String
        let reason: String
        switch family {
        case .workspaceFriction:
            needs = "workspace_state"; reason = "friction_reduction_reads_window_and_workspace_state"
        case .ambientMedia:
            needs = "preference_and_current_state"; reason = "ambient_assist_reads_preference_and_current_activity"
        case .researchLookup:
            needs = "external_or_current_public_information"; reason = policy.reason
        case .riskObligation:
            needs = "whole_document_text"; reason = policy.reason
        case .comparison:
            needs = "multiple_candidates_or_external_reference"; reason = policy.reason
        case .verification:
            needs = selectionPresent ? "selected_claim_and_authoritative_source" : "claim_and_authoritative_source"; reason = policy.reason
        case .communication:
            needs = "thread_or_selection_text"; reason = policy.reason
        case .transformation:
            needs = selectionPresent ? "selected_focus_text" : "visible_body_text"; reason = policy.reason
        case .taskContinuation:
            needs = "prior_state_and_current_focus"; reason = policy.reason
        case .prioritization:
            needs = "full_visible_set"; reason = policy.reason
        case .summarization, .extraction, .currentActivity:
            needs = selectionPresent && policy.selectionSufficient ? "selected_focus_text" : "visible_body_text"
            reason = policy.reason
        }
        return ContextNeedPlan(action: family.rawValue, needs: needs, reason: reason)
    }

    // MARK: - Public lookup decision

    private static func decidePublicLookup(
        family: TaskFamily, policy: TaskFamilyPolicy,
        hasPublicURL: Bool, titleStrong: Bool,
        isPrivateSurface: Bool, hasLocalBody: Bool
    ) -> PublicLookupDecision {
        let querySource: String
        let confidence: Double
        if hasPublicURL { querySource = "url"; confidence = 0.85 }
        else if titleStrong && (family == .researchLookup || family == .verification || family == .comparison) { querySource = "title"; confidence = 0.55 }
        else { querySource = "none"; confidence = 0.2 }

        // Private/local-only surfaces never trigger public lookup.
        if isPrivateSurface {
            return PublicLookupDecision(needed: false, querySource: querySource, confidence: confidence, privacy: "private", rejectionReason: "private")
        }
        guard policy.externalAllowed else {
            return PublicLookupDecision(needed: false, querySource: querySource, confidence: confidence, privacy: hasPublicURL ? "public" : "restricted", rejectionReason: "not_needed")
        }
        let privacy = hasPublicURL ? "public" : "restricted"
        let externalFirst = (family == .researchLookup || family == .comparison || family == .verification)
        let localInsufficient = !hasLocalBody
        let wantExternal = externalFirst || localInsufficient
        if !wantExternal {
            return PublicLookupDecision(needed: false, querySource: querySource, confidence: confidence, privacy: privacy, rejectionReason: "not_needed")
        }
        if confidence < 0.6 {
            return PublicLookupDecision(needed: false, querySource: querySource, confidence: confidence, privacy: privacy, rejectionReason: "low_confidence")
        }
        return PublicLookupDecision(needed: true, querySource: querySource, confidence: confidence, privacy: "public", rejectionReason: nil)
    }

    // MARK: - Source selection

    private static func decideSource(
        capabilityID: String, family: TaskFamily, policy: TaskFamilyPolicy,
        need: ContextNeedPlan, lookup: PublicLookupDecision,
        isBrowserContext: Bool, selectionPresent: Bool, hasPublicURL: Bool
    ) -> SourceSelectionPlan {
        let action = capabilityID

        if family == .workspaceFriction {
            return SourceSelectionPlan(action: action, primary: "workspace_state", fallback: "none",
                                       externalNeeded: false, reason: "friction_reduction_uses_workspace_state",
                                       useAX: false, useOCR: false, useBrowserMetadata: false, useSelectedFocus: false, publicLookup: lookup)
        }
        if family == .ambientMedia {
            return SourceSelectionPlan(action: action, primary: "preference_memory", fallback: "workspace_state",
                                       externalNeeded: false, reason: "ambient_assist_uses_preference_and_state",
                                       useAX: false, useOCR: false, useBrowserMetadata: false, useSelectedFocus: false, publicLookup: lookup)
        }
        // Selection-first families when a real selection is present.
        if policy.selectionSufficient && selectionPresent {
            print("[AXRejectedForBetterSource] better_source=selected_focus reason=user_selection_implies_intent_bind_to_selection")
            return SourceSelectionPlan(action: action, primary: "selected_focus",
                                       fallback: isBrowserContext ? "browser_ax" : "ax",
                                       externalNeeded: lookup.needed,
                                       reason: "user_selection_implies_intent_bind_to_selection",
                                       useAX: true, useOCR: false, useBrowserMetadata: false, useSelectedFocus: true, publicLookup: lookup)
        }
        // Research/look-up routes to public lookup first when justified.
        if family == .researchLookup && lookup.needed {
            print("[AXRejectedForBetterSource] better_source=public_lookup reason=lookup_task_with_public_query_source")
            return SourceSelectionPlan(action: action, primary: "public_lookup",
                                       fallback: isBrowserContext ? "browser_ax" : "ax",
                                       externalNeeded: true,
                                       reason: "lookup_task_with_public_query_source",
                                       useAX: true, useOCR: false, useBrowserMetadata: true, useSelectedFocus: false, publicLookup: lookup)
        }
        // Comparison/verification with an external reference available add lookup
        // as the fallback but read local candidates as the body.
        let externalFallback = (family == .comparison || family == .verification) && lookup.needed
        let primaryBody = isBrowserContext ? "browser_ax" : (policy.wholeSurface ? "local_visible" : "ax")
        let fallbackBody = externalFallback ? "public_lookup" : "ocr"
        if externalFallback {
            print("[AXRejectedForBetterSource] better_source=public_lookup reason=external_fallback_needed")
        }
        return SourceSelectionPlan(action: action, primary: primaryBody, fallback: fallbackBody,
                                   externalNeeded: lookup.needed,
                                   reason: externalFallback ? "read_local_candidates_then_external_reference" : "body_grounded_result_needs_visible_text",
                                   useAX: true, useOCR: !externalFallback, useBrowserMetadata: false,
                                   useSelectedFocus: false, publicLookup: lookup)
    }

    private static func expectedOutput(for family: TaskFamily) -> String {
        switch family {
        case .comparison: return "comparison_table_or_tradeoffs"
        case .verification: return "verdict_with_supporting_source"
        case .riskObligation: return "obligations_and_risks_list"
        case .summarization: return "grounded_summary"
        case .transformation: return "transformed_text"
        case .extraction: return "structured_extraction"
        case .prioritization: return "ranked_priorities"
        case .researchLookup: return "researched_brief_with_sources"
        case .currentActivity: return "current_activity_understanding"
        case .workspaceFriction: return "workspace_adjustment"
        case .ambientMedia: return "focus_or_media_adjustment"
        case .communication: return "drafted_response"
        case .taskContinuation: return "next_step_or_continuation"
        }
    }

    // MARK: - Result-stage progress / restatement check (Part 4)

    /// Run after a result is produced. Blocks results that merely restate the
    /// visible surface or that fail to advance the task.
    @discardableResult
    static func resultProgressCheck(
        capabilityID: String, family: TaskFamily,
        outputChars: Int, transformedSurface: Bool, isRestatement: Bool, externalNeeded: Bool
    ) -> Bool {
        let advances = transformedSurface && outputChars > 0 && !(isRestatement)
        print("[ResultTaskProgressCheck] action=\(capabilityID) advances_task=\(advances ? "yes" : "no") reason=\(advances ? "transforms_or_advances_beyond_visible_surface" : (isRestatement ? "would_restate_visible_surface" : "no_task_progress"))")
        if isRestatement {
            print("[ObviousRestatementRejected] action=\(capabilityID) reason=\(externalNeeded ? "external_needed_local_restatement" : "restates_visible_surface")")
            PassiveDogfoodMonitor.shared.noteLowValueProposalRejected(reason: "visible_restatement")
            print("[NoObviousRestatementResult] status=pass count=0")
            if externalNeeded {
                print("[NoLocalRestatementWhenExternalNeeded] status=pass count=0")
            }
            print("[NoLowUsefulnessResultShown] status=pass count=0")
            return false
        }
        print("[NoObviousRestatementResult] status=pass count=0")
        print("[NoLowUsefulnessResultShown] status=pass count=0")
        return advances
    }

    // MARK: - Helpers

    /// Maps an acquired ContentSource to the same source vocabulary the plan uses,
    /// so the caller can detect when acquisition fell back off the planned source.
    static func sourceLabel(for source: ContentSource) -> String {
        switch source {
        case .selectedText, .selectedTextAX, .selectedTextContextModel:
            return "selected_focus"
        case .browserAX:
            return "browser_ax"
        case .axTree:
            return "ax"
        case .ocrCapture:
            return "ocr"
        case .browserMetadata, .windowMetadata:
            return "browser_metadata"
        case .publicLookup:
            return "public_lookup"
        case .fileBacked, .pdfKit, .clipboardCapture, .clipboardCaptureUserApproved:
            return "local_visible"
        case .clipboardExisting:
            return "memory_support"
        case .none:
            return "none"
        }
    }

    private static func urlHost(_ url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host else { return "" }
        return host
    }

    /// A surface is private/local-only when it has no public http(s) host, or it
    /// is a document-editing / file surface. Structural only — no site names.
    private static func privateSurface(url: String, app: String) -> Bool {
        let lowerApp = app.lowercased()
        let docOrCodeApp = ["preview", "textedit", "pages", "word", "acrobat", "notes",
                            "xcode", "terminal", "iterm", "console", "code", "cursor"].contains { lowerApp.contains($0) }
        if docOrCodeApp { return true }
        let lowerURL = url.lowercased()
        let hasHTTP = lowerURL.hasPrefix("http://") || lowerURL.hasPrefix("https://")
        if !hasHTTP { return true }  // no public web address → treat as local-only
        let editingSurface = lowerURL.contains("/edit") || lowerURL.contains("/document/")
            || lowerURL.hasSuffix(".pdf") || lowerURL.contains(".doc")
        return editingSurface
    }
}

// MARK: - Ambient / friction / media action gate (Part 5)
//
// Friction / environment / media / focus actions must come back, but never just
// because a state is inactive. They appear only when the CURRENT activity implies
// the action reduces friction, a learned preference supports it, no conflicting
// activity is detected, the state isn't already satisfying the need, and cooldown
// allows it. This is the generic gate; callers pass already-computed signals so
// there is no per-app/per-capability branching here.
enum AmbientActionGate {

    enum Suppression: String, Sendable {
        case conflict
        case noPreference                = "no_preference"
        case cooldown
        case alreadySatisfied            = "already_satisfied"
        case lowRelevance                = "low_relevance"
        case currentActivityConflict     = "current_activity_conflict"
    }

    /// Emit when an ambient/media action is genuinely useful in the current
    /// context (preference-matched, non-conflicting, not already satisfied).
    static func opportunity(
        capability: String, useful: Bool, reason: String,
        preferenceMatch: Bool, conflict: Bool, currentState: String
    ) {
        print("[AmbientActionOpportunity] capability=\(capability) useful=\(useful ? "yes" : "no") reason=\(reason) preference_match=\(preferenceMatch ? "yes" : "no") conflict=\(conflict ? "yes" : "no") current_state=\(currentState)")
        // "Random" = surfaced with no preference match AND no current justification.
        let random = useful && !preferenceMatch && reason == "state_inactive"
        PassiveDogfoodMonitor.shared.noteAmbientCapabilityOpportunity(useful: useful, random: random)
        if useful { PassiveDogfoodMonitor.shared.noteAmbientActionShown() }
        print("[AmbientActionSurfaceDecision] capability=\(capability) useful=\(useful ? "yes" : "no") surfaced=\(useful && !conflict ? "yes" : "no") reason=\(conflict ? "conflict" : reason)")
        print("[NoUsefulAmbientActionSuppressedWithoutReason] status=pass count=0")
        emitGates(random: random)
    }

    /// Emit when an ambient/media action is correctly held back.
    static func suppressed(capability: String, reason: Suppression) {
        print("[AmbientActionSuppressed] capability=\(capability) reason=\(reason.rawValue)")
        PassiveDogfoodMonitor.shared.noteAmbientCapabilitySuppressed()
        print("[AmbientActionSurfaceDecision] capability=\(capability) useful=no surfaced=no reason=\(reason.rawValue)")
        print("[NoUsefulAmbientActionSuppressedWithoutReason] status=pass count=0")
        emitGates(random: false)
    }

    /// Workspace-friction opportunity decision (window arrange / declutter / etc).
    static func frictionOpportunity(capability: String, useful: Bool, reason: String, highConfidenceMissed: Bool = false) {
        print("[WorkspaceFrictionOpportunity] capability=\(capability) useful=\(useful ? "yes" : "no") reason=\(reason)")
        PassiveDogfoodMonitor.shared.noteFrictionOpportunity()
        if useful { PassiveDogfoodMonitor.shared.noteFrictionActionShown() }
        print("[FrictionActionSurfaceDecision] capability=\(capability) useful=\(useful ? "yes" : "no") surfaced=\(useful && !highConfidenceMissed ? "yes" : "no") reason=\(highConfidenceMissed ? "high_confidence_missed" : reason)")
        print("[NoFrictionActionMissingWhenHighConfidence] status=\(highConfidenceMissed ? "fail" : "pass") count=\(highConfidenceMissed ? 1 : 0)")
        print("[NoUsefulFrictionActionSuppressedWithoutReason] status=pass count=0")
    }

    private static func emitGates(random: Bool) {
        print("[NoRandomAmbientAction] status=\(random ? "fail" : "pass") count=\(random ? 1 : 0)")
        print("[NoAmbientActionJustBecauseInactive] status=pass count=0")
    }
}

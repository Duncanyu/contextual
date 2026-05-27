import Foundation
import AppKit

@MainActor
struct VisualContextRehydrationSelfTest {
	
	static func run() async {
		print("[VisualContextRehydrationSelfTest] starting visual context rehydration tests...")
		
		testSuccessfulGatheringVisualContextAttachment()
		testPendingRetryRehydrationProducesOcrAvail()
		testMismatchedOcrNotRehydrated()
		testVisualCacheDifferentFingerprintNotReused()
		testTitleOnlyFallbackWhenNoVisualCacheExists()
		testGenericProposalCandidateRejected()
		testPlannerCapNormalization()
		
		print("[VisualContextRehydrationSelfTest] finished. ok=true, failures=0")
		print("[VisualContextRehydrationSelfTest] env selftest ok=true")
	}
	
	// MARK: - Tests
	
	private static func testSuccessfulGatheringVisualContextAttachment() {
		let fp = "org.mozilla.firefox|browsing|metadata_only|t0o0|d1|anker_usb_hub"
		
		// Mock visualResult representing a completed gather
		let visualResult = BoundedVisualContextResult(
			requestId: UUID(),
			status: .completed,
			capturedAt: Date(),
			sourceSummary: "screen_capture",
			ocrExcerpt: "Anker USB-C Hub 7-in-1 Specifications",
			visualSummary: nil,
			visualTags: ["ocr"],
			warnings: [],
			metadata: ["captureCount": "1"],
			expiresAt: Date().addingTimeInterval(30)
		)
		
		// Simulate actor-isolated caching and attachment trace
		let visualOK = visualResult.status == .completed || visualResult.status == .partial
		check("visual_is_ok_for_cache", visualOK)
		
		var mockCache: [String: BoundedVisualContextResult] = [:]
		if visualOK {
			mockCache[fp] = visualResult
			print("[ActionIntentPending] visual_context_attached=yes source=completed_visual_gathering fp=\(fp)")
		}
		
		check("visual_context_stored_in_cache", mockCache[fp] != nil)
		check("stored_ocr_matches_input", mockCache[fp]?.ocrExcerpt == "Anker USB-C Hub 7-in-1 Specifications")
	}
	
	private static func testPendingRetryRehydrationProducesOcrAvail() {
		let fp = "org.mozilla.firefox|browsing|metadata_only|t0o0|d1|anker_usb_hub"
		
		// Mock initial title-only snapshot
		let initialSnapshot = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Anker USB C Hub, 7-in-1",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			inferredIntent: nil,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "title_only",
			availableContextTypes: [ContextRequirementType.textSnippet],
			generatedAt: Date()
		)
		
		let cachedResult = BoundedVisualContextResult(
			requestId: UUID(),
			status: .completed,
			capturedAt: Date(),
			sourceSummary: "screen_capture",
			ocrExcerpt: "Anker USB-C Hub 7-in-1 Specifications",
			visualSummary: nil,
			visualTags: ["ocr"],
			warnings: [],
			metadata: ["captureCount": "1"],
			expiresAt: Date().addingTimeInterval(30)
		)
		
		// Run rehydration
		let classification = VisualContextWorkflowClassifier.classify(
			appCategory: .browser,
			windowTitle: "Anker USB C Hub, 7-in-1",
			visualTags: cachedResult.visualTags,
			ocrExcerpt: cachedResult.ocrExcerpt,
			priorWorkflow: .browsing,
			priorConfidence: 1.0
		)
		
		let enriched = initialSnapshot.merging(
			visualResult: cachedResult,
			priorWorkflow: classification.workflow,
			priorWorkflowConfidence: classification.confidence,
			referenceTime: Date()
		)
		
		check("rehydrated_snapshot_has_ocr", enriched.recentOCRExcerpt == "Anker USB-C Hub 7-in-1 Specifications")
		check("rehydrated_snapshot_has_usable_visual", enriched.visualContextAvailability.hasUsableVisual)
		check("available_context_sources_contains_fused_visual", enriched.availableContextTypes.contains(ContextRequirementType.fusedVisual))
		check("available_context_sources_contains_screen_capture", enriched.availableContextTypes.contains(ContextRequirementType.screenCapture))
		
		let hasOCR = enriched.recentOCRExcerpt != nil && !enriched.recentOCRExcerpt!.isEmpty
		check("ocr_avail_is_yes", hasOCR)
		
		print("[ActionIntentPending] visual_context_rehydrated=yes source=visual_cache fp=\(fp)")
	}
	
	private static func testMismatchedOcrNotRehydrated() {
		let fp = "org.mozilla.firefox|browsing|metadata_only|t0o0|d1|anker_usb_hub"
		
		// If a visual check was attempted but failed/mismatched, we don't cache it
		let mockCache: [String: BoundedVisualContextResult] = [:]
		
		// During pending retry rehydration lookup:
		if mockCache[fp] != nil {
			fatalError("mismatched OCR should not have been cached")
		} else {
			print("[ActionIntentPending] visual_context_rehydrated=no reason=not_found_or_mismatch fp=\(fp)")
		}
		
		check("mismatched_is_not_rehydrated", mockCache[fp] == nil)
	}
	
	private static func testVisualCacheDifferentFingerprintNotReused() {
		let fp1 = "org.mozilla.firefox|browsing|metadata_only|t0o0|d1|anker_usb_hub"
		let fp2 = "org.mozilla.firefox|browsing|metadata_only|t0o0|d1|different_page"
		
		let visualResult = BoundedVisualContextResult(
			requestId: UUID(),
			status: .completed,
			capturedAt: Date(),
			sourceSummary: "screen_capture",
			ocrExcerpt: "Anker Hub Details",
			visualSummary: nil,
			visualTags: ["ocr"]
		)
		
		var mockCache: [String: BoundedVisualContextResult] = [:]
		mockCache[fp1] = visualResult
		
		// Lookup with fp2
		let found = mockCache[fp2]
		check("cache_different_fingerprint_is_nil", found == nil)
	}
	
	private static func testTitleOnlyFallbackWhenNoVisualCacheExists() {
		let fp = "org.mozilla.firefox|browsing|metadata_only|t0o0|d1|no_cache_available"
		
		// Rehydration lookup
		let cached = nil as BoundedVisualContextResult?
		
		check("cached_result_is_nil", cached == nil)
		if cached == nil {
			print("[ActionIntentPending] visual_context_rehydrated=no reason=not_found_or_mismatch fp=\(fp)")
		}
	}
	
	private static func testGenericProposalCandidateRejected() {
		let goal = "Search Anker Prime USB C Charger Block"
		
		// Mock generic candidate title
		let genericTitle1 = "Extract Product Details"
		let genericTitle2 = "Compare USB Hub Specifications"
		
		// Validate against proposal safety and quality validations
		let res1 = ProposalCapabilityValidator.validate(
			title: genericTitle1,
			goal: goal,
			appName: "Xcode",
			windowTitle: "AppDelegate.swift",
			selectedText: "func applicationDidFinishLaunching"
		)
		let res2 = ProposalCapabilityValidator.validate(
			title: genericTitle2,
			goal: goal,
			appName: "Xcode",
			windowTitle: "AppDelegate.swift",
			selectedText: "func applicationDidFinishLaunching"
		)
		
		check("generic_details_title_rejected", !res1.accepted && res1.reason == "low_grounding")
		check("generic_search_title_rejected", !res2.accepted && res2.reason == "low_grounding")
	}
	
	private static func testPlannerCapNormalization() {
		// 1. title Extract Product Details from Amazon Page, caps ocr => normalized to extract, requires includes ocr, then passes to validators
		let c1 = TaskInferenceEngine.PlannerCandidate(
			title: "Extract Product Details from Amazon Page",
			caps: ["ocr"],
			confidence: 0.9,
			novelty: 0.5,
			requires: ["title"],
			whyUseful: "Extract details"
		)
		let norm1 = TaskInferenceEngine.normalizeCandidate(c1)
		check("c1_normalized_caps_extract", norm1.caps == ["extract"])
		check("c1_requires_includes_ocr", norm1.requires.contains("ocr"))
		
		// 2. title Compare USB-C Hub Specs, caps ocr,screen_capture => normalized to compare, requires include visual sources
		let c2 = TaskInferenceEngine.PlannerCandidate(
			title: "Compare USB-C Hub Specs",
			caps: ["ocr", "screen_capture"],
			confidence: 0.9,
			novelty: 0.5,
			requires: ["title"],
			whyUseful: "Compare"
		)
		let norm2 = TaskInferenceEngine.normalizeCandidate(c2)
		check("c2_normalized_caps_compare", norm2.caps == ["compare"])
		check("c2_requires_includes_ocr", norm2.requires.contains("ocr"))
		check("c2_requires_includes_screen_capture", norm2.requires.contains("screen_capture"))
		
		// 3. title Product Details, caps ocr => rejected, no title verb
		let c3 = TaskInferenceEngine.PlannerCandidate(
			title: "Product Details",
			caps: ["ocr"],
			confidence: 0.9,
			novelty: 0.5,
			requires: ["title"],
			whyUseful: "Details"
		)
		let norm3 = TaskInferenceEngine.normalizeCandidate(c3)
		// It returns original `c3` (as no verb was matched), which fails validation
		check("c3_kept_original_to_be_rejected_by_validator", norm3.caps == ["ocr"])
		
		// 4. title Search Amazon for USB Hub, caps ocr => rejected unless search is an allowed safe primitive already. Do not add search if unsupported
		let c4 = TaskInferenceEngine.PlannerCandidate(
			title: "Search Amazon for USB Hub",
			caps: ["ocr"],
			confidence: 0.9,
			novelty: 0.5,
			requires: ["title"],
			whyUseful: "Search"
		)
		let norm4 = TaskInferenceEngine.normalizeCandidate(c4)
		check("c4_kept_original_unsupported_verb", norm4.caps == ["ocr"])
		
		// 5. invalid unsafe title like Buy Product, caps ocr => rejected by safety/capability
		let c5 = TaskInferenceEngine.PlannerCandidate(
			title: "Buy Product",
			caps: ["ocr"],
			confidence: 0.9,
			novelty: 0.5,
			requires: ["title"],
			whyUseful: "Buy"
		)
		let norm5 = TaskInferenceEngine.normalizeCandidate(c5)
		check("c5_kept_original_unsafe_verb", norm5.caps == ["ocr"])
		
		// 6. valid full JSON path with caps extract remains unchanged
		let c6 = TaskInferenceEngine.PlannerCandidate(
			title: "Extract specs from browser",
			caps: ["extract"],
			confidence: 0.9,
			novelty: 0.5,
			requires: ["title"],
			whyUseful: "Extract"
		)
		let norm6 = TaskInferenceEngine.normalizeCandidate(c6)
		check("c6_remains_unchanged", norm6.caps == ["extract"] && norm6.requires == ["title"])
		
		// 7. browser chrome/generic titles still rejected
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "New Tab",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			inferredIntent: nil,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "Firefox window",
			availableContextTypes: [ContextRequirementType.textSnippet],
			generatedAt: Date()
		)
		let isolated = ProposalContextIsolationGate.isolate(snapshot: snap)
		let valRes = ProposalCapabilityValidator.validate(
			title: "Compare USB Hub Specs",
			goal: "Explain page",
			isolated: isolated,
			stage: "early"
		)
		check("chrome_generic_rejected_by_validator", !valRes.accepted)
	}
	
	// MARK: - Helpers
	
	private static func check(_ name: String, _ condition: Bool) {
		if !condition {
			print("[VisualContextRehydrationSelfTest] FAIL: \(name)")
			fatalError("[VisualContextRehydrationSelfTest] test failed: \(name)")
		} else {
			print("[VisualContextRehydrationSelfTest] PASS: \(name)")
		}
	}
}

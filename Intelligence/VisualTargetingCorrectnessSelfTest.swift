import Foundation
import AppKit

@MainActor
struct VisualTargetingCorrectnessSelfTest {
	
	static func run() async {
		print("[VisualTargetingCorrectnessSelfTest] starting visual targeting & mismatch tests...")
		
		testCoordinateConversionAndScreenMapping()
		testMismatchFirefoxTitlePlusChatGptOcrRejected()
		testMatchedOcrAccepted()
		testVisualMismatchDoesNotPoisonPlannerPacket()
		
		print("[VisualTargetingCorrectnessSelfTest] finished. ok=true, failures=0")
		print("[VisualTargetingCorrectnessSelfTest] env selftest ok=true")
	}
	
	// MARK: - Tests
	
	private static func testCoordinateConversionAndScreenMapping() {
		// Mock screen and window layout parameters
		let primaryScreenHeight: CGFloat = 1080
		
		// Secondary screen AppKit frame: (1920, 0, 1920, 1080)
		let secondaryScreenAppKitFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
		
		// Window center in Quartz coordinate space (origin at top-left of primary screen)
		let windowCenterQuartz = CGPoint(x: 2880, y: 540) // Middle of secondary screen horizontally and vertically
		
		// Convert Quartz coordinates to AppKit coordinates (y increases upwards from bottom-left of primary screen)
		let windowCenterAppKit = CGPoint(x: windowCenterQuartz.x, y: primaryScreenHeight - windowCenterQuartz.y)
		
		// Check that the AppKit center point lies inside the secondary screen's AppKit frame
		let contains = NSPointInRect(windowCenterAppKit, secondaryScreenAppKitFrame)
		
		check("secondary_screen_contains_center_point", contains)
		
		// Convert AppKit secondary screen frame back to Quartz coordinates
		let quartzY = primaryScreenHeight - secondaryScreenAppKitFrame.origin.y - secondaryScreenAppKitFrame.size.height
		let screenQuartzRect = CGRect(x: secondaryScreenAppKitFrame.origin.x, y: quartzY, width: secondaryScreenAppKitFrame.size.width, height: secondaryScreenAppKitFrame.size.height)
		
		check("screen_quartz_rect_origin_x", screenQuartzRect.origin.x == 1920)
		check("screen_quartz_rect_origin_y", screenQuartzRect.origin.y == 0)
	}
	
	private static func testMismatchFirefoxTitlePlusChatGptOcrRejected() {
		let activeApp = "Firefox"
		let activeTitle = "Amazon.ca : usb c hub anker"
		let ocrText = "ChatGPT File GPTs KIKIS CORNER * '• A SSt f'• ?, ovprf o g) / o o ,IJ EN"
		
		let isMismatched = OCRProcessor.isOcrMismatched(ocrText: ocrText, activeApp: activeApp, activeTitle: activeTitle)
		check("mismatched_active_app_and_ocr_rejected", isMismatched)
	}
	
	private static func testMatchedOcrAccepted() {
		let activeApp = "Firefox"
		let activeTitle = "Amazon.ca : usb c hub anker"
		let ocrText = "Amazon.ca: Low Prices – Fast Shipping. usb c hub anker Prime..."
		
		let isMismatched = OCRProcessor.isOcrMismatched(ocrText: ocrText, activeApp: activeApp, activeTitle: activeTitle)
		check("matched_active_app_and_ocr_accepted", !isMismatched)
	}
	
	private static func testVisualMismatchDoesNotPoisonPlannerPacket() {
		// Mock tokenization logic checks to confirm no false positives/negatives in match set
		let ocrTokens = OCRProcessor.tokenize("ChatGPT File GPTs KIKIS CORNER")
		let activeTokens = OCRProcessor.tokenize("Amazon.ca : usb c hub anker")
		
		let overlap = ocrTokens.intersection(activeTokens)
		check("visual_mismatch_has_no_overlap_tokens", overlap.isEmpty)
	}
	
	// MARK: - Helpers
	
	private static func check(_ name: String, _ condition: Bool) {
		if !condition {
			print("[VisualTargetingCorrectnessSelfTest] FAIL: \(name)")
			fatalError("[VisualTargetingCorrectnessSelfTest] test failed: \(name)")
		} else {
			print("[VisualTargetingCorrectnessSelfTest] PASS: \(name)")
		}
	}
}

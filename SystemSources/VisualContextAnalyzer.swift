import AppKit
import CoreGraphics
import CoreImage
import Foundation

final class VisualContextAnalyzer {
	static let shared = VisualContextAnalyzer()

	private let ciContext = CIContext(options: [
		.cacheIntermediates: false,
		.priorityRequestLow: true,
		.useSoftwareRenderer: false
	])

	private init() {}

	func analyze(snapshot: WindowSnapshotContext) -> VisualContextDescriptor? {
		// Freshness gate (descriptor can still be created but marked stale).
		let age = Date().timeIntervalSince(snapshot.capturedAt)
		let isStale = age > VisualContextDescriptor.recommendedFreshnessSeconds

		guard let features = extractFeatures(from: snapshot.image) else {
			print("[VisualContext] skipped reason=analysis_failed")
			return nil
		}

		let hints = makeAppHints(appName: snapshot.appName, bundleId: snapshot.bundleIdentifier)
		let scored = classify(features: features, appHints: hints)

		let kinds = scored.kinds.isEmpty ? [.unknown] : scored.kinds
		let conf = max(0.0, min(1.0, scored.confidence))

		let descriptor = VisualContextDescriptor(
			generatedAt: Date(),
			sourceSnapshotID: snapshot.id,
			confidence: conf,
			visibleUIKinds: kinds,
			estimatedTextDensity: features.edgeDensity,
			estimatedVisualDensity: features.visualSmoothness,
			estimatedPanelCount: features.estimatedPanelCount,
			likelyScrollable: features.likelyScrollable,
			dominantLayoutStyle: features.dominantLayoutStyle,
			containsLargeMonospaceRegion: features.containsLargeMonospaceRegion,
			containsLargeImageRegion: features.containsLargeImageRegion,
			containsDialogLikeRegion: features.containsDialogLikeRegion,
			containsToolbarLikeRegion: features.containsToolbarLikeRegion,
			isStale: isStale,
			metadata: [
				"w": "\(snapshot.imageWidth)",
				"h": "\(snapshot.imageHeight)"
			],
			sourceAppHints: hints.isEmpty ? nil : hints
		)

		let kindsLabel = kinds.map(\.rawValue).joined(separator: ",")
		let c = String(format: "%.2f", conf)
		print("[VisualContext] analyzed kinds=\(kindsLabel) conf=\(c)")
		return descriptor
	}

	// MARK: - Feature extraction

	private struct ImageFeatures {
		let edgeDensity: Double
		let visualSmoothness: Double
		let estimatedPanelCount: Int
		let likelyScrollable: Bool
		let dominantLayoutStyle: VisualDominantLayoutStyle
		let containsLargeMonospaceRegion: Bool
		let containsLargeImageRegion: Bool
		let containsDialogLikeRegion: Bool
		let containsToolbarLikeRegion: Bool
	}

	private func extractFeatures(from cgImage: CGImage) -> ImageFeatures? {
		let ci = CIImage(cgImage: cgImage)

		// Downscale aggressively to keep analysis cheap and local.
		let targetMaxSide: CGFloat = 240
		let scale = min(targetMaxSide / ci.extent.width, targetMaxSide / ci.extent.height, 1.0)
		let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

		guard let gray = scaled.applyingFilter("CIColorControls", parameters: [
			kCIInputSaturationKey: 0.0,
			kCIInputContrastKey: 1.0
		]) as CIImage? else { return nil }

		// Edge density proxy (high frequency detail -> text-ish / UI-heavy).
		let edges = gray.applyingFilter("CIEdges", parameters: ["inputIntensity": 1.0])
		guard let edgeMean = areaMeanIntensity(edges) else { return nil }
		let edgeDensity = clamp01(edgeMean * 2.2) // heuristic scaling

		// Smoothness proxy (low edges + low variance -> likely imagery / large regions).
		let blurred = gray.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2.2])
		guard let blurMean = areaMeanIntensity(blurred) else { return nil }
		let visualSmoothness = clamp01((1.0 - edgeDensity) * 0.7 + blurMean * 0.3)

		// Coarse grid energy to estimate panels/layout (simple, no OCR).
		let grid = coarseGridEnergy(gray, rows: 6, cols: 10)
		let panelCount = estimatePanels(from: grid)
		let layoutStyle = dominantLayout(from: grid)

		// Heuristics for scrollable: repeated horizontal structure + moderate edge density.
		let likelyScrollable = (grid.verticalBandVariance > 0.08 && edgeDensity > 0.22)

		// Monospace-ish proxy: many thin vertical edges + mid edge density (typical for code/terminal).
		let containsLargeMonospaceRegion = (grid.verticalEdgeBias > 0.18 && edgeDensity > 0.28)

		// Image region proxy: large smoothness + low edge density.
		let containsLargeImageRegion = (visualSmoothness > 0.68 && edgeDensity < 0.22)

		// Dialog proxy: central concentration + low panel count.
		let containsDialogLikeRegion = (panelCount <= 2 && grid.centerEnergy > 0.55 && edgeDensity > 0.18)

		// Toolbar proxy: strong energy band near top.
		let containsToolbarLikeRegion = (grid.topBandEnergy > 0.62 && grid.topBandEnergy - grid.centerEnergy > 0.12)

		return ImageFeatures(
			edgeDensity: edgeDensity,
			visualSmoothness: visualSmoothness,
			estimatedPanelCount: panelCount,
			likelyScrollable: likelyScrollable,
			dominantLayoutStyle: layoutStyle,
			containsLargeMonospaceRegion: containsLargeMonospaceRegion,
			containsLargeImageRegion: containsLargeImageRegion,
			containsDialogLikeRegion: containsDialogLikeRegion,
			containsToolbarLikeRegion: containsToolbarLikeRegion
		)
	}

	private func areaMeanIntensity(_ image: CIImage) -> Double? {
		let extent = image.extent
		let mean = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
		var pixel = [UInt8](repeating: 0, count: 4)
		ciContext.render(mean, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
		// Mean intensity of RGB (avoid logging content).
		let r = Double(pixel[0]) / 255.0
		let g = Double(pixel[1]) / 255.0
		let b = Double(pixel[2]) / 255.0
		return (r + g + b) / 3.0
	}

	private struct GridStats {
		let cells: [Double] // row-major, already 0...1
		let rows: Int
		let cols: Int
		let topBandEnergy: Double
		let centerEnergy: Double
		let verticalBandVariance: Double
		let verticalEdgeBias: Double
	}

	private func coarseGridEnergy(_ gray: CIImage, rows: Int, cols: Int) -> GridStats {
		let e = gray.extent
		let cellW = e.width / CGFloat(cols)
		let cellH = e.height / CGFloat(rows)
		var cells: [Double] = []
		cells.reserveCapacity(rows * cols)

		// Sample per-cell brightness mean; we interpret variation as layout structure.
		for r in 0..<rows {
			for c in 0..<cols {
				let rect = CGRect(
					x: e.origin.x + CGFloat(c) * cellW,
					y: e.origin.y + CGFloat(r) * cellH,
					width: cellW,
					height: cellH
				)
				let cell = gray.cropped(to: rect)
				let m = areaMeanIntensity(cell) ?? 0.0
				cells.append(clamp01(m))
			}
		}

		let topBand = bandEnergy(cells: cells, rows: rows, cols: cols, rowRange: 0..<max(1, rows / 6))
		let center = bandEnergy(cells: cells, rows: rows, cols: cols, rowRange: (rows / 3)..<(2 * rows / 3))

		// Variance across column means (useful for columnar / scrollable layouts).
		var colMeans: [Double] = []
		colMeans.reserveCapacity(cols)
		for c in 0..<cols {
			var sum = 0.0
			for r in 0..<rows {
				sum += cells[r * cols + c]
			}
			colMeans.append(sum / Double(rows))
		}
		let vVar = variance(colMeans)

		// Vertical edge bias proxy: variance across adjacent columns.
		var diffs: [Double] = []
		diffs.reserveCapacity(max(0, cols - 1))
		for c in 0..<(cols - 1) {
			diffs.append(abs(colMeans[c + 1] - colMeans[c]))
		}
		let vEdgeBias = diffs.isEmpty ? 0.0 : clamp01(diffs.reduce(0.0, +) / Double(diffs.count) * 3.0)

		return GridStats(
			cells: cells,
			rows: rows,
			cols: cols,
			topBandEnergy: clamp01(topBand),
			centerEnergy: clamp01(center),
			verticalBandVariance: clamp01(vVar * 6.0),
			verticalEdgeBias: vEdgeBias
		)
	}

	private func bandEnergy(cells: [Double], rows: Int, cols: Int, rowRange: Range<Int>) -> Double {
		let rr = max(0, rowRange.lowerBound)..<min(rows, rowRange.upperBound)
		if rr.isEmpty { return 0.0 }
		var sum = 0.0
		var n = 0
		for r in rr {
			for c in 0..<cols {
				sum += cells[r * cols + c]
				n += 1
			}
		}
		return n == 0 ? 0.0 : sum / Double(n)
	}

	private func estimatePanels(from grid: GridStats) -> Int {
		// Panel proxy: more column variance + higher edge bias suggests multi-pane layouts.
		if grid.verticalBandVariance > 0.18 && grid.verticalEdgeBias > 0.22 { return 3 }
		if grid.verticalBandVariance > 0.12 { return 2 }
		return 1
	}

	private func dominantLayout(from grid: GridStats) -> VisualDominantLayoutStyle {
		if grid.verticalBandVariance > 0.18 { return .columns }
		if grid.centerEnergy > 0.62 && grid.verticalBandVariance < 0.08 { return .singlePane }
		if grid.verticalBandVariance > 0.12 { return .multiPane }
		return .unknown
	}

	// MARK: - Classification

	private struct ClassificationResult {
		let kinds: [VisualUIKind]
		let confidence: Double
	}

	private func classify(features: ImageFeatures, appHints: [String: String]) -> ClassificationResult {
		var kinds: [VisualUIKind] = []
		var conf: Double = 0.45

		if features.containsDialogLikeRegion {
			kinds.append(.dialog)
			conf += 0.10
		}
		if features.containsLargeImageRegion {
			kinds.append(.media)
			conf += 0.10
		}

		// Editor/terminal proxies lean on monospace + edge density; app hint is weak additive.
		if features.containsLargeMonospaceRegion {
			kinds.append(.editor)
			conf += 0.12
			if appHints["category"] == "developer" {
				conf += 0.05
			}
		}

		if features.edgeDensity > 0.34 && features.estimatedPanelCount >= 2 {
			if !kinds.contains(.browser) {
				kinds.append(.browser)
			}
			conf += 0.06
		}

		// Article-like: high edge density but low panel count + likely scroll.
		if features.edgeDensity > 0.30 && features.estimatedPanelCount == 1 && features.likelyScrollable {
			kinds.append(.article)
			conf += 0.08
		}

		// Chart proxy: mid edge density + low smoothness + multi-pane / grid-ish.
		if features.edgeDensity > 0.22 && features.edgeDensity < 0.38 && !features.containsLargeImageRegion && features.estimatedPanelCount >= 2 {
			kinds.append(.chart)
			conf += 0.05
		}

		// Terminal proxy: strong vertical edge bias + monospace + darker mean often (we don't compute mean; keep heuristic conservative).
		if features.containsLargeMonospaceRegion && features.edgeDensity > 0.36 {
			kinds.append(.terminal)
			conf += 0.05
		}

		// Form proxy: toolbar + multi-pane-ish + moderate density.
		if features.containsToolbarLikeRegion && features.edgeDensity > 0.20 && features.edgeDensity < 0.34 && features.estimatedPanelCount >= 2 {
			kinds.append(.form)
			conf += 0.04
		}

		// Dedup while preserving order.
		var seen = Set<VisualUIKind>()
		kinds = kinds.filter { seen.insert($0).inserted }

		return ClassificationResult(kinds: kinds, confidence: clamp01(conf))
	}

	private func makeAppHints(appName: String?, bundleId: String?) -> [String: String] {
		guard let bundleId else { return [:] }
		let lower = bundleId.lowercased()
		if lower.contains("xcode") || lower.contains("jetbrains") || lower.contains("vscode") {
			return ["category": "developer", "bundle": bundleId, "app": appName ?? ""]
		}
		if lower.contains("safari") || lower.contains("chrome") || lower.contains("firefox") {
			return ["category": "browser", "bundle": bundleId, "app": appName ?? ""]
		}
		return ["bundle": bundleId, "app": appName ?? ""]
	}

	private func variance(_ values: [Double]) -> Double {
		guard !values.isEmpty else { return 0.0 }
		let mean = values.reduce(0.0, +) / Double(values.count)
		let v = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
		return v
	}

	private func clamp01(_ x: Double) -> Double { max(0.0, min(1.0, x)) }
}

#if DEBUG
extension VisualContextAnalyzer {
	/// Manual debug hook. Call from LLDB:
	/// `expr -l Swift -- VisualContextAnalyzer.shared._selfTest()`
	@discardableResult
	func _selfTest() -> Bool {
		guard WindowSnapshotSource.shared.hasScreenRecordingPermission() else {
			print("[VisualContext] skipped reason=permission_denied")
			return false
		}
		guard let snap = WindowSnapshotSource.shared.captureActiveWindowSnapshot() else {
			print("[VisualContext] skipped reason=no_snapshot")
			return false
		}
		return analyze(snapshot: snap) != nil
	}
}
#endif


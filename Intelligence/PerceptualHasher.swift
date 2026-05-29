import CoreGraphics
import CoreImage
import Foundation

// MARK: - PerceptualHasher

/// Computes perceptual hashes (DCT-based pHash) from CGImage for visual delta detection.
///
/// ## Algorithm (standard pHash)
/// 1. Scale image to 32×32 grayscale
/// 2. Compute separable 2D DCT-II
/// 3. Extract top-left 8×8 frequency block (lowest spatial frequencies)
/// 4. Compute mean of 63 coefficients (DC component excluded)
/// 5. Build 64-bit hash: bit[i] = 1 if coeff[i] > mean
///
/// ## Hamming distance interpretation
/// - 0–8 bits:   near-identical (same frame, tiny render tick)
/// - 9–16 bits:  minor change  (small text edit, cursor move, progress indicator)
/// - 17–28 bits: moderate change (scroll, element appear/disappear, panel expand)
/// - 29+ bits:   major change  (page navigation, modal, full content switch)
///
/// ## Performance
/// CoreImage resize + pure-Swift 32×32 DCT: < 2ms on Apple Silicon.
/// CGImage.cropping() for quadrant split is zero-copy (subrect on existing buffer).
///
/// No Accelerate framework required — uses CIImage for downscale+grayscale,
/// pure Swift for the DCT pass.
enum PerceptualHasher {

    // MARK: - Primary hash

    /// Compute a 64-bit perceptual hash of the full image.
    /// Returns 0 if image processing fails (caller should treat as "unknown, assume changed").
    static func hash(_ image: CGImage) -> UInt64? {
        guard let pixels = extractGrayscalePixels(image, side: 32) else { return nil }
        return computePHash(pixels: pixels, side: 32)
    }

    // MARK: - Quadrant hashes

    /// Compute pHashes for a 2×2 quadrant split of the image.
    /// Returns 4 values: [topLeft, topRight, bottomLeft, bottomRight].
    /// Useful for localising *where* on screen a visual change occurred.
    static func quadrantHashes(_ image: CGImage) -> [UInt64] {
        let w = image.width
        let h = image.height
        // Images too small to split sensibly — return the same hash in all slots.
        guard w >= 64, h >= 64 else {
            let h = hash(image) ?? 0
            return [h, h, h, h]
        }
        let qw = w / 2
        let qh = h / 2
        var result: [UInt64] = []
        result.reserveCapacity(4)
        for row in 0..<2 {
            for col in 0..<2 {
                let rect = CGRect(x: col * qw, y: row * qh, width: qw, height: qh)
                if let cropped = image.cropping(to: rect), let h = hash(cropped) {
                    result.append(h)
                } else {
                    result.append(0)
                }
            }
        }
        return result
    }

    // MARK: - Distance

    /// Hamming distance between two pHashes (number of differing bits, 0–64).
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        var diff = a ^ b
        var count = 0
        while diff != 0 {
            count &+= 1
            diff &= diff &- 1   // clear lowest set bit (Kernighan's method)
        }
        return count
    }

    /// Whether two pHashes represent visually similar content.
    /// Default threshold 12 is empirically tuned for macOS GUI screenshots
    /// (tolerates sub-pixel antialiasing, cursor blink, minor badge updates).
    static func areSimilar(_ a: UInt64, _ b: UInt64, threshold: Int = 12) -> Bool {
        hammingDistance(a, b) <= threshold
    }

    // MARK: - Quadrant delta classification

    /// Classify which screen region changed by comparing two sets of quadrant hashes.
    static func classifyQuadrantDelta(
        previous: [UInt64],
        current:  [UInt64],
        threshold: Int = 12
    ) -> QuadrantDelta {
        guard previous.count == 4, current.count == 4 else {
            return QuadrantDelta(changedQuadrants: [], region: .unknown, anyChanged: false)
        }
        let labels = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
        var changed: [String] = []
        for i in 0..<4 where !areSimilar(previous[i], current[i], threshold: threshold) {
            changed.append(labels[i])
        }
        let region = classifyRegion(Set(changed))
        return QuadrantDelta(
            changedQuadrants: changed,
            region:           region,
            anyChanged:       !changed.isEmpty
        )
    }

    struct QuadrantDelta: Sendable {
        let changedQuadrants: [String]   // which of [topLeft, topRight, bottomLeft, bottomRight]
        let region:           ChangeRegion
        let anyChanged:       Bool

        var description: String {
            changedQuadrants.isEmpty ? "no_change" : changedQuadrants.joined(separator: "+")
        }
    }

    enum ChangeRegion: String, Sendable {
        case topHalf       // navigation bar refresh, new page loaded at top
        case bottomHalf    // content scrolled in below the fold
        case leftSide      // sidebar / panel open-close
        case rightSide     // inspector / sidebar on right
        case center        // modal, dialog, popover appeared
        case full          // full-page transition (navigation)
        case partial       // mixed / diagonal change
        case unknown
    }

    // MARK: - Private helpers

    private static func classifyRegion(_ s: Set<String>) -> ChangeRegion {
        if s.isEmpty                                        { return .unknown }
        if s.count == 4                                     { return .full }
        let top    = s.contains("topLeft")    || s.contains("topRight")
        let bottom = s.contains("bottomLeft") || s.contains("bottomRight")
        let left   = s.contains("topLeft")    || s.contains("bottomLeft")
        let right  = s.contains("topRight")   || s.contains("bottomRight")
        if top    && !bottom { return .topHalf }
        if bottom && !top    { return .bottomHalf }
        if left   && !right  { return .leftSide }
        if right  && !left   { return .rightSide }
        if s.count == 2 && s.contains("topRight") && s.contains("bottomLeft") { return .center }
        return .partial
    }

    // MARK: - Pixel extraction

    /// Render a CGImage as `side×side` grayscale Float pixel array.
    /// Uses CIImage for hardware-accelerated downscale + desaturation.
    private static func extractGrayscalePixels(_ image: CGImage, side: Int) -> [Float]? {
        let ci = CIImage(cgImage: image)
        guard ci.extent.width > 0, ci.extent.height > 0 else { return nil }

        let sx = CGFloat(side) / ci.extent.width
        let sy = CGFloat(side) / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        guard let gray = scaled.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 0.0]
        ) as CIImage? else { return nil }

        let ctx = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
        let n = side * side
        var rgba = [UInt8](repeating: 0, count: n * 4)
        ctx.render(
            gray,
            toBitmap:   &rgba,
            rowBytes:   side * 4,
            bounds:     CGRect(x: 0, y: 0, width: side, height: side),
            format:     .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Red channel == gray value after full desaturation
        var result = [Float](repeating: 0, count: n)
        for i in 0..<n { result[i] = Float(rgba[i * 4]) / 255.0 }
        return result
    }

    // MARK: - DCT pHash

    /// Build a 64-bit pHash from a `side×side` grayscale Float pixel grid.
    private static func computePHash(pixels: [Float], side: Int) -> UInt64 {
        let dct   = compute2DDCT(pixels: pixels, side: side)
        let block = extractTopLeft8x8(dct: dct, stride: side)

        // Mean of 63 AC coefficients (skip DC at index 0 — it dominates and is uninformative)
        let ac = block.dropFirst()
        let mean = ac.reduce(0, +) / Float(ac.count)

        var hash: UInt64 = 0
        for (i, v) in block.enumerated() where v > mean {
            hash |= (1 << i)
        }
        return hash
    }

    /// Separable 2D DCT-II: rows then columns.
    private static func compute2DDCT(pixels: [Float], side: Int) -> [Float] {
        var result = pixels   // copy — mutated in-place

        // DCT over rows
        var buf = [Float](repeating: 0, count: side)
        for r in 0..<side {
            for c in 0..<side { buf[c] = result[r * side + c] }
            let row = dct1D(buf, n: side)
            for c in 0..<side { result[r * side + c] = row[c] }
        }

        // DCT over columns
        for c in 0..<side {
            for r in 0..<side { buf[r] = result[r * side + c] }
            let col = dct1D(buf, n: side)
            for r in 0..<side { result[r * side + c] = col[r] }
        }

        return result
    }

    /// 1D DCT-II: O(N²) — acceptable for N=32 (1024 ops per vector).
    private static func dct1D(_ input: [Float], n: Int) -> [Float] {
        let piOverN = Float.pi / Float(n)
        var output  = [Float](repeating: 0, count: n)
        for k in 0..<n {
            var sum: Float = 0
            let kp = Float(k)
            for i in 0..<n {
                sum += input[i] * cos(piOverN * kp * (Float(i) + 0.5))
            }
            output[k] = sum
        }
        return output
    }

    /// Extract the top-left 8×8 block from a `stride`-wide 2D array, row-major.
    private static func extractTopLeft8x8(dct: [Float], stride: Int) -> [Float] {
        var block = [Float]()
        block.reserveCapacity(64)
        for r in 0..<8 {
            for c in 0..<8 {
                block.append(dct[r * stride + c])
            }
        }
        return block
    }
}

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lightweight vision-first grounding model coordinator.
/// Uses the local Ollama vision model to locate elements on screenshots.
struct VisualGrounder: Sendable {

    struct GroundedRegion: Sendable {
        let x1: Double
        let y1: Double
        let x2: Double
        let y2: Double
        let center: CGPoint
    }

    /// Typed outcome of a grounding attempt — callers must distinguish timeout from
    /// other failures so they do not fall back to AX on a slow-model stall.
    enum GroundingOutcome: Sendable {
        case grounded(GroundedRegion)
        /// The VLM request exceeded the hard timeout. AX fallback is NOT safe.
        case timedOut
        /// The model is offline, missing, or returned unparseable output.
        case unavailable(reason: String)
    }

    /// Hard wall-clock limit for a single grounding request (milliseconds).
    static let timeoutMs: Int = 1500

    /// Ground a visual instruction on a screenshot and return the coordinates mapped to
    /// AppKit screen points. Returns `(outcome, rawResponse)` — the raw model string is
    /// surfaced for smoke-test diagnostics; production callers can ignore it.
    static func ground(
        image: CGImage,
        instruction: String,
        targetRect: CGRect?
    ) async -> (outcome: GroundingOutcome, rawResponse: String?) {
        print("[VisualGrounding] started instruction=\"\(instruction)\"")

        // 1. Discover vision model (fast default: moondream, never minicpm-v by default)
        guard let model = await discoverVisionModel() else {
            print("[VisualGrounding] unavailable reason=no_vision_model_installed")
            return (.unavailable(reason: "no_vision_model_installed"), nil)
        }

        // 2. Downscale screenshot to keep inference fast
        guard let downscaled = downscale(image, toMaxDimension: 1000) else {
            print("[VisualGrounding] failed reason=downscale_failed")
            return (.unavailable(reason: "downscale_failed"), nil)
        }
        print("[VisualGrounding] screenshot_scaled=\(downscaled.width)x\(downscaled.height)")

        // 3. Convert to compact JPEG string
        guard let base64Image = cgImageToBase64JPEG(downscaled, compressionQuality: 0.4) else {
            print("[VisualGrounding] failed reason=jpeg_encode_failed")
            return (.unavailable(reason: "jpeg_encode_failed"), nil)
        }

        // 4. Dispatch specialized grounding query
        let prompt = """
        SYSTEM:
        You locate UI elements on screenshots.

        USER:
        Find the approximate region containing:
        "\(instruction)"

        Return ONLY:
        x1,y1,x2,y2
        """

        let timeoutSeconds = Double(timeoutMs) / 1000.0
        print("[VisualGrounding] timeout_ms=\(timeoutMs)")

        let start = Date()
        var responseText: String? = nil
        var requestTimedOut = false

        do {
            if let url = URL(string: "http://127.0.0.1:11434/api/generate") {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                struct OllamaVisionRequest: Encodable {
                    let model: String
                    let prompt: String
                    let stream: Bool
                    let images: [String]
                    let options: [String: Double]
                    let keepAlive: String
                    enum CodingKeys: String, CodingKey {
                        case model, prompt, stream, images, options
                        case keepAlive = "keep_alive"
                    }
                }

                let payload = OllamaVisionRequest(
                    model: model,
                    prompt: prompt,
                    stream: false,
                    images: [base64Image],
                    options: ["temperature": 0.1, "num_predict": 20],
                    keepAlive: "10m"
                )
                request.httpBody = try JSONEncoder().encode(payload)
                request.timeoutInterval = timeoutSeconds

                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    struct OllamaVisionResponse: Decodable { let response: String? }
                    if let decoded = try? JSONDecoder().decode(OllamaVisionResponse.self, from: data) {
                        responseText = decoded.response?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        } catch let urlError as URLError where urlError.code == .timedOut {
            requestTimedOut = true
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            print("[VisualGrounding] failed reason=timeout elapsed_ms=\(elapsed)")
        } catch {
            print("[VisualGrounding] failed reason=request_failed error=\(error.localizedDescription)")
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        if requestTimedOut {
            return (.timedOut, nil)
        }

        guard let text = responseText, !text.isEmpty else {
            print("[VisualGrounding] failed reason=empty_response latency_ms=\(latencyMs)")
            return (.unavailable(reason: "empty_response"), responseText)
        }

        print("[VisualGrounding] raw_model_output=\"\(text.prefix(80))\" latency_ms=\(latencyMs)")

        // 5. Robust parse coordinates
        guard let rawCoords = parseCoordinates(from: text) else {
            print("[VisualGrounding] failed reason=coordinate_parsing_failed raw=\"\(text)\"")
            return (.unavailable(reason: "coordinate_parsing_failed"), text)
        }

        // 6. Scale and translate to actual screen points
        let imgWidth = Double(image.width)
        let imgHeight = Double(image.height)
        let center = resolveNormalizedCenter(numbers: rawCoords, imgWidth: imgWidth, imgHeight: imgHeight)

        let captureRect = targetRect ?? CGRect(x: 0, y: 0, width: CGFloat(imgWidth), height: CGFloat(imgHeight))
        let nx = center.x / imgWidth
        let ny = center.y / imgHeight
        let screenX = captureRect.origin.x + CGFloat(nx) * captureRect.width
        let screenY = captureRect.origin.y + CGFloat(ny) * captureRect.height
        let screenCenter = CGPoint(x: screenX, y: screenY)

        print("[VisualGrounding] proposed_region=\(Int(rawCoords.0)),\(Int(rawCoords.1)),\(Int(rawCoords.2)),\(Int(rawCoords.3))")
        print("[VisualGrounding] click_center=\(Int(screenCenter.x)),\(Int(screenCenter.y))")

        let region = GroundedRegion(
            x1: rawCoords.0,
            y1: rawCoords.1,
            x2: rawCoords.2,
            y2: rawCoords.3,
            center: screenCenter
        )
        return (.grounded(region), text)
    }
    
    // MARK: - Internal Helpers
    
    private static func discoverVisionModel() async -> String? {
        do {
            if let url = URL(string: "http://127.0.0.1:11434/api/tags") {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 2.0
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    struct TagsRoot: Codable {
                        struct TagEntry: Codable { let name: String }
                        let models: [TagEntry]
                    }
                    if let root = try? JSONDecoder().decode(TagsRoot.self, from: data) {
                        let names = root.models.map { $0.name.lowercased() }

                        // Env override: CONTEXTUAL_VISUAL_GROUNDER_MODEL=moondream (or any model name prefix)
                        let envOverride = ProcessInfo.processInfo.environment["CONTEXTUAL_VISUAL_GROUNDER_MODEL"]?
                            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                        if !envOverride.isEmpty, let found = names.first(where: { $0.contains(envOverride) }) {
                            print("[VisualGrounding] model_selected=\(found) reason=env_override env=\(envOverride)")
                            return found
                        }

                        // Fast-default priority: moondream → llava → llama3.2-vision → any vision model.
                        // minicpm-v is explicitly LAST — it is too slow for hot click grounding.
                        let fastPriority: [(prefix: String, reason: String)] = [
                            ("moondream",        "fast_default"),
                            ("llava",            "fast_fallback"),
                            ("llama3.2-vision",  "fast_fallback"),
                        ]
                        for (prefix, reason) in fastPriority {
                            if let found = names.first(where: { $0.contains(prefix) }) {
                                print("[VisualGrounding] model_selected=\(found) reason=\(reason)")
                                return found
                            }
                        }
                        // Generic vision tag fallback (excludes minicpm unless it's all that's installed)
                        if let found = names.first(where: { $0.contains("vision") && !$0.contains("minicpm") }) {
                            print("[VisualGrounding] model_selected=\(found) reason=vision_tag_fallback")
                            return found
                        }
                        // Last resort: minicpm-v — only if nothing faster is available
                        if let found = names.first(where: { $0.contains("minicpm") }) {
                            print("[VisualGrounding] model_selected=\(found) reason=slow_last_resort warning=expect_timeout")
                            return found
                        }
                    }
                }
            }
        } catch {}
        return nil
    }
    
    private static func downscale(_ cgImage: CGImage, toMaxDimension maxDim: CGFloat) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > maxDim || height > maxDim else { return cgImage }
        
        let ratio = width / height
        let newWidth: CGFloat
        let newHeight: CGFloat
        if ratio > 1 {
            newWidth = maxDim
            newHeight = maxDim / ratio
        } else {
            newHeight = maxDim
            newWidth = maxDim * ratio
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(newWidth),
            height: Int(newHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
    
    private static func cgImageToBase64JPEG(_ image: CGImage, compressionQuality: Double = 0.4) -> String? {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) else {
            return nil
        }
        return data.base64EncodedString()
    }
    
    static func parseCoordinates(from response: String) -> (x1: Double, y1: Double, x2: Double, y2: Double)? {
        let pattern = "[0-9]+(?:\\.[0-9]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: response, range: NSRange(response.startIndex..., in: response))
        let numbers = matches.compactMap { match -> Double? in
            guard let range = Range(match.range, in: response) else { return nil }
            return Double(response[range])
        }
        guard numbers.count >= 4 else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }
    
    static func resolveNormalizedCenter(
        numbers: (Double, Double, Double, Double),
        imgWidth: Double,
        imgHeight: Double
    ) -> CGPoint {
        let (n0, n1, n2, n3) = numbers
        
        let maxValue = max(n0, n1, n2, n3)
        let scaleX: Double
        let scaleY: Double
        
        if maxValue <= 1.0 {
            scaleX = imgWidth
            scaleY = imgHeight
        } else if maxValue <= 100.0 {
            scaleX = imgWidth / 100.0
            scaleY = imgHeight / 100.0
        } else if maxValue <= 1000.0 {
            scaleX = imgWidth / 1000.0
            scaleY = imgHeight / 1000.0
        } else {
            scaleX = 1.0
            scaleY = 1.0
        }
        
        let x1 = n0 * scaleX
        let y1 = n1 * scaleY
        let x2 = n2 * scaleX
        let y2 = n3 * scaleY
        
        let cx = (x1 + x2) / 2.0
        let cy = (y1 + y2) / 2.0
        
        return CGPoint(x: cx, y: cy)
    }
}

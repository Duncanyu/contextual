import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VLMPerceptionResult: Sendable, Equatable {
	let caption: String
	let contentCategory: String
	let semanticHash: UInt32
	let confidence: Float
}

// MARK: - VLMPerceptionEngine

/// Lightweight bridge to the local VLM server (http://127.0.0.1:8123).
///
/// Protocol:
///   GET  /health  →  { "ok": true, "model": "moondream", "loaded": true }
///   POST /analyze →  { "caption": "...", "content_category": "...", "confidence": 0.0 }
///
/// Server implementation: Scripts/vlm_server.py
/// Start with:           bash Scripts/start_vlm_server.sh
///
/// Timeouts:
///   /health  — 300 ms (fail fast; cached 30 s)
///   /analyze — 20 s  (VLM inference is slow on first call; skip if exceeded)
///
/// Logs:
///   [VLMPerception] enabled=yes / enabled=no
///   [VLMPerception] health_ok=yes model=<name>
///   [VLMPerception] health_ok=no reason=<reason>
///   [VLMPerception] skipped reason=server_unavailable
///   [VLMPerception] completed caption_chars=N latency_ms=N
///   [VLMCaption]    caption="..."
actor VLMPerceptionEngine {
	static let shared = VLMPerceptionEngine()

	private let analyzeEndpoint: URL
	private let healthEndpoint:  URL
	private let enabled: Bool
	private var hasLoggedDisabled: Bool = false
	private var captionCache: [String: (result: VLMPerceptionResult, storedAt: Date)] = [:]
	private let captionCacheTTL: TimeInterval = 300.0   // 5 minutes (per-window semantic reuse)
	private var inFlightEnrichmentKeys: Set<String> = []

	// Health-check cache — avoids calling /health on every captured frame.
	private var healthLastChecked: Date?
	private var healthCachedOk:    Bool   = false
	private var healthCachedModel: String = ""
	private let healthCacheTTL: TimeInterval = 30.0

	// URLSession with no OS-level caching and quiet logging.
	private let session: URLSession = {
		let cfg = URLSessionConfiguration.ephemeral
		cfg.urlCache = nil
		cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		return URLSession(configuration: cfg)
	}()

	init() {
		let env = ProcessInfo.processInfo.environment
		let base = (env["CONTEXTUAL_VLM_ENDPOINT"]?.trimmingCharacters(in: .whitespacesAndNewlines))
			?? "http://127.0.0.1:8123/analyze"
		self.analyzeEndpoint = URL(string: base) ?? URL(string: "http://127.0.0.1:8123/analyze")!

		// Derive /health from /analyze endpoint
		var comps = URLComponents(url: self.analyzeEndpoint, resolvingAgainstBaseURL: false)!
		comps.path = "/health"
		self.healthEndpoint = comps.url ?? URL(string: "http://127.0.0.1:8123/health")!

		// Performance-first default: VLM is opt-in.
		// Set `CONTEXTUAL_VLM_ENABLED=1` to enable local VLM enrichment.
		self.enabled = env["CONTEXTUAL_VLM_ENABLED"] == "1"
	}

	func isEnabled() -> Bool { enabled }
	func configuredEndpoint() -> String { analyzeEndpoint.absoluteString }

	func cachedCaption(cacheKey: String) -> VLMPerceptionResult? {
		guard let entry = captionCache[cacheKey] else { return nil }
		if Date().timeIntervalSince(entry.storedAt) > captionCacheTTL {
			captionCache.removeValue(forKey: cacheKey)
			return nil
		}
		return entry.result
	}

	func storeCaption(cacheKey: String, result: VLMPerceptionResult) {
		captionCache[cacheKey] = (result, Date())
	}

	/// Returns true if the caller successfully reserved an in-flight slot for this cache key.
	/// Used to de-duplicate slow async enrichments.
	func beginAsyncEnrichment(cacheKey: String) -> Bool {
		guard enabled else { return false }
		if inFlightEnrichmentKeys.contains(cacheKey) { return false }
		inFlightEnrichmentKeys.insert(cacheKey)
		return true
	}

	func endAsyncEnrichment(cacheKey: String) {
		inFlightEnrichmentKeys.remove(cacheKey)
	}

	/// Public wrapper around the health check for callers that only need to probe
	/// reachability without running a full analyze. Uses the same 30-second cache.
	func probeServerHealth() async -> Bool {
		await isServerHealthy()
	}

	// MARK: - Health check

	/// Returns true if the VLM server is reachable and has a loaded model.
	/// Result is cached for `healthCacheTTL` seconds to avoid hammering the server.
	private func isServerHealthy() async -> Bool {
		guard enabled else {
			if !hasLoggedDisabled {
				hasLoggedDisabled = true
				print("[VLMPerception] disabled reason=user_or_env")
			}
			return false
		}

		// Return cached value if still fresh.
		if let last = healthLastChecked,
		   Date().timeIntervalSince(last) < healthCacheTTL {
			return healthCachedOk
		}

		var req = URLRequest(url: healthEndpoint)
		req.httpMethod = "GET"
		req.timeoutInterval = 0.30    // 300 ms — fail fast

		do {
			let (data, resp) = try await session.data(for: req)
			guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
				// Non-200: server exists but unhealthy — try to restart it.
				let managed = await attemptManagedLaunch()
				cacheHealth(ok: managed, model: managed ? "managed" : "")
				return managed
			}
			if let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			   let ok    = obj["ok"] as? Bool {
				let model = (obj["model"] as? String) ?? "unknown"
				cacheHealth(ok: ok, model: model)
				if ok {
					print("[VLMPerception] health_ok=yes model=\(model)")
				} else {
					print("[VLMPerception] health_ok=no reason=model_not_loaded")
				}
				return ok
			}
		} catch {
			let reason = isConnectionRefused(error) ? "server_unavailable" : "health_check_failed"
			print("[VLMPerception] health_ok=no reason=\(reason)")
			// Server is unreachable — attempt auto-launch, bounded at 8 s.
			let managed = await attemptManagedLaunch()
			cacheHealth(ok: managed, model: managed ? "managed" : "")
			return managed
		}
		return false
	}

	/// Delegate to VLMServerManager to launch the server script and wait for it to become healthy.
	/// The result is not cached here — the caller caches via cacheHealth().
	private func attemptManagedLaunch() async -> Bool {
		await VLMServerManager.shared.ensureServerRunning(healthEndpoint: healthEndpoint)
	}

	private func cacheHealth(ok: Bool, model: String) {
		healthCachedOk    = ok
		healthCachedModel = model
		healthLastChecked = Date()
	}

	// MARK: - Analyze

	func analyzeFast(
		screenshot:  CGImage,
		appName:     String,
		windowTitle: String?
	) async -> VLMPerceptionResult? {
		guard let base64 = Self.base64PNG(from: screenshot) else {
			print("[VLMPerception] skipped reason=encode_failed")
			return nil
		}
		return await analyzeFast(
			imageBase64: base64,
			appName: appName,
			windowTitle: windowTitle
		)
	}

	func analyze(
		screenshot:  CGImage,
		appName:     String,
		windowTitle: String?
	) async -> VLMPerceptionResult? {
		guard let base64 = Self.base64PNG(from: screenshot) else {
			print("[VLMPerception] skipped reason=encode_failed")
			return nil
		}
		return await analyze(
			imageBase64: base64,
			appName: appName,
			windowTitle: windowTitle
		)
	}

	func analyzeFast(
		imageBase64: String,
		appName: String,
		windowTitle: String?
	) async -> VLMPerceptionResult? {
		await analyzeInternal(
			imageBase64: imageBase64,
			appName: appName,
			windowTitle: windowTitle,
			timeoutSeconds: 1.0,
			tier: "fast"
		)
	}

	func analyze(
		imageBase64: String,
		appName: String,
		windowTitle: String?
	) async -> VLMPerceptionResult? {
		await analyzeInternal(
			imageBase64: imageBase64,
			appName: appName,
			windowTitle: windowTitle,
			timeoutSeconds: 20.0,
			tier: "slow"
		)
	}

	private func analyzeInternal(
		imageBase64: String,
		appName: String,
		windowTitle: String?,
		timeoutSeconds: Double,
		tier: String
	) async -> VLMPerceptionResult? {
		guard enabled else {
			if !hasLoggedDisabled {
				hasLoggedDisabled = true
				print("[VLMPerception] disabled reason=user_or_env")
			}
			return nil
		}

		// Gate: skip analyze call if server is not healthy.
		let healthy = await isServerHealthy()
		guard healthy else {
			print("[VLMPerception] skipped reason=server_unavailable")
			return nil
		}

		let body: [String: Any] = [
			"app":          appName,
			"title":        windowTitle ?? "",
			"image_base64": imageBase64,
		]

		let startedAt = Date()
		var req = URLRequest(url: analyzeEndpoint)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req.timeoutInterval = timeoutSeconds
		req.httpBody = try? JSONSerialization.data(withJSONObject: body)

		do {
			let (data, _) = try await session.data(for: req)
			let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

			guard
				let obj      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				let caption  = obj["caption"] as? String,
				let category = obj["content_category"] as? String
			else {
				print("[VLMPerception] skipped reason=bad_response")
				// Invalidate health cache so next call retries the health check.
				cacheHealth(ok: false, model: "")
				return nil
			}

			let confidence   = (obj["confidence"] as? Double) ?? 0.0
			let semanticHash = Self.semanticHash(caption: caption, category: category)

			print("[VLMPerception] completed caption_chars=\(caption.count) latency_ms=\(elapsedMs) model=\(healthCachedModel) tier=\(tier)")
			print("[VLMCaption] caption=\"\(caption.prefix(220))\"")

			return VLMPerceptionResult(
				caption:         caption,
				contentCategory: category,
				semanticHash:    semanticHash,
				confidence:      Float(confidence)
			)
		} catch {
			let reason = isConnectionRefused(error) ? "server_unavailable" : "request_failed"
			print("[VLMPerception] skipped reason=\(reason)")
			// Invalidate so next frame retries the health check after cache TTL.
			cacheHealth(ok: false, model: "")
			return nil
		}
	}

	// MARK: - Helpers

	nonisolated static func base64PNG(from image: CGImage) -> String? {
		guard let data = pngData(from: image) else { return nil }
		return data.base64EncodedString()
	}

	private static func pngData(from image: CGImage) -> Data? {
		let data = NSMutableData()
		guard let dest = CGImageDestinationCreateWithData(
			data, UTType.png.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(dest, image, nil)
		guard CGImageDestinationFinalize(dest) else { return nil }
		return data as Data
	}

	private static func semanticHash(caption: String, category: String) -> UInt32 {
		// FNV-1a 32-bit — stable, fast, deterministic
		let input = "\(category)|\(caption)"
		var hash: UInt32 = 2_166_136_261
		for b in input.utf8 {
			hash ^= UInt32(b)
			hash = hash &* 16_777_619
		}
		return hash
	}

	private func isConnectionRefused(_ error: Error) -> Bool {
		if let urlError = error as? URLError {
			switch urlError.code {
			case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
			     .networkConnectionLost, .timedOut:
				return true
			default: break
			}
		}
		if let nsError = error as NSError?,
		   nsError.domain == NSURLErrorDomain,
		   nsError.code == NSURLErrorCannotConnectToHost {
			return true
		}
		return false
	}
}

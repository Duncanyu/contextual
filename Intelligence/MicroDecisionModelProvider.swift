import CoreML
import Foundation

/// CoreML-backed tiny classifier hookup (T12.3.6). Safe when no `MicroDecisionClassifier.mlmodelc` is bundled.
final class MicroDecisionModelProvider {
	static let shared = MicroDecisionModelProvider()

	private(set) var isModelLoaded: Bool = false

	private var coreModel: MLModel?
	private var cachedStringInputName: String?
	private var didAttemptLoad = false
	private var didLogMissingModel = false
	/// Bundled T12.3.7 classifier uses a 32-D feature vector (see `MicroDecisionFeatureEncoder`).
	private var usesCompiledFeatureInput = false
	private var detectedInputKind: String = "unknown"

	private init() {}

	/// Lazily loads optional bundled CoreML model (`MicroDecisionClassifier.mlmodelc` or `.mlmodel`).
	func loadModelIfNeeded() {
		guard !isModelLoaded else { return }
		guard coreModel == nil else { return }
		guard !didAttemptLoad else { return }
		didAttemptLoad = true

		let bundle = Bundle.main
		let resolution = Self.resolveClassifierModelURL(in: bundle)

		guard let url = resolution.url else {
			logMissingModel(searched: resolution.searchSummary)
			return
		}

		print("[MicroDecisionModel] found resource=\(resolution.resourceLabel) bundle_lookup=yes")

		do {
			let model = try MLModel(contentsOf: url)
			coreModel = model
			isModelLoaded = true
			if model.modelDescription.inputDescriptionsByName["features"]?.type == .multiArray {
				usesCompiledFeatureInput = true
				detectedInputKind = "features_multiarray"
				cachedStringInputName = nil
			} else {
				usesCompiledFeatureInput = false
				detectedInputKind = "string"
			}
			print("[MicroDecisionModel] loaded mlmodel_loaded=yes input_kind=\(detectedInputKind)")
		} catch {
			print("[MicroDecisionModel] unavailable reason=load_failed mlmodel_loaded=no")
			coreModel = nil
			isModelLoaded = false
			detectedInputKind = "unknown"
		}
	}

	/// Resolves bundled classifier; order matches typical Xcode output (`mlmodelc` in Resources) and dev layouts (`mlmodel`).
	private static func resolveClassifierModelURL(in bundle: Bundle) -> (
		url: URL?,
		resourceLabel: String,
		searchSummary: String
	) {
		var parts: [String] = []

		if let u = bundle.url(forResource: "MicroDecisionClassifier", withExtension: "mlmodelc") {
			parts.append("forResource_mlmodelc=yes")
			return (u, "MicroDecisionClassifier.mlmodelc", parts.joined(separator: " "))
		}
		parts.append("forResource_mlmodelc=no")

		if let u = bundle.url(forResource: "MicroDecisionClassifier", withExtension: "mlmodel") {
			parts.append("forResource_mlmodel=yes")
			return (u, "MicroDecisionClassifier.mlmodel", parts.joined(separator: " "))
		}
		parts.append("forResource_mlmodel=no")

		let scanC = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
		let matchC = scanC.first { $0.lastPathComponent.contains("MicroDecisionClassifier") }
		parts.append("scan_mlmodelc_count=\(scanC.count)")
		if let u = matchC {
			parts.append("scan_mlmodelc_match=yes")
			return (u, u.lastPathComponent, parts.joined(separator: " "))
		}
		parts.append("scan_mlmodelc_match=no")

		let scanM = bundle.urls(forResourcesWithExtension: "mlmodel", subdirectory: nil) ?? []
		let matchM = scanM.first { $0.lastPathComponent.contains("MicroDecisionClassifier") }
		parts.append("scan_mlmodel_count=\(scanM.count)")
		if let u = matchM {
			parts.append("scan_mlmodel_match=yes")
			return (u, u.lastPathComponent, parts.joined(separator: " "))
		}
		parts.append("scan_mlmodel_match=no")

		return (nil, "", parts.joined(separator: " "))
	}

	private func logMissingModel(searched: String) {
		guard !didLogMissingModel else { return }
		didLogMissingModel = true
		print("[MicroDecisionModel] unavailable reason=model_missing searched=\(searched)")
	}

	/// Runs synchronous CoreML inference when a model is present; otherwise returns `nil`.
	func predict(request: MicroDecisionRequest) -> MicroDecisionResponse? {
		loadModelIfNeeded()
		guard let model = coreModel, isModelLoaded else { return nil }

		let input: MLDictionaryFeatureProvider
		do {
			if usesCompiledFeatureInput {
				input = try Self.makeFeaturesProvider(request: request)
			} else {
				let featureString = Self.buildModelInputString(request: request)
				let inputName: String
				if let cached = cachedStringInputName {
					inputName = cached
				} else {
					let resolved = Self.resolveStringInputFeatureName(model: model)
					cachedStringInputName = resolved
					inputName = resolved
				}
				let v = MLFeatureValue(string: featureString)
				input = try MLDictionaryFeatureProvider(dictionary: [inputName: v])
			}
		} catch {
			print("[MicroDecisionModel] prediction_failed reason=input_build")
			return nil
		}

		let output: MLFeatureProvider
		do {
			output = try model.prediction(from: input)
		} catch {
			print("[MicroDecisionModel] prediction_failed reason=inference")
			return nil
		}

		guard let mapped = Self.mapOutput(output, request: request) else {
			print("[MicroDecisionModel] prediction_failed reason=map_output")
			return nil
		}

		let c = String(format: "%.2f", mapped.confidence)
		print("[MicroDecisionModel] prediction_ok conf=\(c)")
		return mapped
	}

	// MARK: - Feature input (T12.3.7)

	private static func makeFeaturesProvider(request: MicroDecisionRequest) throws -> MLDictionaryFeatureProvider {
		let floats = MicroDecisionFeatureEncoder.floats(for: request)
		let n = MicroDecisionFeatureEncoder.dimension
		precondition(floats.count == n)
		let ma = try MLMultiArray(shape: [NSNumber(value: n)], dataType: .double)
		for i in 0..<n {
			ma[i] = NSNumber(value: floats[i])
		}
		return try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: ma)])
	}

	// MARK: - Legacy string input (never log this string)

	private static func buildModelInputString(request: MicroDecisionRequest) -> String {
		let lenBucket = request.textLength / 25
		let lineBucket = request.lineCount / 2
		let f = request.features
		let flagStr = "q=\(f.hasQuestion) code=\(f.isLikelyCode) log=\(f.isLikelyLog) punct=\(String(format: "%.4f", f.punctuationDensity)) rep=\(String(format: "%.3f", f.repetitionScore))"
		let actions = request.availableActions.sorted().joined(separator: ",")
		return [
			"contextType=\(request.contextType.rawValue)",
			"sourceType=\(request.sourceType)",
			"len=\(lenBucket)",
			"lines=\(lineBucket)",
			"features=\(flagStr)",
			"actions=\(actions)",
			"text=\(request.compressedText)"
		].joined(separator: "\n")
	}

	private static func resolveStringInputFeatureName(model: MLModel) -> String {
		let inputs = model.modelDescription.inputDescriptionsByName
		let preferred = ["text", "input", "features", "string", "data"]
		for name in preferred {
			if let desc = inputs[name], desc.type == .string {
				return name
			}
		}
		for name in inputs.keys.sorted() {
			if inputs[name]?.type == .string {
				return name
			}
		}
		return "text"
	}

	// MARK: - Output mapping

	private static func mapOutput(_ output: MLFeatureProvider, request: MicroDecisionRequest) -> MicroDecisionResponse? {
		let names = Set(output.featureNames.map { $0.lowercased() })

		if names.contains("shouldsuggest") || names.contains("should_suggest") {
			return mapExplicitOutputs(output, request: request)
		}

		for labelKey in ["classLabel", "label", "Label"] {
			if let fv = output.featureValue(for: labelKey), fv.type == .string {
				let s = fv.stringValue
				return mapClassLabel(s, output: output, request: request)
			}
		}

		for labelKey in output.featureNames {
			if let fv = output.featureValue(for: labelKey), fv.type == .string {
				let lowerKey = labelKey.lowercased()
				if lowerKey.contains("label") || lowerKey == "class" {
					return mapClassLabel(fv.stringValue, output: output, request: request)
				}
			}
		}

		return nil
	}

	private static func mapExplicitOutputs(_ output: MLFeatureProvider, request: MicroDecisionRequest) -> MicroDecisionResponse? {
		let suggestKey = output.featureNames.first { $0.lowercased().replacingOccurrences(of: "_", with: "") == "shouldsuggest" }
		let confKey = output.featureNames.first { $0.lowercased() == "confidence" }
		let actionKey = output.featureNames.first { $0.lowercased() == "bestactionid" || $0.lowercased() == "best_action_id" }

		guard let sk = suggestKey, let suggestFV = output.featureValue(for: sk) else { return nil }
		let shouldSuggest = truthy(suggestFV)
		var confidence = confKey.flatMap { output.featureValue(for: $0) }.flatMap { doubleValue($0) } ?? 1.0
		confidence = min(1.0, max(0.0, confidence))

		if shouldSuggest {
			guard let ak = actionKey, let aidFV = output.featureValue(for: ak), aidFV.type == .string else {
				return nil
			}
			let rawId = aidFV.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !rawId.isEmpty, request.availableActions.contains(rawId) else { return nil }
			return MicroDecisionResponse(shouldSuggest: true, bestActionId: rawId, confidence: confidence)
		}

		return MicroDecisionResponse(shouldSuggest: false, bestActionId: nil, confidence: confidence)
	}

	private static func mapClassLabel(_ label: String, output: MLFeatureProvider, request: MicroDecisionRequest) -> MicroDecisionResponse? {
		let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
		let key = trimmed.lowercased()

		var confidence = 1.0
		for pk in ["classProbability", "ClassProbability", "class_probabilities"] {
			if let fv = output.featureValue(for: pk), let d = fv.dictionaryValue as? [String: NSNumber] {
				if let n = d[trimmed]?.doubleValue ?? d[key]?.doubleValue {
					confidence = n
					break
				}
			}
		}
		confidence = min(1.0, max(0.0, confidence))

		if key == "none" || key == "no_suggestion" {
			return MicroDecisionResponse(shouldSuggest: false, bestActionId: nil, confidence: confidence)
		}

		let allowed = Set(["summarize_text", "explain_text", "rewrite_text"])
		guard allowed.contains(trimmed), request.availableActions.contains(trimmed) else {
			return nil
		}

		return MicroDecisionResponse(shouldSuggest: true, bestActionId: trimmed, confidence: confidence)
	}

	private static func truthy(_ v: MLFeatureValue) -> Bool {
		switch v.type {
		case .double:
			return v.doubleValue >= 0.5
		case .int64:
			return v.int64Value != 0
		case .multiArray:
			guard let ma = v.multiArrayValue, ma.count > 0 else { return false }
			return ma[0].doubleValue >= 0.5
		default:
			return false
		}
	}

	private static func doubleValue(_ v: MLFeatureValue) -> Double? {
		switch v.type {
		case .double:
			return v.doubleValue
		case .multiArray:
			guard let ma = v.multiArrayValue, ma.count > 0 else { return nil }
			return ma[0].doubleValue
		case .int64:
			return Double(v.int64Value)
		default:
			return nil
		}
	}

}

import Foundation

/// Pluggable backend for ONNX / CoreML micro classifiers (T12.3.5). No model bundled yet.
final class MicroDecisionModelProvider {
	static let shared = MicroDecisionModelProvider()

	private(set) var isModelLoaded: Bool = false

	private init() {}

	/// Reserved for future ONNX/CoreML load. Does not load any asset today.
	func loadModelIfNeeded() {
		guard !isModelLoaded else { return }
		// Future: locate bundle resource, compile CoreML, or map ONNX session.
	}

	/// Returns a prediction when a model is integrated; currently always `nil`.
	func predict(request: MicroDecisionRequest) -> MicroDecisionResponse? {
		loadModelIfNeeded()
		_ = request // API shape for future inference input packing.
		return nil
	}
}

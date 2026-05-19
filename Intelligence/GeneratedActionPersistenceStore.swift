import Foundation

/// On-disk envelope for reusable generated action records.
struct ReusableGeneratedActionStoreFile: Codable, Sendable {
	let version: Int
	let records: [ReusableGeneratedActionRecord]

	static let currentVersion = 1
}

protocol GeneratedActionPersistenceStore: Sendable {
	func loadRecords() async -> [ReusableGeneratedActionRecord]
	func saveRecords(_ records: [ReusableGeneratedActionRecord]) async throws
	func clearAll() async throws
}

/// In-memory store for self-tests.
final class InMemoryGeneratedActionPersistenceStore: GeneratedActionPersistenceStore, @unchecked Sendable {
	private let lock = NSLock()
	private var records: [ReusableGeneratedActionRecord]
	private var shouldFailSave: Bool

	init(records: [ReusableGeneratedActionRecord] = [], shouldFailSave: Bool = false) {
		self.records = records
		self.shouldFailSave = shouldFailSave
	}

	func loadRecords() async -> [ReusableGeneratedActionRecord] {
		lock.lock()
		defer { lock.unlock() }
		return records
	}

	func saveRecords(_ records: [ReusableGeneratedActionRecord]) async throws {
		lock.lock()
		if shouldFailSave {
			lock.unlock()
			throw GeneratedActionPersistenceStoreError.saveFailed
		}
		self.records = records
		lock.unlock()
	}

	func clearAll() async throws {
		lock.lock()
		records = []
		lock.unlock()
	}
}

enum GeneratedActionPersistenceStoreError: Error, Sendable {
	case saveFailed
	case invalidEnvelope
}

/// Local JSON persistence in Application Support (metadata-only).
final class LocalGeneratedActionPersistenceStore: GeneratedActionPersistenceStore, @unchecked Sendable {
	private let fileURL: URL
	private let fileManager: FileManager

	init(
		fileManager: FileManager = .default,
		fileURL: URL? = nil
	) {
		self.fileManager = fileManager
		if let fileURL {
			self.fileURL = fileURL
		} else {
			let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
				?? fileManager.temporaryDirectory
			let dir = base.appendingPathComponent("Contextual", isDirectory: true)
			self.fileURL = dir.appendingPathComponent("reusable-generated-actions.json")
		}
	}

	func loadRecords() async -> [ReusableGeneratedActionRecord] {
		guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
		do {
			let data = try Data(contentsOf: fileURL)
			let envelope = try JSONDecoder().decode(ReusableGeneratedActionStoreFile.self, from: data)
			guard envelope.version == ReusableGeneratedActionStoreFile.currentVersion else { return [] }
			return envelope.records
		} catch {
			return []
		}
	}

	func saveRecords(_ records: [ReusableGeneratedActionRecord]) async throws {
		let dir = fileURL.deletingLastPathComponent()
		if !fileManager.fileExists(atPath: dir.path) {
			try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
		}
		let envelope = ReusableGeneratedActionStoreFile(
			version: ReusableGeneratedActionStoreFile.currentVersion,
			records: records
		)
		let data = try JSONEncoder().encode(envelope)
		let tempURL = fileURL.appendingPathExtension("tmp")
		try data.write(to: tempURL, options: .atomic)
		if fileManager.fileExists(atPath: fileURL.path) {
			try fileManager.removeItem(at: fileURL)
		}
		try fileManager.moveItem(at: tempURL, to: fileURL)
	}

	func clearAll() async throws {
		if fileManager.fileExists(atPath: fileURL.path) {
			try fileManager.removeItem(at: fileURL)
		}
	}
}

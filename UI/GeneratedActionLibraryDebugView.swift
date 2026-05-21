import SwiftUI

/// Debug view listing all records in the generated action / reusable template library (T16.X).
/// Read-only. No execution, no mutation. Intended for developer/dogfooding inspection only.
struct GeneratedActionLibraryDebugView: View {
	let records: [ReusableGeneratedActionRecord]
	@State private var showEligibleOnly = false

	private static let genericTitlePrefixes: [String] = [
		"Prepare a next step",
		"Identify what context is needed",
		"Classify the current workflow",
		"Take a bounded visual peek",
		"Gather context from this page to start",
	]

	private var filtered: [ReusableGeneratedActionRecord] {
		showEligibleOnly ? records.filter { $0.reuseEligibility == .eligible } : records
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			// Header summary
			HStack(spacing: 8) {
				Toggle("Eligible only", isOn: $showEligibleOnly)
					.toggleStyle(.checkbox)
					.font(.caption2)
				Spacer()
				let eligibleCount = records.filter { $0.reuseEligibility == .eligible }.count
				Text("\(eligibleCount) eligible / \(records.count) total")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}

			if filtered.isEmpty {
				Text("No records\(showEligibleOnly ? " (eligible only)" : "").")
					.font(.caption2)
					.foregroundStyle(.secondary)
					.padding(.vertical, 4)
			} else {
				ForEach(filtered, id: \.actionTemplateId) { record in
					LibraryRecordRow(
						record: record,
						isGeneric: Self.genericTitlePrefixes.contains(where: { record.title.hasPrefix($0) })
					)
				}
			}
		}
	}
}

// MARK: - Row

private struct LibraryRecordRow: View {
	let record: ReusableGeneratedActionRecord
	let isGeneric: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			// Title + eligibility badge
			HStack(alignment: .top, spacing: 4) {
				Image(systemName: isGeneric ? "exclamationmark.circle" : "checkmark.circle")
					.font(.caption2)
					.foregroundStyle(isGeneric ? Color.orange : Color.green)
				Text(record.title)
					.font(.caption2.weight(.semibold))
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 0)
				eligibilityBadge
			}
			// Workflow · intent · primitive
			Text("\(record.workflowType.rawValue) · \(record.intentType.rawValue) · \(record.primitiveSignature)")
				.font(.system(size: 9, weight: .regular, design: .monospaced))
				.foregroundStyle(.secondary)
				.lineLimit(2)
			// Stats row
			HStack(spacing: 8) {
				Text("score=\(String(format: "%.2f", record.usefulnessScore))")
				Text("✓\(record.successfulExecutionCount) ✗\(record.failedExecutionCount)")
				if record.metadata["requires_visual"] == "1" { Text("👁 visual") }
				if isGeneric { Text("fallback").foregroundStyle(.orange) }
			}
			.font(.system(size: 9))
			.foregroundStyle(.tertiary)
		}
		.padding(.vertical, 3)
		.padding(.horizontal, 4)
		.background(
			RoundedRectangle(cornerRadius: 4, style: .continuous)
				.fill(isGeneric ? Color.orange.opacity(0.06) : Color.clear)
		)
		Divider()
	}

	@ViewBuilder private var eligibilityBadge: some View {
		switch record.reuseEligibility {
		case .eligible:
			Text("eligible")
				.font(.system(size: 8, weight: .medium))
				.foregroundStyle(.green)
				.padding(.horizontal, 4)
				.padding(.vertical, 1)
				.background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
		case .notEligible:
			Text("not eligible")
				.font(.system(size: 8))
				.foregroundStyle(.secondary)
		case .suppressed:
			Text("suppressed")
				.font(.system(size: 8, weight: .medium))
				.foregroundStyle(.orange)
		}
	}
}

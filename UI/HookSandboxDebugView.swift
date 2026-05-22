// HookSandboxDebugView.swift
// Debug-only UI for the quarantined hook execution sandbox.
// Shown inside LocalModelStatusView when two-stage inference is active.

import SwiftUI

struct HookSandboxDebugView: View {
    let result: HookSandboxResult?
    let isRunning: Bool
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.3)

            HStack {
                Text("Hook Sandbox")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("debug")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                Spacer()
                if isRunning {
                    ProgressView().scaleEffect(0.55)
                }
            }

            Button {
                onRun()
            } label: {
                Label(
                    isRunning ? "Running…" : "Run Hook Sandbox",
                    systemImage: isRunning ? "hourglass" : "play.rectangle"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
            .disabled(isRunning)

            if let result {
                resultBlock(result)
            }
        }
    }

    @ViewBuilder
    private func resultBlock(_ result: HookSandboxResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Status badge
            HStack(spacing: 5) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.success ? .green : .red)
                    .font(.system(size: 11))
                Text(result.success ? "Passed" : "Failed at \(result.failedAt ?? "?")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.success ? Color.green : Color.red)
                Spacer()
                Text("\(result.completedCount)/\(result.chain.count) hooks")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // Per-step rows
            ForEach(result.steps, id: \.hookId) { step in
                HStack(spacing: 5) {
                    Image(systemName: step.succeeded ? "checkmark.circle" : "minus.circle")
                        .foregroundStyle(step.succeeded ? Color.green : Color.orange)
                        .font(.system(size: 9))
                    Text(step.hookId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !step.succeeded {
                        Text("→ \(step.outcome.shortLabel)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Text("\(step.durationMs)ms")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            // Final output block
            if let output = result.finalOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(output)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 80)
                }
                .padding(6)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }

            // Failure reason
            if !result.success, let reason = result.failureReason {
                Text("Reason: \(reason)")
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

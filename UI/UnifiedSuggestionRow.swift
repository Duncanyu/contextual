import SwiftUI

struct UnifiedSuggestionRow: View {
    let suggestion: UnifiedSuggestion
    let onExecute: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                
                // Mode indicator
                if suggestion.kind == .composedPlan {
                    Text("Plan")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if suggestion.kind == .debugAction {
                    Text("Debug")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            
            if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            if DebugMode.isEnabled {
                HStack(spacing: 8) {
                    Text("score:\(String(format: "%.2f", suggestion.confidence))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("source:\(suggestion.source.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Button("Execute") {
                onExecute()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            print("[UnifiedSuggestionRow] id=\(suggestion.id) kind=\(suggestion.kind.rawValue) title=\"\(suggestion.title)\" section=\(suggestion.target.rawValue)")
            print("[VisibleButtonAudit] surface=panel id=\(suggestion.id) has_handler=yes")
        }
    }
}

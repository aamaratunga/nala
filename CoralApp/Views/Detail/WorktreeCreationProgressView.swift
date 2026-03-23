import Lottie
import SwiftUI

struct WorktreeCreationProgressView: View {
    let state: WorktreeCreationState

    var body: some View {
        VStack(spacing: 0) {
            // Header bar — matches SessionDetailView style
            header

            // Accent gradient line
            LinearGradient(
                colors: [.accentColor.opacity(0.6), .accentColor.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)

            // Dark terminal background with vertically centered content
            VStack(spacing: 20) {
                Spacer()

                // Lottie hand animation
                LottieView {
                    try await DotLottieFile.named("Loading_Hand")
                }
                .playing(loopMode: .loop)
                .frame(width: 280, height: 280)

                // Progress stepper
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(WorktreeCreationState.Step.allCases, id: \.rawValue) { step in
                        stepRow(step)
                    }
                }
                .frame(width: 280)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.031, green: 0.043, blue: 0.063))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text("Creating \(state.shortWorktreePath)")
                    .font(.headline)

                if !state.repoPath.isEmpty {
                    Text("from repo \(state.shortRepoPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("Claude")
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Step Row

    @ViewBuilder
    private func stepRow(_ step: WorktreeCreationState.Step) -> some View {
        let status = state.stepStatuses[step] ?? .pending

        HStack(spacing: 10) {
            stepIcon(status)
                .frame(width: 20, height: 20)

            Text(step.rawValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(stepTextColor(status))

            Spacer()

            if case .failed(let message) = status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ status: WorktreeCreationState.StepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.white.opacity(0.3))
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.gray)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func stepTextColor(_ status: WorktreeCreationState.StepStatus) -> Color {
        switch status {
        case .pending: .white.opacity(0.4)
        case .inProgress: .white
        case .completed: .green.opacity(0.8)
        case .skipped: .gray
        case .failed: .red
        }
    }
}

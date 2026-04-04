import Lottie
import SwiftUI

struct WorktreeCreationProgressView: View {
    let state: WorktreeCreationState
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader(
                title: "Creating \(state.shortWorktreePath)",
                subtitle: state.repoPath.isEmpty ? nil : "from repo \(state.shortRepoPath)",
                agentLabel: "Claude"
            )

            // Dark terminal background with vertically centered content
            VStack(spacing: 20) {
                Spacer()

                // Lottie hand animation
                LottieView {
                    try await DotLottieFile.named("Loading_Hand")
                }
                .playing(loopMode: .loop)
                .frame(maxWidth: 240, maxHeight: 240)
                .aspectRatio(1, contentMode: .fit)

                // Progress stepper
                StepProgressList<WorktreeCreationState.Step>(statuses: state.stepStatuses)

                if state.hasFailed {
                    VStack(spacing: 12) {
                        Text("Operation failed")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(NalaTheme.red.opacity(0.8))

                        HStack(spacing: 16) {
                            Button("Dismiss") {
                                store.dismissCreationProgress()
                            }
                            .buttonStyle(.bordered)

                            Button("Retry") {
                                store.retryWorktreeCreation(state: state)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(NalaTheme.coralPrimary)
                        }
                    }
                    .padding(.top, 16)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NalaTheme.terminalBackground)
        }
    }
}

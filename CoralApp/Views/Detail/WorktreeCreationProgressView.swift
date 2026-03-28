import Lottie
import SwiftUI

struct WorktreeCreationProgressView: View {
    let state: WorktreeCreationState

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

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CoralTheme.terminalBackground)
        }
    }
}

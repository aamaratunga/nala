import Lottie
import SwiftUI

struct WorktreeDeletionProgressView: View {
    let state: WorktreeDeletionState
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader(
                title: "Removing \(state.shortFolderPath)",
                subtitle: state.repoPath.isEmpty ? nil : "from repo \(state.shortRepoPath)",
                accentColor: .red
            )

            // Dark terminal background with vertically centered content
            VStack(spacing: 20) {
                Spacer()

                // Lottie paper plane animation
                LottieView {
                    try await DotLottieFile.named("Loading_Paperplane")
                }
                .playing(loopMode: .loop)
                .frame(maxWidth: 280, maxHeight: 280)
                .aspectRatio(1, contentMode: .fit)

                // Progress stepper
                StepProgressList<WorktreeDeletionState.Step>(statuses: state.stepStatuses)

                if state.hasFailed {
                    VStack(spacing: 12) {
                        Text("Operation failed")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.8))

                        HStack(spacing: 16) {
                            Button("Dismiss") {
                                store.dismissDeletionProgress()
                            }
                            .buttonStyle(.bordered)

                            Button("Retry") {
                                store.retryWorktreeDeletion(state: state)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 16)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CoralTheme.terminalBackground)
        }
    }
}

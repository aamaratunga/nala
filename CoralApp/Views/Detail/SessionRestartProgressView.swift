import Lottie
import SwiftUI

struct SessionRestartProgressView: View {
    let state: SessionRestartState
    @Environment(SessionStore.self) private var store
    @State private var showTimeout = false

    private var phaseText: String {
        switch state.phase {
        case .killing: "Stopping session\u{2026}"
        case .launching: "Starting session\u{2026}"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader(
                title: "Restarting \(state.originalSession.displayLabel)",
                accentColor: .orange
            )

            // Dark terminal background with vertically centered content
            VStack(spacing: 20) {
                Spacer()

                LottieView {
                    try await DotLottieFile.named("Loading_Hand")
                }
                .playing(loopMode: .loop)
                .frame(maxWidth: 200, maxHeight: 200)
                .aspectRatio(1, contentMode: .fit)

                Text(phaseText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                if showTimeout {
                    VStack(spacing: 8) {
                        Text("Taking longer than expected\u{2026}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Dismiss") {
                            store.dismissRestartProgress()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CoralTheme.terminalBackground)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                showTimeout = true
            }
        }
    }
}

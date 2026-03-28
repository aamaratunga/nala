import Lottie
import SwiftUI

struct SessionLaunchProgressView: View {
    let state: SessionLaunchState

    private var headerTitle: String {
        state.agentType == "terminal" ? "Launching Terminal" : "Launching Agent"
    }

    private var agentLabel: String {
        switch state.agentType {
        case "terminal": "Terminal"
        case "gemini": "Gemini"
        default: "Claude"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader(
                title: headerTitle,
                agentLabel: agentLabel,
                accentColor: .blue
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

                Text("Starting session\u{2026}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CoralTheme.terminalBackground)
        }
    }
}

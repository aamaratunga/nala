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
            header

            // Blue accent gradient line
            LinearGradient(
                colors: [.blue.opacity(0.6), .blue.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)

            // Dark terminal background with vertically centered content
            VStack(spacing: 20) {
                Spacer()

                LottieView {
                    try await DotLottieFile.named("Loading_Hand")
                }
                .playing(loopMode: .loop)
                .frame(width: 200, height: 200)

                Text("Starting session\u{2026}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

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

            Text(headerTitle)
                .font(.headline)

            Spacer()

            Text(agentLabel)
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
}

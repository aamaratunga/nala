import Lottie
import SwiftUI

struct SessionRestartProgressView: View {
    let state: SessionRestartState

    private var phaseText: String {
        switch state.phase {
        case .killing: "Stopping session\u{2026}"
        case .launching: "Starting session\u{2026}"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Orange accent gradient line
            LinearGradient(
                colors: [.orange.opacity(0.6), .orange.opacity(0)],
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

                Text(phaseText)
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

            Text("Restarting \(state.originalSession.displayLabel)")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

import Lottie
import SwiftUI

struct SessionLaunchProgressView: View {
    let state: SessionLaunchState
    @Environment(SessionStore.self) private var store
    @State private var showTimeout = false

    private var headerTitle: String {
        provider.id == "terminal" ? "Launching Terminal" : "Launching Agent"
    }

    private var agentLabel: String {
        provider.displayName
    }

    private var provider: AgentProvider {
        AgentProvider.provider(for: state.agentType)
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader(
                title: headerTitle,
                agentLabel: agentLabel,
                accentColor: NalaTheme.coralPrimary
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
                    .foregroundStyle(NalaTheme.textSecondary)

                if showTimeout {
                    VStack(spacing: 8) {
                        Text("Taking longer than expected\u{2026}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Dismiss") {
                            store.dismissLaunchProgress()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NalaTheme.terminalBackground)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                showTimeout = true
            }
        }
    }
}

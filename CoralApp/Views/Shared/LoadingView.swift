import SwiftUI

struct LoadingView: View {
    let serverManager: ServerManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 64))
                .foregroundStyle(CoralTheme.coralGradient)
                .symbolEffect(.pulse, options: .repeating)

            Text("Coral")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .foregroundStyle(CoralTheme.coralGradient)

            ProgressView()
                .controlSize(.small)

            Text(serverManager.statusMessage)
                .font(.callout)
                .foregroundStyle(CoralTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CoralTheme.bgBase)
    }
}

#Preview {
    LoadingView(serverManager: ServerManager())
}

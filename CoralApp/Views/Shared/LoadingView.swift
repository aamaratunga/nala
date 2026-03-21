import SwiftUI

struct LoadingView: View {
    let serverManager: ServerManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)

            Text("Coral")
                .font(.largeTitle)
                .fontWeight(.semibold)

            ProgressView()
                .controlSize(.small)

            Text(serverManager.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    LoadingView(serverManager: ServerManager())
}

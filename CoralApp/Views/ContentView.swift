import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            if let session = store.selectedSession {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView {
                    Label("No Session Selected", systemImage: "terminal")
                } description: {
                    Text("Select an agent session from the sidebar, or launch a new one.")
                }
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $store.showingLaunchSheet) {
            LaunchAgentSheet()
        }
    }
}

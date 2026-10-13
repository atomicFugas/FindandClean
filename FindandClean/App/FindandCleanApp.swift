import SwiftUI

@main
struct FindandCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear {
                    appState.presentAccessPromptIfNeeded()
                }
                .sheet(isPresented: $appState.showFDASheet) {
                    FullDiskAccessSheet(
                        isPresented: $appState.showFDASheet,
                        onAnswered: { appState.markAccessPromptAnswered() }
                    )
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

import Foundation
import SwiftUI

enum WorkspaceMode: Equatable {
    /// Find Any File–style: search fills the window.
    case find
    /// AppCleaner + Find hybrid: uninstall leftovers + search side by side.
    case duo
}

@MainActor
final class AppState: ObservableObject {
    @Published var mode: WorkspaceMode = .find
    @Published var showFDASheet = false

    private let accessAnsweredKey = "didAnswerDiskAccessPrompt"
    private let legacyAccessKey = "didShowFullDiskAccessSheet"

    var hasAnsweredAccessPrompt: Bool {
        UserDefaults.standard.bool(forKey: accessAnsweredKey)
            || UserDefaults.standard.bool(forKey: legacyAccessKey)
    }

    func presentAccessPromptIfNeeded() {
        guard !hasAnsweredAccessPrompt else { return }
        showFDASheet = true
    }

    func markAccessPromptAnswered() {
        UserDefaults.standard.set(true, forKey: accessAnsweredKey)
    }

    func enterDuo() {
        withAnimation(.easeInOut(duration: 0.25)) {
            mode = .duo
        }
    }

    func exitDuo() {
        withAnimation(.easeInOut(duration: 0.25)) {
            mode = .find
        }
    }
}

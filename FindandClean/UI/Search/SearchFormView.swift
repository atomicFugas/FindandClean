import SwiftUI
import AppKit

struct SearchFormView: View {
    @Binding var query: SearchQuery
    var isSearching: Bool
    var onSearch: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("File name", text: $query.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSearch)

                Picker("Match", selection: $query.nameMode) {
                    ForEach(NameMatchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Button("Find") {
                    onSearch()
                }
                .disabled(!query.isValid)
                .keyboardShortcut(.defaultAction)
                .help(isSearching ? "Start a new search (stops the current one)" : "Find")

                if isSearching {
                    Button("Stop", action: onStop)
                        .keyboardShortcut(.cancelAction)
                }
            }

            HStack(spacing: 12) {
                Picker("Location", selection: $query.rootPreset) {
                    ForEach(SearchRootPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .frame(maxWidth: 220)

                if query.rootPreset == .custom {
                    Button(query.customRoot?.path ?? "Choose Folder…") {
                        chooseFolder()
                    }
                }

                TextField("Kind (ext)", text: $query.kindExtension)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .help("Optional extension filter, e.g. pdf or folder")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK else { return }
            query.customRoot = panel.url
        }
    }
}

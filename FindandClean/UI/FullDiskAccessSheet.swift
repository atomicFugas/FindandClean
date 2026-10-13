import SwiftUI
import AppKit

struct FullDiskAccessSheet: View {
    @Binding var isPresented: Bool
    var onAnswered: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow disk access")
                .font(.title2.weight(.semibold))

            Text(
                "FindandClean needs Full Disk Access once to search protected folders such as ~/Library/Biome, Mail, Safari data, and other leftovers. Without it, many results Find Any File shows will be missing. You’ll only be asked this one time."
            )
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                labeledStep(1, "Click Open Settings")
                labeledStep(2, "Enable FindandClean under Full Disk Access")
                labeledStep(3, "Return here and continue")
            }
            .font(.callout)

            HStack {
                Button("Not Now") {
                    onAnswered()
                    isPresented = false
                }
                Spacer()
                Button("Open Settings") {
                    openFDASettings()
                }
                Button("Done") {
                    onAnswered()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func labeledStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).")
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
        }
    }

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

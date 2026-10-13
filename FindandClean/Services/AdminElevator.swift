import Foundation
import AppKit

actor AdminElevator {
    static let shared = AdminElevator()

    struct ElevatedTrashResult: Sendable {
        var trashed: [URL]
        var failed: [(URL, String)]
    }

    /// Moves items into the user's Trash using an administrator-privileged shell.
    /// Uses osascript so the standard macOS password dialog appears once per batch.
    func moveToTrash(urls: [URL]) async throws -> ElevatedTrashResult {
        guard !urls.isEmpty else {
            return ElevatedTrashResult(trashed: [], failed: [])
        }

        let trashDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)

        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        var trashed: [URL] = []
        var failed: [(URL, String)] = []

        var scriptLines: [String] = ["#!/bin/bash", "set -e"]
        let trashPathEscaped = shellEscape(trashDir.path)
        for url in urls {
            let src = shellEscape(url.path)
            let baseName = shellEscape(url.lastPathComponent)
            scriptLines.append(
                """
                src=\(src)
                trash=\(trashPathEscaped)
                base=\(baseName)
                dest="$trash/$base"
                if [ -e "$dest" ]; then
                  dest="$trash/$base-$$"
                fi
                /bin/mv "$src" "$dest"
                """
            )
        }

        let script = scriptLines.joined(separator: "\n")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("findandclean-trash-\(UUID().uuidString).sh")
        try script.write(to: temp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)

        defer { try? FileManager.default.removeItem(at: temp) }

        let command = "/bin/bash \(temp.path)"
        let appleScript = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                trashed = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
                let stillThere = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                for url in stillThere {
                    failed.append((url, "Still present after elevated move"))
                }
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = (message?.isEmpty == false) ? message! : "Administrator authentication failed or was cancelled"
                for url in urls {
                    failed.append((url, reason))
                }
            }
        } catch {
            for url in urls {
                failed.append((url, error.localizedDescription))
            }
        }

        return ElevatedTrashResult(trashed: trashed, failed: failed)
    }

    private func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptStringLiteral(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

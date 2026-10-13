import Foundation

struct TrashService {
    enum TrashError: LocalizedError {
        case refusedRoot(URL)
        case partialFailure([String])

        var errorDescription: String? {
            switch self {
            case .refusedRoot(let url):
                return "Refusing to trash volume root: \(url.path)"
            case .partialFailure(let messages):
                return messages.joined(separator: "\n")
            }
        }
    }

    struct Result: Sendable {
        var trashed: [URL]
        var failed: [(URL, String)]
        var usedElevation: Bool
    }

    func trash(urls: [URL], allowElevation: Bool = true) async throws -> Result {
        var trashed: [URL] = []
        var failed: [(URL, String)] = []
        var needsElevation: [URL] = []

        for url in urls {
            if isForbidden(url) {
                failed.append((url, TrashError.refusedRoot(url).localizedDescription))
                continue
            }

            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                trashed.append(url)
            } catch {
                let ns = error as NSError
                if allowElevation, isPermissionError(ns) {
                    needsElevation.append(url)
                } else {
                    failed.append((url, error.localizedDescription))
                }
            }
        }

        var usedElevation = false
        if !needsElevation.isEmpty {
            usedElevation = true
            let elevated = try await AdminElevator.shared.moveToTrash(urls: needsElevation)
            trashed.append(contentsOf: elevated.trashed)
            failed.append(contentsOf: elevated.failed)
        }

        return Result(trashed: trashed, failed: failed, usedElevation: usedElevation)
    }

    private func isForbidden(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let forbidden = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        return forbidden.contains(path)
    }

    private func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            let codes: [Int] = [
                NSFileWriteNoPermissionError,
                NSFileReadNoPermissionError,
                NSFileWriteVolumeReadOnlyError
            ]
            if codes.contains(error.code) { return true }
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == EACCES || error.code == EPERM) {
            return true
        }
        return false
    }
}

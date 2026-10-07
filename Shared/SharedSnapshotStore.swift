import Foundation
import Darwin

enum SharedSnapshotStore {
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CodexUsageViewerConstants.appGroup)?
            .appendingPathComponent("usage-snapshot.json")
    }

    static func load() -> UsageSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data),
              snapshot.version == 1 else { return .empty }
        // Only the three stable slots are accepted from disk.
        var safe = UsageSnapshot.empty
        for index in safe.accounts.indices {
            if let account = snapshot.accounts.first(where: { $0.id == safe.accounts[index].id }) {
                safe.accounts[index] = account
            }
        }
        safe.savedAt = snapshot.savedAt
        safe.localCodexEmail = snapshot.localCodexEmail
        safe.localCodexCheckedAt = snapshot.localCodexCheckedAt
        return safe
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        guard let url = fileURL else {
            throw NSError(domain: "CodexUsageViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex Usage Viewer couldn’t access its widget storage. Check the app’s signing and App Group configuration."])
        }
        try write(snapshot, to: url)
    }

    static func write(_ snapshot: UsageSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        // Publish a complete file whose permissions were private from creation.
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

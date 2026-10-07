import XCTest
@testable import CodexUsageViewerCore

final class SnapshotStoreTests: XCTestCase {
    func testSnapshotPublicationIsPrivateAndReplacesWholeFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        try SharedSnapshotStore.write(.preview, to: file)
        try SharedSnapshotStore.write(.empty, to: file)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(snapshot.accounts.count, 3)
        XCTAssertTrue(snapshot.accounts.allSatisfy { $0.state == .disconnected && $0.buckets.isEmpty })
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["snapshot.json"])
    }
}

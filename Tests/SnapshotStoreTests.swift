import XCTest
@testable import CodexUsageViewerCore

final class SnapshotStoreTests: XCTestCase {
    func testResetCreditSnapshotRoundTripKeepsOnlyCountAndExpiryAndReadsLegacySnapshots() throws {
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":4,"credits":[{"id":"redemption-secret","status":"available","expiresAt":1900000500,"grantedAt":1900000000,"title":"Unneeded title","description":"Unneeded description"}]}}"#.utf8))
        var snapshot = UsageSnapshot.preview
        snapshot.accounts[0].resetCredits = response.rateLimitResetCredits
        let data = try JSONEncoder().encode(snapshot)
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(serialized.contains("redemption-secret"))
        XCTAssertFalse(serialized.contains("grantedAt"))
        XCTAssertFalse(serialized.contains("Unneeded"))
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded.accounts[0].resetCredits, RateLimitResetCredits(availableCount: 4, earliestExpiresAt: 1_900_000_500))
        XCTAssertEqual(decoded.accounts[0].primaryBucket?.credits, snapshot.accounts[0].primaryBucket?.credits)
        let legacy = try JSONDecoder().decode(AccountSnapshot.self, from: Data(#"{"id":"account-1","name":"Account","state":"connected","buckets":[],"updatedAt":0}"#.utf8))
        XCTAssertNil(legacy.resetCredits)
        XCTAssertEqual(legacy.resetsValue(at: Date(timeIntervalSinceReferenceDate: 0)), .unknown)
    }

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

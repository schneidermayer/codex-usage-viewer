import XCTest
@testable import CodexUsageViewerCore

final class UsageModelsTests: XCTestCase {
    func testDynamicWindowsAndRemainingUsage() throws {
        let window = try JSONDecoder().decode(QuotaWindow.self, from: Data(#"{"usedPercent":26,"windowDurationMins":300,"resetsAt":1900000000}"#.utf8))
        XCTAssertEqual(window.remainingPercent, 74)
        XCTAssertEqual(window.label, "5-hour")
        XCTAssertEqual(QuotaWindow(usedPercent: 100, windowDurationMins: 10_080).label, "Weekly")
        XCTAssertEqual(QuotaWindow(usedPercent: 120).remainingPercent, 0)
    }

    func testMissingWindowIsNotZeroAndNegativeUsageIsRejected() throws {
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8))
        XCTAssertNil(response.buckets.first?.primary)
        XCTAssertThrowsError(try JSONDecoder().decode(QuotaWindow.self, from: Data(#"{"usedPercent":-1}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(QuotaWindow.self, from: Data(#"{"windowDurationMins":300}"#.utf8)))
    }

    func testAllMeteredBucketsArePreservedAndCodexFirst() throws {
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":20}},"codex":{"primary":{"usedPercent":70}}}}"#.utf8))
        XCTAssertEqual(response.buckets.map(\.id), ["codex", "other"])
        XCTAssertEqual(response.buckets.first?.primary?.remainingPercent, 30)
    }

    func testStaleAndElapsedDataDoNotResetAllowance() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let window = QuotaWindow(usedPercent: 91, windowDurationMins: 300, resetsAt: 1_899_999_999)
        XCTAssertTrue(window.hasElapsed(at: now))
        XCTAssertEqual(window.remainingPercent, 9)
        var account = AccountSnapshot(id: "account-1", name: "Personal")
        XCTAssertTrue(account.isStale(at: now))
        account.updatedAt = now.addingTimeInterval(-601)
        XCTAssertTrue(account.isStale(at: now))
        account.updatedAt = now.addingTimeInterval(120)
        XCTAssertTrue(account.isStale(at: now))
        account.updatedAt = now
        XCTAssertFalse(account.isStale(at: now))
    }

    func testExactlyThreeStableSlotsAndNoFabricatedInitialData() {
        let snapshot = UsageSnapshot.empty
        XCTAssertEqual(snapshot.accounts.map(\.id), CodexUsageViewerConstants.accountIDs)
        XCTAssertEqual(snapshot.accounts.count, 3)
        XCTAssertTrue(snapshot.accounts.allSatisfy { $0.state == .disconnected && $0.buckets.isEmpty && $0.updatedAt == nil })
    }

    func testLocalBadgeRequiresMatchingConnectedAndFreshIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var snapshot = UsageSnapshot.preview
        snapshot.localCodexEmail = "PERSONAL@example.com"
        snapshot.localCodexCheckedAt = now
        XCTAssertTrue(snapshot.isLocalAccount(snapshot.accounts[0], at: now))
        XCTAssertFalse(snapshot.isLocalAccount(snapshot.accounts[1], at: now))
        XCTAssertFalse(snapshot.isLocalAccount(snapshot.accounts[0], at: now.addingTimeInterval(601)))
        snapshot.accounts[0].state = .disconnected
        XCTAssertFalse(snapshot.isLocalAccount(snapshot.accounts[0], at: now))
        let legacy = try JSONDecoder().decode(UsageSnapshot.self, from: Data(#"{"version":1,"accounts":[],"savedAt":0}"#.utf8))
        XCTAssertNil(legacy.localCodexEmail)
        XCTAssertNil(legacy.localCodexCheckedAt)
    }
}

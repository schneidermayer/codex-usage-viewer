import XCTest
@testable import CodexUsageViewerCore

final class WeeklyUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func weekly(seconds: Int = 302_400) -> QuotaWindow {
        QuotaWindow(usedPercent: 42, windowDurationMins: 10_080, resetsAt: 1_900_000_000 + seconds)
    }

    private func account(primary: QuotaWindow?, secondary: QuotaWindow?) -> AccountSnapshot {
        AccountSnapshot(id: "account-1", name: "Account 1", state: .connected,
                        buckets: [UsageBucket(limitId: "codex", primary: primary, secondary: secondary)], updatedAt: now)
    }

    func testFindsWeeklyByDurationInEitherSlotWithoutSessionFallback() {
        let session = QuotaWindow(usedPercent: 8, windowDurationMins: 300)
        XCTAssertEqual(account(primary: session, secondary: weekly()).weeklyWindow, weekly())
        XCTAssertEqual(account(primary: weekly(), secondary: session).weeklyWindow, weekly())
        XCTAssertNil(account(primary: session, secondary: nil).weeklyWindow)
        XCTAssertEqual(account(primary: session, secondary: nil).weeklyUsage(at: now), .notReported)
        var value = account(primary: session, secondary: nil)
        value.buckets.append(UsageBucket(limitId: "other", primary: weekly()))
        XCTAssertNil(value.weeklyWindow, "Another meter must not stand in for Codex weekly usage")
    }

    func testResetProgressMeasuresTimeNotUsageAndUsesNumericCountdown() throws {
        let progress = try XCTUnwrap(WeeklyResetProgress(window: weekly(), at: now))
        XCTAssertEqual(progress.fractionRemaining, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(progress.countdown, "3d 12h")
        XCTAssertEqual(WeeklyResetProgress(window: weekly(seconds: 66_600), at: now)?.countdown, "18h 30m")
        XCTAssertEqual(WeeklyResetProgress(window: weekly(seconds: 119), at: now)?.countdown, "1m")
        XCTAssertEqual(WeeklyResetProgress(window: weekly(seconds: 59), at: now)?.countdown, "<1m")
        XCTAssertEqual(WeeklyResetProgress(window: weekly(seconds: 700_000), at: now)?.fractionRemaining, 1)
        XCTAssertNil(WeeklyResetProgress(window: weekly(seconds: 0), at: now))
        XCTAssertNil(WeeklyResetProgress(window: QuotaWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 1_900_000_100), at: now))
    }

    func testStaleSignedOutMissingAndElapsedRemainUnknown() {
        var value = account(primary: nil, secondary: weekly())
        value.updatedAt = now.addingTimeInterval(-601)
        XCTAssertEqual(value.weeklyUsage(at: now), .stale)
        XCTAssertNil(value.weeklyUsage(at: now).window)
        value.state = .needsSignIn
        XCTAssertEqual(value.weeklyUsage(at: now), .needsSignIn)
        value.state = .connected
        value.updatedAt = now
        value.buckets[0].secondary = weekly(seconds: 0)
        XCTAssertEqual(value.weeklyUsage(at: now), .resetElapsed)
        XCTAssertNil(value.weeklyUsage(at: now).window)
        XCTAssertEqual(value.buckets[0].secondary?.usedPercent, 42)
        value.buckets[0].secondary = weekly()
        value.issue = "Fixture unavailable"
        XCTAssertEqual(value.weeklyUsage(at: now), .unavailable)
    }

    func testSessionResetUsesItsOwnDurationAndRejectsUnknownOrExpiredTime() throws {
        var window = QuotaWindow(usedPercent: 95, windowDurationMins: 300, resetsAt: 1_900_009_000)
        let progress = try XCTUnwrap(QuotaResetProgress(window: window, at: now))
        XCTAssertEqual(progress.fractionRemaining, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(progress.countdown, "2h 30m")
        XCTAssertNil(WeeklyResetProgress(window: window, at: now))
        window.windowDurationMins = nil
        XCTAssertNil(QuotaResetProgress(window: window, at: now))
        window.windowDurationMins = 0
        XCTAssertNil(QuotaResetProgress(window: window, at: now))
        window.windowDurationMins = 300
        window.resetsAt = 1_900_000_000
        XCTAssertNil(QuotaResetProgress(window: window, at: now))
        window.resetsAt = nil
        XCTAssertNil(QuotaResetProgress(window: window, at: now))
    }

    func testMissingResetDoesNotInventCountdownOrDiscardValidWeeklyUsage() {
        var window = weekly()
        window.resetsAt = nil
        let value = account(primary: window, secondary: nil)
        XCTAssertEqual(value.weeklyUsage(at: now).window?.remainingPercent, 58)
        XCTAssertNil(WeeklyResetProgress(window: window, at: now))
    }

    func testTimelineIncludesCountdownTicksStalenessAndWeeklyExpiryOnly() {
        let session = QuotaWindow(usedPercent: 8, windowDurationMins: 300, resetsAt: 1_900_000_050)
        let value = account(primary: session, secondary: weekly(seconds: 400))
        let snapshot = UsageSnapshot(accounts: [value], savedAt: now)
        let dates = WeeklyWidgetTimeline.dates(snapshot: snapshot, now: now, reloadAt: now.addingTimeInterval(900))
        XCTAssertEqual(dates.map { Int($0.timeIntervalSince(now)) }, [0, 300, 400, 600, 601, 900])
        XCTAssertEqual(value.weeklyUsage(at: now.addingTimeInterval(400)), .resetElapsed)
    }

    func testTimelineInvalidatesAvailableResetCountAtItsKnownExpiry() {
        var value = account(primary: nil, secondary: weekly())
        value.resetCredits = RateLimitResetCredits(availableCount: 4, earliestExpiresAt: 1_900_000_120)
        let snapshot = UsageSnapshot(accounts: [value], savedAt: now)
        let dates = WeeklyWidgetTimeline.dates(snapshot: snapshot, now: now, reloadAt: now.addingTimeInterval(180))
        XCTAssertEqual(dates.map { Int($0.timeIntervalSince(now)) }, [0, 120, 180])
        XCTAssertEqual(value.resetsValue(at: now.addingTimeInterval(119)), .amount("4"))
        XCTAssertEqual(value.resetsValue(at: now.addingTimeInterval(120)), .unknown)
        XCTAssertEqual(value.weeklyUsage(at: now.addingTimeInterval(120)).window, weekly())
    }
}

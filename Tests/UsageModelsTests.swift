import XCTest
@testable import CodexUsageViewerCore

final class UsageModelsTests: XCTestCase {
    private let resourceNow = Date(timeIntervalSince1970: 1_900_000_000)

    private func resourceAccount(credits: CreditBalance? = CreditBalance(hasCredits: true, unlimited: false, balance: "125.5"), resets: RateLimitResetCredits? = RateLimitResetCredits(availableCount: 2)) -> AccountSnapshot {
        AccountSnapshot(id: "account-1", name: "Account", state: .connected,
                        buckets: [UsageBucket(limitId: "codex", credits: credits)], updatedAt: resourceNow, resetCredits: resets)
    }

    func testResetCreditDecoderUsesAuthoritativeCountAndEarliestAvailableExpiry() throws {
        let json = #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":7,"credits":[{"id":"private-redemption-id","status":"available","expiresAt":1900000040,"title":"Private title"},{"status":"available","expiresAt":1900000080},{"status":"redeemed","expiresAt":1899999000},{"status":"redeeming","expiresAt":1899999999},{"status":"available","expiresAt":null}]}}"#
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(json.utf8))
        let summary = try XCTUnwrap(response.rateLimitResetCredits)
        XCTAssertEqual(summary.availableCount, 7, "The backend can cap details; their count is not the allowance")
        XCTAssertEqual(summary.earliestExpiresAt, 1_900_000_040)
        var account = resourceAccount(resets: summary)
        XCTAssertEqual(account.resetsValue(at: resourceNow), .amount("7"))
        XCTAssertEqual(account.resetsValue(at: resourceNow.addingTimeInterval(40)), .unknown)
        XCTAssertEqual(account.resetCredits?.availableCount, 7, "Passing an expiry must not spend a reset locally")
        account.resetCredits?.availableCount = -1
        XCTAssertEqual(account.resetsValue(at: resourceNow), .unknown)
    }

    func testResetCreditsDistinguishMissingZeroAndCountWithoutDetails() throws {
        for suffix in ["", #", "rateLimitResetCredits":null"#, #", "rateLimitResetCredits":{}"#] {
            let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data("{\"rateLimits\":{}\(suffix)}".utf8))
            XCTAssertEqual(resourceAccount(resets: response.rateLimitResetCredits).resetsValue(at: resourceNow), .unknown)
        }
        for details in ["null", "[]"] {
            let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data("{\"rateLimits\":{},\"rateLimitResetCredits\":{\"availableCount\":3,\"credits\":\(details)}}".utf8))
            XCTAssertEqual(resourceAccount(resets: response.rateLimitResetCredits).resetsValue(at: resourceNow), .amount("3"))
        }
        XCTAssertEqual(resourceAccount(resets: RateLimitResetCredits(availableCount: 0)).resetsValue(at: resourceNow), .amount("0"))
    }

    func testCreditsDistinguishReportedZeroAvailabilityUnlimitedAndUnknown() {
        XCTAssertEqual(resourceAccount(credits: nil).creditsValue(at: resourceNow), .unknown)
        XCTAssertEqual(resourceAccount(credits: CreditBalance(hasCredits: false, unlimited: false, balance: nil)).creditsValue(at: resourceNow), .amount("0"))
        XCTAssertEqual(resourceAccount(credits: CreditBalance(hasCredits: true, unlimited: false, balance: nil)).creditsValue(at: resourceNow), .available)
        XCTAssertEqual(resourceAccount(credits: CreditBalance(hasCredits: true, unlimited: true, balance: nil)).creditsValue(at: resourceNow), .unlimited)
        XCTAssertEqual(resourceAccount().creditsValue(at: resourceNow), .amount("125.5"))
        for malformed in ["", "nan", "Infinity", "-1", "12 credits", "12x", "1e999999", "1,500"] {
            XCTAssertEqual(resourceAccount(credits: CreditBalance(hasCredits: true, unlimited: false, balance: malformed)).creditsValue(at: resourceNow), .unknown, malformed)
        }
    }

    func testResourcesRequireFreshSuccessfulConnectedSnapshot() {
        var values: [AccountSnapshot] = []
        var account = resourceAccount()
        account.state = .disconnected; values.append(account)
        account = resourceAccount(); account.state = .needsSignIn; values.append(account)
        account = resourceAccount(); account.issue = "Offline"; values.append(account)
        account = resourceAccount(); account.updatedAt = nil; values.append(account)
        account = resourceAccount(); account.updatedAt = resourceNow.addingTimeInterval(-601); values.append(account)
        account = resourceAccount(); account.updatedAt = resourceNow.addingTimeInterval(61); values.append(account)
        for value in values {
            XCTAssertEqual(value.creditsValue(at: resourceNow), .unknown)
            XCTAssertEqual(value.resetsValue(at: resourceNow), .unknown)
        }
        account = resourceAccount()
        account.buckets[0].primary = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: 1_899_999_999)
        XCTAssertEqual(account.creditsValue(at: resourceNow), .amount("125.5"), "Scheduled quota resets do not determine purchased credits")
        XCTAssertEqual(account.resetsValue(at: resourceNow), .amount("2"))
    }

    func testCreditFallbackIsMatchedByBucketAndDoesNotOverrideExplicitBalance() throws {
        let fallback = #""rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"75"}}"#
        for map in [#"{"codex":{},"other":{}}"#, #"{"other":{}}"#] {
            let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data("{\(fallback),\"rateLimitsByLimitId\":\(map)}".utf8))
            XCTAssertEqual(response.buckets.first?.id, "codex")
            XCTAssertEqual(response.buckets.first?.credits?.balance, "75")
            XCTAssertNil(response.buckets.first(where: { $0.id == "other" })?.credits)
        }
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data("{\(fallback),\"rateLimitsByLimitId\":{\"codex\":{\"credits\":{\"hasCredits\":false,\"unlimited\":false}}}}".utf8))
        XCTAssertEqual(response.buckets.first?.credits?.hasCredits, false)
        XCTAssertNil(response.buckets.first?.credits?.balance)
    }

    func testResourceFormattingHandlesLargeAndFractionalValuesWithoutChangingExactAccessibilityValue() {
        let large = resourceAccount(credits: CreditBalance(hasCredits: true, unlimited: false, balance: "1000000000000000000000000000000")).creditsValue(at: resourceNow)
        XCTAssertNotEqual(large, .unknown)
        XCTAssertLessThan(large.compactText.count, 10)
        XCTAssertEqual(large.accessibilityText, "1000000000000000000000000000000")
        XCTAssertEqual(AccountResourceValue.amount("12345.67").compactText, "12.3K")
        XCTAssertEqual(AccountResourceValue.amount("0.00001").compactText, "<0.01")
        XCTAssertEqual(AccountResourceValue.unknown.text, "Unknown")
        XCTAssertEqual(AccountResourceValue.unknown.compactText, "—")
        XCTAssertEqual(AccountResourceValue.available.compactText, "Yes")
        XCTAssertEqual(AccountResourceValue.unlimited.compactText, "∞")
    }

    func testCreditDisplaysLimitPrecisionWithoutChangingStoredBalance() {
        let balance = "61.354207891"
        let account = resourceAccount(credits: CreditBalance(hasCredits: true, unlimited: false, balance: balance))
        let value = account.creditsValue(at: resourceNow)
        XCTAssertEqual(account.buckets[0].credits?.balance, balance)
        XCTAssertEqual(value, .amount(balance))
        XCTAssertEqual(value.text, "61.35")
        XCTAssertEqual(value.compactText, "61.35")
        XCTAssertEqual(value.accessibilityText, "61.35")
        for (balance, expected) in [("125.50000", "125.5"), ("2.99999", "2.99"),
                                    ("0.00001", "<0.01"), ("0", "0"), ("2", "2")] {
            XCTAssertEqual(AccountResourceValue.amount(balance).text, expected)
            XCTAssertEqual(AccountResourceValue.amount(balance).compactText, expected)
        }
        XCTAssertEqual(AccountResourceValue.amount("1234567.891234").text, "1234567.89")
        XCTAssertEqual(AccountResourceValue.amount("1234567.891234").compactText, "1.2M")
    }

    func testSubscriptionDisplayLabelsPreserveReportedPlansAndUnknownNames() {
        for (reported, displayed) in [("prolite", "100"), ("PRO", "200"), (" ProMax\n", "500"),
                                      ("Enterprise Research", "Enterprise Research"), ("plus", "plus"),
                                      ("pro_future", "pro_future")] {
            let account = AccountSnapshot(id: "account-1", name: "Account", plan: reported)
            XCTAssertEqual(account.subscriptionDisplayName, displayed)
            XCTAssertEqual(account.plan, reported)
        }
    }

    func testMissingSubscriptionDoesNotInventATier() {
        for reported: String? in [nil, "", " \n\t"] {
            let account = AccountSnapshot(id: "account-1", name: "Account", plan: reported)
            XCTAssertNil(account.subscriptionDisplayName)
        }
    }

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

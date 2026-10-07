import Foundation
import XCTest
@testable import CodexUsageViewerCore

@MainActor
private final class Deferred<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func succeed(_ value: Value) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}

private enum StoreFixtureError: Error { case offline }

@MainActor
private final class StoreConnectionFixture: CodexAccountConnection {
    var identity: CodexIdentity? = CodexIdentity(email: "current@fixture.test", planType: "pro", type: "chatgpt")
    var accountHandler: (() async throws -> CodexIdentity?)?
    var limitsHandler: (() async throws -> RateLimitsResponse)?
    var beginHandler: (() async throws -> CodexLogin)?
    var waitHandler: (() async throws -> Void)?
    var accountCalls = 0
    var limitsCalls = 0
    var beginCalls = 0
    var disconnectCalls = 0
    var canceledLogins: [String] = []
    var events: [String] = []

    static var limits: RateLimitsResponse {
        RateLimitsResponse(rateLimits: UsageBucket(limitId: "codex", primary: QuotaWindow(usedPercent: 33, windowDurationMins: 300, resetsAt: 1_900_000_000)))
    }

    func account() async throws -> CodexIdentity? {
        accountCalls += 1
        if let accountHandler { return try await accountHandler() }
        return identity
    }
    func readLimits() async throws -> RateLimitsResponse {
        limitsCalls += 1
        let result = try await limitsHandler?() ?? Self.limits
        events.append("limits returned")
        return result
    }
    func beginLogin() async throws -> CodexLogin {
        beginCalls += 1
        return try await beginHandler?() ?? CodexLogin(loginId: "fixture-login", authURL: URL(string: "https://auth.openai.com/fixture")!)
    }
    func waitForLogin(loginID: String) async throws { try await waitHandler?() }
    func cancelLogin(loginID: String) async { canceledLogins.append(loginID) }
    func disconnect() async throws { disconnectCalls += 1; events.append("disconnected") }
    func stop() {}
}

@MainActor
final class CodexStoreTests: XCTestCase {
    @MainActor private final class Harness {
        let worker = StoreConnectionFixture()
        let preferences: UserDefaults
        let suite = "CodexUsageViewerStoreTests.\(UUID().uuidString)"
        var now = Date(timeIntervalSince1970: 1_850_000_000)
        var localIdentity: CodexIdentity?
        var localReadHandler: (() async throws -> CodexIdentity?)?
        var localReadCalls = 0
        var workers: [String: StoreConnectionFixture] = [:]
        var saved: [UsageSnapshot] = []
        var widgetReloads = 0
        var cached: UsageSnapshot
        var store: CodexUsageViewerStore!

        init(connected: Bool = true, arguments: [String] = [], profiles: [ChromeProfile] = [], savedProfile: String? = nil) {
            preferences = UserDefaults(suiteName: suite)!
            if let savedProfile { preferences.set(["account-1": savedProfile], forKey: "chromeProfiles") }
            var accounts = AccountSnapshot.emptyAccounts
            if connected {
                accounts[0] = AccountSnapshot(id: "account-1", name: "My personal account", email: "old@fixture.test", plan: "plus",
                                              state: .connected, buckets: [StoreConnectionFixture.limits.rateLimits],
                                              updatedAt: now.addingTimeInterval(-1_000))
            }
            cached = UsageSnapshot(accounts: accounts, savedAt: now.addingTimeInterval(-1_000))
            let dependencies = CodexUsageViewerStoreDependencies(
                loadSnapshot: { [unowned self] in cached },
                saveSnapshot: { [unowned self] in saved.append($0) },
                reloadWidgets: { [unowned self] in widgetReloads += 1 },
                locateExecutable: { _ in URL(fileURLWithPath: "/fixture/codex") },
                makeConnection: { [unowned self] id, _ in workers[id] ?? worker },
                credentialExists: { _ in false }, discoverChromeProfiles: { profiles }, now: { [unowned self] in now },
                readLocalIdentity: { [unowned self] _ in
                    localReadCalls += 1
                    if let localReadHandler { return try await localReadHandler() }
                    return localIdentity
                })
            store = CodexUsageViewerStore(dependencies: dependencies, preferences: preferences, arguments: arguments)
        }

        func finish() {
            store.shutdown()
            preferences.removePersistentDomain(forName: suite)
        }
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected lifecycle event did not occur", file: file, line: line)
    }

    func testChangedIdentityNeverKeepsPreviousAccountsQuotaOnFetchFailure() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.worker.limitsHandler = { throw StoreFixtureError.offline }
        await harness.store.refresh()
        let account = harness.store.accounts[0]
        XCTAssertEqual(account.email, "current@fixture.test")
        XCTAssertEqual(account.plan, "pro")
        XCTAssertTrue(account.buckets.isEmpty)
        XCTAssertNil(account.updatedAt)
        XCTAssertNotNil(account.issue)
        XCTAssertEqual(harness.saved.last?.accounts[0], account)
    }

    func testReconnectClearsPreviousIdentityBeforeAccountReadCanFail() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.worker.accountHandler = { throw StoreFixtureError.offline }
        await harness.store.connect("account-1")
        await eventually { harness.store.login?.isWaiting == false }
        let account = harness.store.accounts[0]
        XCTAssertEqual(account.name, "My personal account")
        XCTAssertNil(account.email)
        XCTAssertTrue(account.buckets.isEmpty)
        XCTAssertNil(account.updatedAt)
        XCTAssertEqual(account.state, .needsSignIn)
        XCTAssertNotNil(harness.store.login?.error)
        XCTAssertEqual(harness.saved.last?.accounts[0], account)
    }

    func testSameIdentityNetworkFailurePreservesLastSuccessfulSnapshot() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.worker.identity = CodexIdentity(email: "old@fixture.test", planType: "plus", type: "chatgpt")
        harness.worker.limitsHandler = { throw StoreFixtureError.offline }
        await harness.store.refresh()
        XCTAssertEqual(harness.store.accounts[0].buckets, harness.cached.accounts[0].buckets)
        XCTAssertEqual(harness.store.accounts[0].updatedAt, harness.cached.accounts[0].updatedAt)
        XCTAssertNotNil(harness.store.accounts[0].issue)
    }

    func testMissingAuthenticationClearsQuotaWithoutInventingFreshUsage() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.worker.identity = nil
        await harness.store.refresh()
        XCTAssertEqual(harness.store.accounts[0].state, .needsSignIn)
        XCTAssertTrue(harness.store.accounts[0].buckets.isEmpty)
        XCTAssertNil(harness.store.accounts[0].updatedAt)
        XCTAssertEqual(harness.worker.limitsCalls, 0)
    }

    func testDisconnectWaitsForRefreshAndCannotBeOverwrittenByItsResult() async {
        let harness = Harness()
        defer { harness.finish() }
        let gate = Deferred<RateLimitsResponse>()
        harness.worker.limitsHandler = { try await gate.wait() }
        let refresh = Task { await harness.store.refresh() }
        await eventually { harness.worker.limitsCalls == 1 }
        let disconnect = Task { await harness.store.disconnect("account-1") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(harness.worker.disconnectCalls, 0)
        gate.succeed(StoreConnectionFixture.limits)
        await refresh.value
        await disconnect.value
        XCTAssertEqual(harness.worker.events, ["limits returned", "disconnected"])
        XCTAssertEqual(harness.store.accounts[0].state, .disconnected)
        XCTAssertTrue(harness.store.accounts[0].buckets.isEmpty)
        XCTAssertNil(harness.store.accounts[0].email)
        XCTAssertEqual(harness.saved.last?.accounts[0].state, .disconnected)
    }

    func testCancelingQueuedDisconnectDoesNotClearRefreshBusyState() async {
        let harness = Harness()
        defer { harness.finish() }
        let gate = Deferred<RateLimitsResponse>()
        harness.worker.limitsHandler = { try await gate.wait() }
        let refresh = Task { await harness.store.refresh() }
        await eventually { harness.worker.limitsCalls == 1 }
        let disconnect = Task { await harness.store.disconnect("account-1") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        disconnect.cancel()
        await disconnect.value
        XCTAssertTrue(harness.store.busyAccountIDs.contains("account-1"))
        XCTAssertEqual(harness.worker.disconnectCalls, 0)
        gate.succeed(StoreConnectionFixture.limits)
        await refresh.value
        XCTAssertTrue(harness.store.busyAccountIDs.isEmpty)
        XCTAssertEqual(harness.store.accounts[0].state, .connected)
    }

    func testCancelDuringLoginStartCancelsReturnedIDAndReconcilesEmptyAccount() async {
        let harness = Harness(connected: false)
        defer { harness.finish() }
        let gate = Deferred<CodexLogin>()
        harness.worker.beginHandler = { try await gate.wait() }
        harness.worker.identity = nil
        await harness.store.connect("account-1")
        await eventually { harness.worker.beginCalls == 1 }
        let cancel = Task { await harness.store.cancelLogin() }
        await eventually { harness.store.login == nil }
        harness.store.setDemo(true)
        XCTAssertFalse(harness.store.isDemo, "Cleanup must finish before entering demo")
        await harness.store.connect("account-2")
        XCTAssertNil(harness.store.login, "A second browser flow must wait for canceled start to finish")
        gate.succeed(CodexLogin(loginId: "late-login", authURL: URL(string: "https://auth.openai.com/fixture")!))
        await cancel.value
        XCTAssertEqual(harness.worker.canceledLogins, ["late-login"])
        XCTAssertEqual(harness.store.accounts[0].state, .disconnected)
        XCTAssertTrue(harness.store.accounts[0].buckets.isEmpty)
        XCTAssertNil(harness.store.accounts[0].issue)
    }

    func testCancelReconcilesSuccessfulBrowserCallback() async {
        let harness = Harness(connected: false)
        defer { harness.finish() }
        harness.worker.waitHandler = { try await Task.sleep(nanoseconds: 10_000_000_000) }
        await harness.store.connect("account-1")
        await eventually { harness.store.login?.authURL != nil }
        await harness.store.cancelLogin()
        XCTAssertEqual(harness.store.accounts[0].state, .connected)
        XCTAssertEqual(harness.store.accounts[0].email, "current@fixture.test")
        XCTAssertEqual(harness.store.accounts[0].updatedAt, harness.now)
        XCTAssertEqual(harness.worker.canceledLogins, ["fixture-login"])
        XCTAssertNil(harness.store.login)
    }

    func testDuplicateSheetDismissalDoesNotRunSecondCancellation() async {
        let harness = Harness(connected: false)
        defer { harness.finish() }
        let gate = Deferred<CodexLogin>()
        harness.worker.beginHandler = { try await gate.wait() }
        harness.worker.identity = nil
        await harness.store.connect("account-1")
        await eventually { harness.worker.beginCalls == 1 }
        let firstCancel = Task { await harness.store.cancelLogin() }
        await eventually { harness.store.login == nil }
        var duplicateReturned = false
        let duplicate = Task { await harness.store.cancelLogin(); duplicateReturned = true }
        await eventually { duplicateReturned }
        gate.succeed(CodexLogin(loginId: "late-login", authURL: URL(string: "https://auth.openai.com/fixture")!))
        await firstCancel.value
        await duplicate.value
        XCTAssertEqual(harness.worker.canceledLogins, ["late-login"])
        XCTAssertEqual(harness.worker.accountCalls, 1)
    }

    func testDemoNeverPersistsFixturesAndRestoresCachedLiveAccounts() async {
        let harness = Harness(arguments: ["--demo"])
        defer { harness.finish() }
        XCTAssertTrue(harness.store.isDemo)
        await harness.store.refresh()
        await harness.store.connect("account-1")
        await harness.store.disconnect("account-1")
        XCTAssertTrue(harness.saved.isEmpty)
        XCTAssertEqual(harness.worker.accountCalls, 0)
        XCTAssertEqual(harness.widgetReloads, 0)
        harness.store.setDemo(false)
        XCTAssertEqual(harness.store.accounts, harness.cached.accounts)
        harness.worker.identity = CodexIdentity(email: "old@fixture.test", planType: "plus", type: "chatgpt")
        harness.worker.limitsHandler = { throw StoreFixtureError.offline }
        await harness.store.refresh()
        XCTAssertEqual(harness.saved.count, 1)
        XCTAssertEqual(harness.saved[0].accounts[0].email, "old@fixture.test")
        XCTAssertEqual(harness.saved[0].accounts[0].updatedAt, harness.cached.accounts[0].updatedAt)
        XCTAssertFalse(harness.saved[0].accounts.contains { $0.email?.hasSuffix("@example.com") == true })
    }

    func testDeletedChromeProfileSelectionIsClearedAndCannotLaunch() async {
        let profile = ChromeProfile(id: "Profile 1", name: "Existing profile")
        let harness = Harness(connected: false, profiles: [profile], savedProfile: "Profile 9")
        defer { harness.finish() }
        harness.worker.waitHandler = { try await Task.sleep(nanoseconds: 10_000_000_000) }
        await harness.store.connect("account-1")
        await eventually { harness.store.login?.authURL != nil }
        XCTAssertEqual(harness.store.selectedChromeProfileID, "")
        XCTAssertNil((harness.preferences.dictionary(forKey: "chromeProfiles") as? [String: String])?["account-1"])
        harness.store.openSignInInChrome() // No valid profile, so no browser launch.
        harness.store.selectedChromeProfileID = "Profile 1"
        XCTAssertEqual(harness.store.selectedChromeProfileID, "Profile 1")
        harness.store.selectedChromeProfileID = "Profile 9"
        XCTAssertEqual(harness.store.selectedChromeProfileID, "")
        await harness.store.cancelLogin()
    }

    func testNilLocalIdentityNeverBadgesAnAccount() async {
        let harness = Harness()
        defer { harness.finish() }
        await harness.store.refresh()
        XCTAssertNil(harness.store.localCodexEmail)
        XCTAssertFalse(harness.store.accounts.contains(where: harness.store.isLocalAccount))
        XCTAssertEqual(harness.store.localCodexStatus, "Local Codex isn’t signed in.")
    }

    func testLocalIdentityMatchesCaseInsensitivelyAndExpires() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.localIdentity = CodexIdentity(email: "CURRENT@FIXTURE.TEST", planType: "pro", type: "chatgpt")
        await harness.store.refresh()
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[0]))
        XCTAssertEqual(harness.saved.last?.localCodexEmail, "CURRENT@FIXTURE.TEST")
        XCTAssertEqual(harness.saved.last?.localCodexCheckedAt, harness.now)
        harness.now = harness.now.addingTimeInterval(CodexUsageViewerConstants.staleInterval + 1)
        XCTAssertFalse(harness.store.isLocalAccount(harness.store.accounts[0]))
    }

    func testSwitchingLocalAccountMovesBadgeToMatchingSlot() async {
        let harness = Harness()
        defer { harness.finish() }
        let second = StoreConnectionFixture()
        second.identity = CodexIdentity(email: "second@fixture.test", planType: "pro", type: "chatgpt")
        harness.workers["account-2"] = second
        harness.store.accounts[1] = AccountSnapshot(id: "account-2", name: "Second", email: "second@fixture.test", plan: "pro", state: .connected)
        harness.localIdentity = harness.worker.identity
        await harness.store.refresh()
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[0]))
        XCTAssertFalse(harness.store.isLocalAccount(harness.store.accounts[1]))
        harness.localIdentity = second.identity
        await harness.store.refresh()
        XCTAssertFalse(harness.store.isLocalAccount(harness.store.accounts[0]))
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[1]))
    }

    func testUnmatchedLocalAccountIsExplicitAndNoSlotIsBadged() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.localIdentity = CodexIdentity(email: "unmatched@fixture.test", planType: "pro", type: "chatgpt")
        await harness.store.refresh()
        XCTAssertFalse(harness.store.accounts.contains(where: harness.store.isLocalAccount))
        XCTAssertEqual(harness.store.localCodexStatus, "Local Codex uses an account that isn’t connected here.")
    }

    func testLocalDetectionRunsWithoutConnectedViewerAccounts() async {
        let harness = Harness(connected: false)
        defer { harness.finish() }
        harness.localIdentity = harness.worker.identity
        await harness.store.refresh()
        XCTAssertEqual(harness.localReadCalls, 1)
        XCTAssertEqual(harness.worker.accountCalls, 0)
        XCTAssertEqual(harness.store.localCodexEmail, "current@fixture.test")
        XCTAssertFalse(harness.store.accounts.contains(where: harness.store.isLocalAccount))
    }

    func testLocalReadFailureClearsPreviouslyConfirmedBadge() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.localIdentity = harness.worker.identity
        await harness.store.refresh()
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[0]))
        harness.localReadHandler = { throw StoreFixtureError.offline }
        await harness.store.refresh()
        XCTAssertNil(harness.store.localCodexEmail)
        XCTAssertNil(harness.store.localCodexCheckedAt)
        XCTAssertFalse(harness.store.accounts.contains(where: harness.store.isLocalAccount))
        XCTAssertNotNil(harness.store.localCodexStatus)
    }

    func testConnectingRefreshesLocalIdentityWithoutWaitingForPoll() async {
        let harness = Harness(connected: false)
        defer { harness.finish() }
        harness.localIdentity = harness.worker.identity
        await harness.store.connect("account-1")
        await eventually { harness.localReadCalls == 1 && harness.store.login == nil }
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[0]))
    }

    func testChangingCLIPathDiscardsInFlightLocalIdentity() async {
        let harness = Harness(connected: false)
        defer { harness.finish() }
        let gate = Deferred<CodexIdentity?>()
        harness.localReadHandler = { try await gate.wait() }
        let refresh = Task { await harness.store.refresh() }
        await eventually { harness.localReadCalls == 1 }
        harness.store.codexPath = "/different/codex"
        gate.succeed(harness.worker.identity)
        await refresh.value
        XCTAssertNil(harness.store.localCodexEmail)
        XCTAssertNil(harness.store.localCodexCheckedAt)
    }

    func testVerifiedIdentityFullNameIsPublishedAndClearedWhenItChanges() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.worker.identity = CodexIdentity(email: "current@fixture.test", planType: "pro", type: "chatgpt", fullName: "Alex Morgan")
        await harness.store.refresh()
        XCTAssertEqual(harness.store.accounts[0].fullName, "Alex Morgan")
        XCTAssertEqual(harness.store.accounts[0].displayName, "Alex Morgan")
        XCTAssertEqual(harness.saved.last?.accounts[0].fullName, "Alex Morgan")
        harness.worker.identity = CodexIdentity(email: "different@fixture.test", planType: "plus", type: "chatgpt")
        harness.worker.limitsHandler = { throw StoreFixtureError.offline }
        await harness.store.refresh()
        XCTAssertNil(harness.store.accounts[0].fullName)
        XCTAssertEqual(harness.store.accounts[0].displayName, "different@fixture.test")
    }

    func testConnectedUITestFixtureHasNamesPlanAndLocalBadgeWithoutNetwork() async {
        let harness = Harness(arguments: ["--ui-testing", "--ui-testing-connected"])
        defer { harness.finish() }
        XCTAssertFalse(harness.store.isDemo)
        XCTAssertEqual(harness.store.accounts[0].displayName, "Alex Morgan")
        XCTAssertEqual(harness.store.accounts[0].plan, "pro")
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[0]))
        await harness.store.refresh()
        await harness.store.connect("account-1")
        await harness.store.disconnect("account-1")
        XCTAssertEqual(harness.worker.accountCalls, 0)
        XCTAssertEqual(harness.localReadCalls, 0)
        XCTAssertEqual(harness.worker.beginCalls, 0)
        XCTAssertTrue(harness.saved.isEmpty)
    }
}

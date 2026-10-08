import Foundation
import XCTest
@testable import CodexUsageViewerCore

@MainActor
private final class StoreBackgroundFixture: BackgroundServing {
    var state: BackgroundState
    var commands: [BackgroundCommand] = []
    var shutdownCalls = 0
    var handler: ((BackgroundCommand) async throws -> BackgroundState)?

    init(snapshot: UsageSnapshot) {
        state = BackgroundState(snapshot: snapshot, isRefreshing: false, busyAccountIDs: [], login: nil,
                                availableCodex: true, localCodexStatus: "Fixture local account",
                                errorMessage: nil, codexPath: "/fixture/codex")
    }

    func send(_ command: BackgroundCommand) async throws -> BackgroundState {
        commands.append(command)
        if let handler { return try await handler(command) }
        return state
    }

    func shutdown() { shutdownCalls += 1 }
}

@MainActor
private final class UnusedBackgroundStoreWorker: CodexAccountConnection {
    func account() async throws -> CodexIdentity? { throw BackgroundIPCError.unavailable }
    func readLimits() async throws -> RateLimitsResponse { throw BackgroundIPCError.unavailable }
    func beginLogin() async throws -> CodexLogin { throw BackgroundIPCError.unavailable }
    func waitForLogin(loginID: String) async throws { throw BackgroundIPCError.unavailable }
    func cancelLogin(loginID: String) async {}
    func disconnect() async throws { throw BackgroundIPCError.unavailable }
    func stop() {}
}

@MainActor
private final class DeferredBackgroundStoreState {
    private var continuation: CheckedContinuation<BackgroundState, Error>?

    func wait(ready: () -> Void) async throws -> BackgroundState {
        try await withCheckedThrowingContinuation {
            continuation = $0
            ready()
        }
    }

    func succeed(_ state: BackgroundState) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: state)
    }
}

@MainActor
final class BackgroundStoreTests: XCTestCase {
    @MainActor private final class Harness {
        let preferences: UserDefaults
        let suite = "CodexUsageViewerBackgroundStoreTests.\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let cached: UsageSnapshot
        let background: StoreBackgroundFixture
        private let unusedWorker = UnusedBackgroundStoreWorker()
        private(set) var workerCreations = 0
        private(set) var localIdentityReads = 0
        private(set) var snapshotWrites = 0
        private(set) var widgetReloads = 0
        var store: CodexUsageViewerStore!

        init() {
            preferences = UserDefaults(suiteName: suite)!
            var accounts = AccountSnapshot.emptyAccounts
            accounts[0] = AccountSnapshot(
                id: "account-1", name: "Account 1", email: "cached@fixture.test", plan: "pro",
                state: .connected,
                buckets: [UsageBucket(limitId: "codex", secondary: QuotaWindow(
                    usedPercent: 61, windowDurationMins: 10_080, resetsAt: Int(now.timeIntervalSince1970) - 60))],
                updatedAt: now.addingTimeInterval(-1_000))
            cached = UsageSnapshot(accounts: accounts, savedAt: now.addingTimeInterval(-1_000),
                                   localCodexEmail: "cached@fixture.test", localCodexCheckedAt: now.addingTimeInterval(-1_000))
            background = StoreBackgroundFixture(snapshot: cached)
            let dependencies = CodexUsageViewerStoreDependencies(
                loadSnapshot: { [unowned self] in cached },
                saveSnapshot: { [unowned self] _ in snapshotWrites += 1 },
                reloadWidgets: { [unowned self] in widgetReloads += 1 },
                locateExecutable: { _ in URL(fileURLWithPath: "/fixture/codex") },
                makeConnection: { [unowned self] _, _ in
                    workerCreations += 1
                    return unusedWorker
                },
                credentialExists: { _ in false }, discoverChromeProfiles: { [] },
                now: { [unowned self] in now },
                readLocalIdentity: { [unowned self] _ in
                    localIdentityReads += 1
                    return nil
                })
            store = CodexUsageViewerStore(dependencies: dependencies, preferences: preferences, background: background)
        }

        func assertHelperOwnsAllAccountWork(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(workerCreations, 0, file: file, line: line)
            XCTAssertEqual(localIdentityReads, 0, file: file, line: line)
            XCTAssertEqual(snapshotWrites, 0, file: file, line: line)
            XCTAssertEqual(widgetReloads, 0, file: file, line: line)
        }

        func finish() {
            store.shutdown()
            preferences.removePersistentDomain(forName: suite)
        }
    }

    func testAccountActionsOnlySendHelperCommands() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.background.handler = { [unowned harness] command in
            switch command {
            case .connect(let accountID):
                harness.background.state.login = PendingLogin(id: accountID, accountName: "Fixture", isWaiting: true)
            case .cancelLogin:
                harness.background.state.login = nil
            default: break
            }
            return harness.background.state
        }
        await harness.store.refresh()
        await harness.store.connect("account-2")
        XCTAssertEqual(harness.store.login?.id, "account-2")
        await harness.store.cancelLogin()
        XCTAssertNil(harness.store.login)
        await harness.store.disconnect("account-1")
        XCTAssertEqual(harness.background.commands, [
            .refresh, .connect(accountID: "account-2"), .cancelLogin, .disconnect(accountID: "account-1")
        ])
        harness.assertHelperOwnsAllAccountWork()
    }

    func testHelperStateUpdatesAccountAndLocalBadgeWithoutRepublishingSnapshot() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.background.state.snapshot.accounts[0].email = "fresh@fixture.test"
        harness.background.state.snapshot.accounts[0].updatedAt = harness.now
        harness.background.state.snapshot.localCodexEmail = "FRESH@fixture.test"
        harness.background.state.snapshot.localCodexCheckedAt = harness.now
        harness.background.state.isRefreshing = true
        harness.background.state.busyAccountIDs = ["account-1"]
        harness.background.state.codexPath = "/fixture/new-codex"
        harness.background.state.availableCodex = false
        await harness.store.sendToBackground(.state)

        XCTAssertEqual(harness.store.accounts[0].email, "fresh@fixture.test")
        XCTAssertEqual(harness.store.localCodexCheckedAt, harness.now)
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[0]))
        XCTAssertTrue(harness.store.isRefreshing)
        XCTAssertEqual(harness.store.busyAccountIDs, ["account-1"])
        XCTAssertFalse(harness.store.availableCodex)
        XCTAssertEqual(harness.store.codexPath, "/fixture/new-codex")
        XCTAssertEqual(harness.background.commands, [.state], "Applying a helper path must not send a new setExecutable command")
        harness.assertHelperOwnsAllAccountWork()
    }

    func testDemoPreservesItsFixtureWhileCachingNewLiveHelperState() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.store.setDemo(true)
        let demoAccounts = harness.store.accounts
        harness.background.state.snapshot.accounts[0].email = "updated-while-demo@fixture.test"
        harness.background.state.snapshot.localCodexEmail = "updated-while-demo@fixture.test"
        harness.background.state.snapshot.localCodexCheckedAt = harness.now
        await harness.store.sendToBackground(.state)
        await harness.store.refresh()
        XCTAssertEqual(harness.store.accounts, demoAccounts)
        XCTAssertFalse(harness.store.isLocalAccount(harness.store.accounts[0]))
        XCTAssertEqual(harness.background.commands, [.state], "Demo refresh must not request account work")

        harness.store.setDemo(false)
        XCTAssertEqual(harness.store.accounts[0].email, "updated-while-demo@fixture.test")
        XCTAssertTrue(harness.store.isLocalAccount(harness.store.accounts[0]))
        harness.assertHelperOwnsAllAccountWork()
    }

    func testShutdownClosesAppConnectionWithoutCancelingHelperLogin() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.background.state.login = PendingLogin(id: "account-2", accountName: "Fixture", isWaiting: true)
        await harness.store.sendToBackground(.state)
        harness.store.shutdown()
        XCTAssertEqual(harness.background.shutdownCalls, 1)
        XCTAssertEqual(harness.background.commands, [.state])
        XCTAssertEqual(harness.background.state.login?.id, "account-2")
        await harness.store.sendToBackground(.refresh)
        XCTAssertEqual(harness.background.commands, [.state], "A stopped app must send no further commands")
        harness.assertHelperOwnsAllAccountWork()
    }

    func testHelperFailurePreservesUsageAgeAndDoesNotAssumeResetRecovery() async {
        let harness = Harness()
        defer { harness.finish() }
        harness.background.handler = { _ in throw BackgroundIPCError.unavailable }
        await harness.store.refresh()
        XCTAssertEqual(harness.store.accounts, harness.cached.accounts)
        XCTAssertEqual(harness.store.localCodexCheckedAt, harness.cached.localCodexCheckedAt)
        XCTAssertTrue(harness.store.accounts[0].isStale(at: harness.now))
        XCTAssertEqual(harness.store.accounts[0].primaryBucket?.secondary?.usedPercent, 61)
        XCTAssertFalse(harness.store.isLocalAccount(harness.store.accounts[0]))
        XCTAssertNotNil(harness.store.errorMessage)
        harness.assertHelperOwnsAllAccountWork()
    }

    func testEarlierResponseCannotOverwriteNewerAppliedState() async {
        let harness = Harness()
        defer { harness.finish() }
        let gate = DeferredBackgroundStoreState()
        let waiting = expectation(description: "older request waiting")
        let oldState = harness.background.state
        harness.background.handler = { _ in try await gate.wait { waiting.fulfill() } }
        let olderRequest = Task { await harness.store.sendToBackground(.state) }
        await fulfillment(of: [waiting], timeout: 1)
        harness.background.handler = nil
        harness.background.state.snapshot.accounts[0].email = "newer@fixture.test"
        await harness.store.sendToBackground(.state)
        gate.succeed(oldState)
        await olderRequest.value
        XCTAssertEqual(harness.store.accounts[0].email, "newer@fixture.test")
        harness.assertHelperOwnsAllAccountWork()
    }

    func testEarlierSuccessCannotClearNewerConnectionFailure() async {
        let harness = Harness()
        defer { harness.finish() }
        let gate = DeferredBackgroundStoreState()
        let waiting = expectation(description: "older request waiting")
        harness.background.handler = { command in
            if command == .state { return try await gate.wait { waiting.fulfill() } }
            throw BackgroundIPCError.unavailable
        }
        let olderRequest = Task { await harness.store.sendToBackground(.state) }
        await fulfillment(of: [waiting], timeout: 1)
        await harness.store.refresh()
        let failure = harness.store.errorMessage
        XCTAssertNotNil(failure)
        var lateState = harness.background.state
        lateState.snapshot.accounts[0].email = "outdated-response@fixture.test"
        gate.succeed(lateState)
        await olderRequest.value
        XCTAssertEqual(harness.store.errorMessage, failure)
        XCTAssertEqual(harness.store.accounts, harness.cached.accounts)
        harness.assertHelperOwnsAllAccountWork()
    }

    func testHelperNeverOverwritesBrowserProfilesOwnedByTheApp() async {
        let suite = "CodexUsageViewerHelperBrowserPreferenceTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let original = ["account-2": "Profile 2"]
        preferences.set(original, forKey: "chromeProfiles")
        var discoveries = 0
        let worker = UnusedBackgroundStoreWorker()
        let dependencies = CodexUsageViewerStoreDependencies(
            loadSnapshot: { .empty }, saveSnapshot: { _ in }, reloadWidgets: {},
            locateExecutable: { _ in URL(fileURLWithPath: "/fixture/codex") },
            makeConnection: { _, _ in worker }, credentialExists: { _ in false },
            discoverChromeProfiles: { discoveries += 1; return [] }, now: Date.init,
            readLocalIdentity: { _ in nil })
        let engine = CodexUsageViewerStore(dependencies: dependencies, preferences: preferences,
                                          managesChromeProfiles: false)
        defer { engine.shutdown() }
        XCTAssertEqual(preferences.dictionary(forKey: "chromeProfiles") as? [String: String], original)

        // The helper stays alive while the app chooses a profile in a later login.
        let appSelection = ["account-1": "Profile 1", "account-2": "Profile 2"]
        preferences.set(appSelection, forKey: "chromeProfiles")
        await engine.connect("account-3")

        XCTAssertEqual(engine.login?.id, "account-3")
        XCTAssertEqual(discoveries, 0, "The helper must not discover browser profiles")
        XCTAssertEqual(preferences.dictionary(forKey: "chromeProfiles") as? [String: String], appSelection,
                       "A helper login must preserve the app's newer browser choices")
    }
}

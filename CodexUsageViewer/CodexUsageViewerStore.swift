import AppKit
import Combine
import Foundation
import WidgetKit

struct PendingLogin: Identifiable {
    var id: String
    var accountName: String
    var authURL: URL?
    var isWaiting: Bool
    var error: String?
}

@MainActor
struct CodexUsageViewerStoreDependencies {
    var loadSnapshot: () -> UsageSnapshot
    var saveSnapshot: (UsageSnapshot) throws -> Void
    var reloadWidgets: () -> Void
    var locateExecutable: (String?) -> URL?
    var makeConnection: (String, URL) -> any CodexAccountConnection
    var credentialExists: (String) -> Bool
    var discoverChromeProfiles: () -> [ChromeProfile]
    var now: () -> Date
    var readLocalIdentity: (URL) async throws -> CodexIdentity?

    static var live: Self {
        Self(loadSnapshot: SharedSnapshotStore.load, saveSnapshot: SharedSnapshotStore.save,
             reloadWidgets: { WidgetCenter.shared.reloadTimelines(ofKind: CodexUsageViewerConstants.widgetKind) },
             locateExecutable: CodexConnection.locateExecutable,
             makeConnection: { CodexConnection(accountID: $0, executableURL: $1) },
             credentialExists: { id in
                 guard CodexUsageViewerConstants.accountIDs.contains(id) else { return false }
                 let root = FileManager.default.homeDirectoryForCurrentUser
                     .appendingPathComponent("Library/Application Support/CodexUsageViewer/Accounts")
                 return FileManager.default.fileExists(atPath: root.appendingPathComponent(id).appendingPathComponent("auth.json").path)
             }, discoverChromeProfiles: ChromeProfile.discover, now: Date.init,
             readLocalIdentity: { try await CodexConnection.readLocalIdentity(executableURL: $0) })
    }
}

@MainActor
final class CodexUsageViewerStore: ObservableObject {
    @Published var accounts: [AccountSnapshot]
    @Published var isRefreshing = false
    @Published var isDemo = false
    @Published var errorMessage: String?
    @Published var login: PendingLogin?
    @Published private(set) var localCodexEmail: String?
    @Published private(set) var localCodexStatus: String?
    @Published private(set) var localCodexCheckedAt: Date?
    @Published var codexPath: String {
        didSet {
            preferences.set(codexPath, forKey: "codexExecutable")
            for connection in connections.values { connection.stop() }
            connections.removeAll()
            availableCodex = dependencies.locateExecutable(codexPath) != nil
            localCodexEmail = nil
            localCodexCheckedAt = nil
            localCodexStatus = "Refresh to check the local Codex account."
            localLookupID = UUID()
        }
    }
    @Published private(set) var availableCodex: Bool
    @Published private(set) var chromeProfiles: [ChromeProfile]
    @Published private(set) var busyAccountIDs: Set<String> = []
    @Published var launchAtLogin = false
    var openDashboardAction: (() -> Void)?
    private let dependencies: CodexUsageViewerStoreDependencies
    private let preferences: UserDefaults
    private let isUITesting: Bool
    private var connections: [String: any CodexAccountConnection] = [:]
    private var liveAccounts: [AccountSnapshot]
    private var pollTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var activeLoginID: String?
    private var loginAttemptID: UUID?
    private var pendingDisconnectIDs: Set<String> = []
    private var profileSelections: [String: String]
    private var localLookupID = UUID()

    func isLocalAccount(_ account: AccountSnapshot) -> Bool {
        guard !isDemo else { return false }
        var snapshot = UsageSnapshot(accounts: accounts, savedAt: dependencies.now())
        snapshot.localCodexEmail = localCodexEmail
        snapshot.localCodexCheckedAt = localCodexCheckedAt
        return snapshot.isLocalAccount(account, at: dependencies.now())
    }

    var selectedChromeProfileID: String {
        get {
            guard let selected = login.flatMap({ profileSelections[$0.id] }),
                  chromeProfiles.contains(where: { $0.id == selected }) else { return "" }
            return selected
        }
        set {
            guard let id = login?.id else { return }
            objectWillChange.send()
            if chromeProfiles.contains(where: { $0.id == newValue }) {
                profileSelections[id] = newValue
            } else {
                profileSelections.removeValue(forKey: id)
            }
            preferences.set(profileSelections, forKey: "chromeProfiles")
        }
    }

    func openSignInInChrome() {
        guard let url = login?.authURL, !selectedChromeProfileID.isEmpty else { return }
        let profileID = selectedChromeProfileID
        guard chromeProfiles.contains(where: { $0.id == profileID }) else { return }
        let attempt = loginAttemptID
        Task {
            do { try await ChromeProfile.open(url, profileID: profileID) }
            catch {
                guard loginAttemptID == attempt else { return }
                login?.error = "Chrome couldn’t open this profile. You can still copy the sign-in link and open it yourself."
            }
        }
    }

    convenience init() {
        self.init(dependencies: .live, preferences: .standard, startsPolling: true,
                  arguments: ProcessInfo.processInfo.arguments)
    }

    init(dependencies: CodexUsageViewerStoreDependencies, preferences: UserDefaults,
         startsPolling: Bool = false, arguments: [String] = []) {
        self.dependencies = dependencies
        self.preferences = preferences
        isUITesting = arguments.contains("--ui-testing")
        profileSelections = preferences.dictionary(forKey: "chromeProfiles") as? [String: String] ?? [:]
        let discoveredProfiles = dependencies.discoverChromeProfiles()
        chromeProfiles = discoveredProfiles
        profileSelections = profileSelections.filter { _, profileID in discoveredProfiles.contains(where: { $0.id == profileID }) }
        preferences.set(profileSelections, forKey: "chromeProfiles")
        let path = preferences.string(forKey: "codexExecutable") ?? ""
        codexPath = path
        availableCodex = dependencies.locateExecutable(path) != nil
        let cachedSnapshot = isUITesting ? UsageSnapshot.empty : dependencies.loadSnapshot()
        var cached = cachedSnapshot.accounts
        if !isUITesting {
            // Check app-owned credential existence, without reading tokens.
            for index in cached.indices where cached[index].state == .disconnected {
                if dependencies.credentialExists(cached[index].id) {
                    cached[index].state = .needsSignIn
                }
            }
        }
        accounts = cached
        liveAccounts = cached
        localCodexEmail = cachedSnapshot.localCodexEmail
        localCodexCheckedAt = cachedSnapshot.localCodexCheckedAt
        if arguments.contains("--demo") {
            isDemo = true
            accounts = UsageSnapshot.preview.accounts
        }
        if isUITesting && arguments.contains("--ui-testing-connected") {
            accounts = UsageSnapshot.preview.accounts
            liveAccounts = accounts
            isDemo = false
            localCodexEmail = accounts.first?.email
            localCodexCheckedAt = dependencies.now()
        }
        updateLocalCodexMatchStatus()
        if startsPolling && !isUITesting {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: .seconds(CodexUsageViewerConstants.refreshInterval)) }
                    catch { return }
                }
            }
        }
    }

    private func connection(for id: String) throws -> any CodexAccountConnection {
        if let connection = connections[id] { return connection }
        guard CodexUsageViewerConstants.accountIDs.contains(id),
              let executable = dependencies.locateExecutable(codexPath) else {
            throw NSError(domain: "CodexUsageViewer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex CLI wasn’t found. Choose its executable in Settings, then try again."])
        }
        let connection = dependencies.makeConnection(id, executable)
        connections[id] = connection
        return connection
    }

    func refresh() async {
        guard !isDemo, !isUITesting, !isRefreshing else { return }
        availableCodex = dependencies.locateExecutable(codexPath) != nil
        isRefreshing = true
        defer { isRefreshing = false }
        async let localRefresh: Void = refreshLocalCodexIdentity()
        for id in CodexUsageViewerConstants.accountIDs {
            guard let account = accounts.first(where: { $0.id == id }),
                  account.state != .disconnected, login?.id != id else { continue }
            await refreshAccount(id)
        }
        await localRefresh
        updateLocalCodexMatchStatus()
        persist()
    }

    private func refreshLocalCodexIdentity() async {
        guard !isDemo, !isUITesting else { return }
        let lookup = UUID()
        localLookupID = lookup
        guard let executable = dependencies.locateExecutable(codexPath) else {
            localCodexEmail = nil
            localCodexCheckedAt = nil
            localCodexStatus = "Choose the Codex CLI to detect your local account."
            return
        }
        do {
            let identity = try await dependencies.readLocalIdentity(executable)
            guard localLookupID == lookup, !isDemo else { return }
            localCodexCheckedAt = dependencies.now()
            guard let identity else {
                localCodexEmail = nil
                localCodexStatus = "Local Codex isn’t signed in."
                return
            }
            guard identity.type == "chatgpt", let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                localCodexEmail = nil
                localCodexStatus = identity.type == "apiKey" ? "Local Codex uses API-key authentication." : "Local Codex didn’t return an account email."
                return
            }
            localCodexEmail = email
            updateLocalCodexMatchStatus()
        } catch {
            guard localLookupID == lookup else { return }
            localCodexEmail = nil
            localCodexCheckedAt = nil
            localCodexStatus = "Local Codex identity couldn’t be read. Refresh to try again."
        }
    }

    private func updateLocalCodexMatchStatus() {
        guard !isDemo else { localCodexStatus = nil; return }
        guard localCodexEmail != nil, let checkedAt = localCodexCheckedAt else { return }
        let age = dependencies.now().timeIntervalSince(checkedAt)
        guard age >= -60, age <= CodexUsageViewerConstants.staleInterval else {
            localCodexStatus = "Refresh to check the local Codex account."
            return
        }
        if let account = accounts.first(where: { isLocalAccount($0) }) {
            localCodexStatus = "Local Codex is using \(account.displayName)."
        } else {
            localCodexStatus = "Local Codex uses an account that isn’t connected here."
        }
    }

    private func refreshAccount(_ id: String) async {
        guard !busyAccountIDs.contains(id), !pendingDisconnectIDs.contains(id), let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        busyAccountIDs.insert(id)
        defer { busyAccountIDs.remove(id) }
        do {
            let worker = try connection(for: id)
            guard let identity = try await worker.account(), identity.type == "chatgpt" else {
                accounts[index].state = .needsSignIn
                accounts[index].buckets = []
                accounts[index].updatedAt = nil
                accounts[index].issue = "Sign in to reconnect this account."
                return
            }
            if accounts[index].email != identity.email || accounts[index].plan != identity.planType {
                accounts[index].buckets = []
                accounts[index].updatedAt = nil
            }
            accounts[index].email = identity.email
            accounts[index].plan = identity.planType
            accounts[index].fullName = identity.fullName
            accounts[index].state = .connected
            let limits = try await worker.readLimits()
            accounts[index].buckets = limits.buckets
            accounts[index].updatedAt = dependencies.now()
            accounts[index].issue = nil
        } catch {
            accounts[index].issue = error.localizedDescription
            // Preserve the last successful snapshot on failure.
        }
    }

    func connect(_ accountID: String) async {
        guard !isDemo, !isUITesting, login == nil, loginTask == nil, !busyAccountIDs.contains(accountID), !pendingDisconnectIDs.contains(accountID), let account = accounts.first(where: { $0.id == accountID }) else { return }
        chromeProfiles = dependencies.discoverChromeProfiles()
        profileSelections = profileSelections.filter { _, profileID in chromeProfiles.contains(where: { $0.id == profileID }) }
        preferences.set(profileSelections, forKey: "chromeProfiles")
        let attempt = UUID()
        loginAttemptID = attempt
        login = PendingLogin(id: accountID, accountName: account.displayName, isWaiting: true)
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { if loginAttemptID == attempt { loginTask = nil } }
            do {
                let worker = try connection(for: accountID)
                let result = try await worker.beginLogin()
                guard !Task.isCancelled, loginAttemptID == attempt else {
                    await worker.cancelLogin(loginID: result.loginId)
                    return
                }
                activeLoginID = result.loginId
                login?.authURL = result.authURL
                try await worker.waitForLogin(loginID: result.loginId)
                guard !Task.isCancelled, loginAttemptID == attempt else { return }
                if let index = accounts.firstIndex(where: { $0.id == accountID }) {
                    accounts[index] = AccountSnapshot(id: accountID, name: accounts[index].name, state: .needsSignIn)
                }
                await refreshAccount(accountID)
                await refreshLocalCodexIdentity()
                persist()
                if accounts.first(where: { $0.id == accountID })?.isConnected == true {
                    login = nil
                    activeLoginID = nil
                } else {
                    login?.isWaiting = false
                    login?.error = accounts.first(where: { $0.id == accountID })?.issue ?? "Sign-in finished, but usage could not be read. Close this window and refresh to try again."
                }
            } catch {
                guard !Task.isCancelled, loginAttemptID == attempt else { return }
                login?.isWaiting = false
                login?.error = error.localizedDescription
            }
        }
    }

    func cancelLogin() async {
        // Multiple dismissal callbacks may cancel; only the first owns cleanup.
        guard let accountID = login?.id else { return }
        let loginID = activeLoginID
        let task = loginTask
        loginAttemptID = nil
        // Wait for an in-flight start to return the ID needed to cancel its login.
        if loginID != nil { task?.cancel() }
        activeLoginID = nil
        login = nil
        if let loginID {
            await connections[accountID]?.cancelLogin(loginID: loginID)
        }
        await task?.value
        loginTask = nil
        // A browser callback may have completed just as Cancel was pressed.
        if !isDemo, !pendingDisconnectIDs.contains(accountID) {
            await refreshAccount(accountID)
            if let index = accounts.firstIndex(where: { $0.id == accountID }), accounts[index].email == nil, accounts[index].state == .needsSignIn {
                accounts[index].state = .disconnected
                accounts[index].issue = nil
            }
            persist()
        }
    }

    func disconnect(_ accountID: String) async {
        guard !isDemo, !isUITesting, let index = accounts.firstIndex(where: { $0.id == accountID }), !pendingDisconnectIDs.contains(accountID) else { return }
        pendingDisconnectIDs.insert(accountID)
        var ownsBusyState = false
        defer {
            pendingDisconnectIDs.remove(accountID)
            if ownsBusyState { busyAccountIDs.remove(accountID) }
        }
        if login?.id == accountID { await cancelLogin() }
        while busyAccountIDs.contains(accountID) {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        busyAccountIDs.insert(accountID)
        ownsBusyState = true
        do {
            let worker = try connection(for: accountID)
            try await worker.disconnect()
            worker.stop()
            connections.removeValue(forKey: accountID)
            accounts[index] = AccountSnapshot(id: accountID, name: accounts[index].name)
            updateLocalCodexMatchStatus()
            persist()
        } catch { errorMessage = "Couldn’t disconnect: \(error.localizedDescription)" }
    }

    func setDemo(_ enabled: Bool) {
        guard login == nil, loginTask == nil, !isRefreshing, busyAccountIDs.isEmpty, pendingDisconnectIDs.isEmpty else { return }
        if enabled && !isDemo {
            liveAccounts = accounts
            accounts = UsageSnapshot.preview.accounts
        } else if !enabled && isDemo {
            accounts = liveAccounts
        }
        isDemo = enabled
        updateLocalCodexMatchStatus()
    }

    func openDashboard() {
        openDashboardAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        pollTask?.cancel()
        loginTask?.cancel()
        localLookupID = UUID()
        connections.values.forEach { $0.stop() }
    }

    private func persist() {
        guard !isDemo, !isUITesting else { return }
        liveAccounts = accounts
        do {
            var snapshot = UsageSnapshot(accounts: accounts, savedAt: dependencies.now())
            snapshot.localCodexEmail = localCodexEmail
            snapshot.localCodexCheckedAt = localCodexCheckedAt
            try dependencies.saveSnapshot(snapshot)
            dependencies.reloadWidgets()
        } catch { errorMessage = error.localizedDescription }
    }
}

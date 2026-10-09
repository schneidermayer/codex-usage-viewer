import Foundation
import Darwin

struct CodexIdentity: Decodable, Equatable, Sendable {
    let email: String?
    let planType: String?
    let type: String
    var fullName: String? = nil

    private enum CodingKeys: String, CodingKey { case email, planType, type }
}

struct CodexLogin: Sendable {
    let loginId: String
    let authURL: URL
}

enum CodexConnectionError: LocalizedError, Equatable {
    case invalidAccount, unavailable, invalidResponse, stopped, timedOut, loginTimedOut, loginFailed, loginAlreadyWaiting, readOnly
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "This account's local sign-in folder is unavailable."
        case .unavailable: return "Codex could not start. Check the Codex CLI path in Settings."
        case .invalidResponse: return "Codex returned an unreadable response. Update the Codex CLI and try again."
        case .stopped: return "The Codex connection closed. Try refreshing."
        case .timedOut: return "Codex took too long to respond. Check your connection and try again."
        case .loginTimedOut: return "The sign-in link expired. Start sign-in again."
        case .loginFailed: return "Sign-in did not complete. Start sign-in again."
        case .loginAlreadyWaiting: return "Sign-in is already in progress for this account."
        case .readOnly: return "Local Codex detection only supports reading account identity."
        case .requestFailed(let code): return "Codex could not complete the request (\(code)). Try refreshing or sign in again."
        }
    }
}

@MainActor
protocol CodexAccountConnection: AnyObject {
    func account() async throws -> CodexIdentity?
    func readLimits() async throws -> RateLimitsResponse
    func beginLogin() async throws -> CodexLogin
    func waitForLogin(loginID: String) async throws
    func cancelLogin(loginID: String) async
    func disconnect() async throws
    func stop()
}

/// One process and private CODEX_HOME per account.
@MainActor
final class CodexConnection: CodexAccountConnection {
    /// Set before connecting. Workers rejoin the helper's process group for launchd cleanup after a crash.
    static var workerLauncherURL: URL?

    static func runWorkerIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.dropFirst().first == "--codex-worker" else { return }
        guard arguments.count >= 5,
              let parent = pid_t(arguments[2]), parent > 1,
              let group = pid_t(arguments[3]), group > 1,
              getppid() == parent, getpgid(parent) == group,
              arguments[4].hasPrefix("/"),
              !arguments.dropFirst(4).contains(where: { $0.utf8.contains(0) }) else { _exit(64) }
        guard setpgid(0, group) == 0 else { _exit(71) }
        // Parent death before joining could otherwise escape launchd's cleanup.
        guard getppid() == parent else { _exit(71) }
        // Undo the helper's ignored signals before exec.
        for value in [SIGTERM, SIGINT, SIGHUP] { signal(value, SIG_DFL) }
        var mask = sigset_t()
        sigemptyset(&mask)
        sigprocmask(SIG_SETMASK, &mask, nil)
        var argv = arguments.dropFirst(4).map { strdup($0) }
        guard !argv.contains(where: { $0 == nil }) else { _exit(71) }
        argv.append(nil)
        argv.withUnsafeMutableBufferPointer { buffer in
            _ = execv(arguments[4], buffer.baseAddress!)
        }
        _exit(71)
    }

    let accountID: String
    private let executableURL: URL
    private let accountRoot: URL
    private let requestTimeout: TimeInterval
    private let loginTimeout: TimeInterval
    private let localIdentityOnly: Bool
    private var process: Process?
    private var processUsesHelperGroup = false
    private var input: FileHandle?
    private var output: FileHandle?
    private var framer = CodexRPCFramer()
    private var initialized = false
    private var startup: Task<Void, Error>?
    private var startupID: UUID?
    private var nextID = 1
    private var generation = UUID()

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private struct PendingLogin {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var requests: [Int: PendingRequest] = [:]
    private var logins: [String: PendingLogin] = [:]
    private var loginOutcomes: [String: Bool] = [:]

    init(accountID: String, executableURL: URL) {
        self.accountID = accountID
        self.executableURL = executableURL
        self.accountRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexUsageViewer/Accounts", isDirectory: true)
        self.requestTimeout = 30
        self.loginTimeout = 15 * 60
        self.localIdentityOnly = false
    }

    init(accountID: String, executableURL: URL, accountRoot: URL, requestTimeout: TimeInterval, loginTimeout: TimeInterval = 900) {
        self.accountID = accountID
        self.executableURL = executableURL
        self.accountRoot = accountRoot
        self.requestTimeout = requestTimeout
        self.loginTimeout = loginTimeout
        self.localIdentityOnly = false
    }

    private init(localIdentityExecutable executableURL: URL, codexHome: URL, requestTimeout: TimeInterval) {
        accountID = "local-codex"
        self.executableURL = executableURL
        accountRoot = codexHome
        self.requestTimeout = requestTimeout
        loginTimeout = 0
        localIdentityOnly = true
    }

    /// Reads local identity through Codex, without accessing its tokens.
    static func readLocalIdentity(executableURL: URL) async throws -> CodexIdentity? {
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return try await readLocalIdentity(executableURL: executableURL, codexHome: codexHome)
    }

    static func readLocalIdentity(executableURL: URL, codexHome: URL, requestTimeout: TimeInterval = 10) async throws -> CodexIdentity? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexHome.path, isDirectory: &directory), directory.boolValue else { return nil }
        let connection = CodexConnection(localIdentityExecutable: executableURL, codexHome: codexHome, requestTimeout: requestTimeout)
        defer { connection.stop() }
        return try await connection.account()
    }

    func account() async throws -> CodexIdentity? {
        struct AccountResponse: Decodable { let account: CodexIdentity? }
        try await ensureStarted()
        let response: AccountResponse = try await request("account/read", params: ["refreshToken": false])
        var identity = response.account
        if !localIdentityOnly, identity?.type == "chatgpt", let email = identity?.email {
            let directory = accountRoot.appendingPathComponent(accountID, isDirectory: true)
            identity?.fullName = CodexProfileName.readFromAppOwnedAccount(directory: directory, matchingEmail: email)
        }
        return identity
    }

    func readLimits() async throws -> RateLimitsResponse {
        guard !localIdentityOnly else { throw CodexConnectionError.readOnly }
        try await ensureStarted()
        return try await request("account/rateLimits/read")
    }

    func beginLogin() async throws -> CodexLogin {
        guard !localIdentityOnly else { throw CodexConnectionError.readOnly }
        struct LoginResponse: Decodable { let type: String; let loginId: String; let authUrl: String }
        try await ensureStarted()
        let response: LoginResponse = try await request("account/login/start", params: ["type": "chatgpt"])
        guard response.type == "chatgpt", !response.loginId.isEmpty,
              let url = Self.validatedLoginURL(response.authUrl) else {
            throw CodexConnectionError.invalidResponse
        }
        return CodexLogin(loginId: response.loginId, authURL: url)
    }

    func waitForLogin(loginID: String) async throws {
        guard !localIdentityOnly else { throw CodexConnectionError.readOnly }
        try Task.checkCancellation()
        if let success = loginOutcomes.removeValue(forKey: loginID) {
            if !success { throw CodexConnectionError.loginFailed }
            return
        }
        guard process?.isRunning == true else { throw CodexConnectionError.stopped }
        guard logins[loginID] == nil else { throw CodexConnectionError.loginAlreadyWaiting }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(self?.loginTimeout ?? 900)) }
                    catch { return }
                    guard let self else { return }
                    self.finishLogin(loginID, result: .failure(CodexConnectionError.loginTimedOut))
                    // finishLogin cancels this task; send the RPC from a fresh task.
                    Task { [weak self] in await self?.cancelLogin(loginID: loginID) }
                }
                logins[loginID] = PendingLogin(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLogin(loginID, result: .failure(CancellationError()))
                await self?.cancelLogin(loginID: loginID)
            }
        }
    }

    func cancelLogin(loginID: String) async {
        guard !localIdentityOnly else { return }
        finishLogin(loginID, result: .failure(CancellationError()))
        loginOutcomes.removeValue(forKey: loginID)
        guard process?.isRunning == true, initialized else { return }
        let _: EmptyResponse? = try? await request("account/login/cancel", params: ["loginId": loginID])
    }

    func disconnect() async throws {
        guard !localIdentityOnly else { throw CodexConnectionError.readOnly }
        try await ensureStarted()
        let _: EmptyResponse = try await request("account/logout")
        stop()
    }

    func stop() {
        startup?.cancel()
        startup = nil
        startupID = nil
        endTransport(with: CodexConnectionError.stopped)
    }

    deinit {
        output?.readabilityHandler = nil
        if let process { Self.terminate(process, sharesHelperGroup: processUsesHelperGroup) }
        try? input?.close()
        try? output?.close()
    }

    private struct EmptyResponse: Decodable {}

    private func ensureStarted() async throws {
        try Task.checkCancellation()
        if initialized, process?.isRunning == true { return }
        if let startup { return try await startup.value }
        let attempt = UUID()
        startupID = attempt
        let task = Task { [weak self] in
            guard let self else { throw CodexConnectionError.stopped }
            try self.startTransport()
            let _: EmptyResponse = try await self.request("initialize", params: [
                "clientInfo": ["name": "codexusageviewer", "title": "Codex Usage Viewer", "version": CodexUsageViewerVersion.display],
                "capabilities": ["experimentalApi": false]
            ])
            try Task.checkCancellation()
            try self.write(["method": "initialized"])
            self.initialized = true
        }
        startup = task
        defer {
            if startupID == attempt { startup = nil; startupID = nil }
        }
        do { try await task.value }
        catch {
            if startupID == attempt { endTransport(with: error) }
            throw error
        }
    }

    private func startTransport() throws {
        let folder: URL
        if localIdentityOnly {
            folder = accountRoot
        } else {
            guard CodexUsageViewerConstants.accountIDs.contains(accountID) else { throw CodexConnectionError.invalidAccount }
            folder = accountRoot.appendingPathComponent(accountID, isDirectory: true)
            try Self.prepareDirectory(accountRoot.deletingLastPathComponent())
            try Self.prepareDirectory(accountRoot)
            try Self.prepareDirectory(folder)
        }
        generation = UUID()
        let currentGeneration = generation
        framer = CodexRPCFramer()
        initialized = false
        loginOutcomes.removeAll()

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = executableURL
        child.arguments = ["app-server", "--listen", "stdio://"]
        if !localIdentityOnly { child.arguments?.append(contentsOf: ["-c", "cli_auth_credentials_store=\"file\""]) }
        processUsesHelperGroup = Self.workerLauncherURL != nil
        if let launcher = Self.workerLauncherURL {
            child.executableURL = launcher
            child.arguments = ["--codex-worker", String(getpid()), String(getpgrp()), executableURL.path]
                + (child.arguments ?? [])
        }
        child.currentDirectoryURL = folder
        child.environment = Self.isolatedEnvironment(executableURL: executableURL, accountDirectory: folder)
        child.standardInput = stdin
        child.standardOutput = stdout
        // Diagnostics may contain credentials; discard them.
        child.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                if data.isEmpty {
                    // Deliver the final queued response before reporting process exit.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard self.generation == currentGeneration else { return }
                    self.endTransport(with: CodexConnectionError.stopped)
                } else {
                    self.receive(data)
                }
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.generation == currentGeneration else { return }
                self.endTransport(with: CodexConnectionError.stopped)
            }
        }
        process = child
        do { try child.run() }
        catch {
            endTransport(with: CodexConnectionError.unavailable)
            throw CodexConnectionError.unavailable
        }
    }

    private func request<Response: Decodable>(_ method: String, params: [String: Any]? = nil) async throws -> Response {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw CodexConnectionError.stopped }
        let id = nextID
        nextID += 1
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(self?.requestTimeout ?? 30)) }
                    catch { return }
                    self?.finishRequest(id, result: .failure(CodexConnectionError.timedOut))
                }
                requests[id] = PendingRequest(continuation: continuation, timeout: timeout)
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                do { try write(message) }
                catch { finishRequest(id, result: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishRequest(id, result: .failure(CancellationError())) }
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw CodexConnectionError.invalidResponse }
    }

    private func write(_ message: [String: Any]) throws {
        if localIdentityOnly, let method = message["method"] as? String,
           !["initialize", "initialized", "account/read"].contains(method) {
            throw CodexConnectionError.readOnly
        }
        guard let input, process?.isRunning == true else { throw CodexConnectionError.stopped }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.write(contentsOf: data)
        } catch { throw CodexConnectionError.stopped }
    }

    private func receive(_ data: Data) {
        do {
            for line in try framer.append(data) {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexConnectionError.invalidResponse
                }
                if let method = message["method"] as? String {
                    if let id = message["id"] {
                        // Reject unsolicited tool, shell, and token-refresh requests.
                        try write(["id": id, "error": ["code": -32601, "message": "Unsupported method"]])
                    } else if method == "account/login/completed",
                              let params = message["params"] as? [String: Any],
                              let loginID = params["loginId"] as? String,
                              let success = params["success"] as? Bool {
                        if logins[loginID] != nil {
                            finishLogin(loginID, result: success ? .success(()) : .failure(CodexConnectionError.loginFailed))
                        } else {
                            if loginOutcomes.count >= 32 { loginOutcomes.removeAll() }
                            loginOutcomes[loginID] = success
                        }
                    }
                    continue
                }
                guard let id = message["id"] as? Int else { throw CodexConnectionError.invalidResponse }
                guard requests[id] != nil else { continue } // A canceled or timed-out response.
                if let error = message["error"] as? [String: Any] {
                    finishRequest(id, result: .failure(CodexConnectionError.requestFailed(error["code"] as? Int ?? -32603)))
                } else if let result = message["result"], JSONSerialization.isValidJSONObject(result) {
                    finishRequest(id, result: .success(try JSONSerialization.data(withJSONObject: result)))
                } else {
                    throw CodexConnectionError.invalidResponse
                }
            }
        } catch { endTransport(with: CodexConnectionError.invalidResponse) }
    }

    private func finishRequest(_ id: Int, result: Result<Data, Error>) {
        guard let pending = requests.removeValue(forKey: id) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }

    private func finishLogin(_ id: String, result: Result<Void, Error>) {
        guard let pending = logins.removeValue(forKey: id) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }

    private func endTransport(with error: Error) {
        generation = UUID()
        initialized = false
        output?.readabilityHandler = nil
        let child = process
        let sharesHelperGroup = processUsesHelperGroup
        process = nil
        processUsesHelperGroup = false
        child?.terminationHandler = nil
        if let child { Self.terminate(child, sharesHelperGroup: sharesHelperGroup) }
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        for id in Array(requests.keys) { finishRequest(id, result: .failure(error)) }
        for id in Array(logins.keys) { finishLogin(id, result: .failure(error)) }
        loginOutcomes.removeAll()
    }

    private nonisolated static func terminate(_ child: Process, sharesHelperGroup: Bool) {
        guard child.isRunning else { return }
        let pid = child.processIdentifier
        // The helper's group includes other accounts; npm forwards SIGTERM to its child.
        if sharesHelperGroup {
            _ = kill(pid, SIGTERM)
        } else if getpgid(pid) == pid {
            _ = kill(-pid, SIGTERM)
        } else {
            _ = kill(pid, SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            // Retain Process for reaping; escalate only while it is running.
            guard child.isRunning else { return }
            if !sharesHelperGroup, getpgid(pid) == pid {
                _ = kill(-pid, SIGKILL)
            } else {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0.001, min(seconds, 86_400)) * 1_000_000_000)
    }

    private static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CodexConnectionError.invalidAccount }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func isolatedEnvironment(executableURL: URL, accountDirectory: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited.filter { key, _ in
            let upper = key.uppercased()
            return !["CODEX_", "OPENAI_", "CHATGPT_", "AZURE_OPENAI_", "OAI_"].contains(where: upper.hasPrefix)
                && !["ACCESS_TOKEN", "BEARER_TOKEN", "NODE_OPTIONS"].contains(upper)
        }
        environment["CODEX_HOME"] = accountDirectory.path
        // GUI launches have a minimal PATH. Keep the npm wrapper's sibling node first.
        let paths = [executableURL.deletingLastPathComponent().path,
                     executableURL.resolvingSymlinksInPath().deletingLastPathComponent().path,
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            + (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }

    static func validatedLoginURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              host == "openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") else {
            return nil
        }
        return components.url
    }

    static func locateExecutable(override: String?) -> URL? {
        locateExecutable(override: override, environment: ProcessInfo.processInfo.environment,
                         userDirectory: FileManager.default.homeDirectoryForCurrentUser,
                         standardPaths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"])
    }

    // Inspect metadata without executing candidate CLIs.
    static func locateExecutable(override: String?, environment: [String: String], userDirectory: URL, standardPaths: [String]) -> URL? {
        let manager = FileManager.default
        func executable(_ path: String) -> URL? {
            let expanded = NSString(string: path).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), manager.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  !isDirectory.boolValue, manager.isExecutableFile(atPath: expanded) else { return nil }
            let url = URL(fileURLWithPath: expanded)
            let resolved = url.resolvingSymlinksInPath()
            if let root = managedPackageRoot(for: resolved) {
                // An npm entrypoint can survive after macOS removes its native binary.
                guard managedVersion(at: root) != nil, nativeExecutable(in: root) != nil else { return nil }
            }
            return url
        }
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return executable(override.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var candidates = (environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/codex" }
        candidates += standardPaths + [userDirectory.appendingPathComponent(".local/bin/codex").path,
                       userDirectory.appendingPathComponent(".npm-global/bin/codex").path]
        if let selected = candidates.lazy.compactMap(executable).first { return selected }
        let versions = userDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let installed = (try? manager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        let managed = installed.compactMap { node -> (url: URL, version: String)? in
            guard let url = executable(node.appendingPathComponent("bin/codex").path),
                  let root = managedPackageRoot(for: url.resolvingSymlinksInPath()),
                  let version = managedVersion(at: root) else { return nil }
            return (url, version)
        }
        return managed.sorted { left, right in
            let leftCore = left.version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? left.version
            let rightCore = right.version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? right.version
            let coreOrder = leftCore.compare(rightCore, options: .numeric)
            if coreOrder != .orderedSame { return coreOrder == .orderedDescending }
            // Prefer a release over a prerelease of the same version.
            if left.version.contains("-") != right.version.contains("-") { return !left.version.contains("-") }
            let order = left.version.compare(right.version, options: .numeric)
            return order == .orderedSame ? left.url.path < right.url.path : order == .orderedDescending
        }.first?.url
    }

    private static func managedPackageRoot(for executable: URL) -> URL? {
        guard executable.lastPathComponent == "codex.js", executable.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard root.lastPathComponent == "codex", root.deletingLastPathComponent().lastPathComponent == "@openai" else { return nil }
        return root
    }

    private static func managedVersion(at root: URL) -> String? {
        struct PackageMetadata: Decodable { let name: String; let version: String }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let metadata = try? JSONDecoder().decode(PackageMetadata.self, from: data), metadata.name == "@openai/codex",
              metadata.version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z"#, options: .regularExpression) != nil else { return nil }
        return metadata.version
    }

    private static func nativeExecutable(in root: URL) -> URL? {
        #if arch(arm64)
        let platformPackage = "codex-darwin-arm64"
        let target = "aarch64-apple-darwin"
        #else
        let platformPackage = "codex-darwin-x64"
        let target = "x86_64-apple-darwin"
        #endif
        let manager = FileManager.default
        struct PackageMetadata: Decodable { let optionalDependencies: [String: String]? }
        let metadata = (try? Data(contentsOf: root.appendingPathComponent("package.json")))
            .flatMap { try? JSONDecoder().decode(PackageMetadata.self, from: $0) }
        var selectedRoot = root
        let usesPlatformPackage = metadata?.optionalDependencies?["@openai/\(platformPackage)"] != nil
        if usesPlatformPackage {
            let optionalRoots = [root.appendingPathComponent("node_modules/@openai/\(platformPackage)"),
                                 root.deletingLastPathComponent().appendingPathComponent(platformPackage)]
            if let installed = optionalRoots.first(where: { manager.fileExists(atPath: $0.appendingPathComponent("package.json").path) }) {
                // A broken platform package cannot fall back to an embedded binary.
                selectedRoot = installed
            }
        }
        let targetRoot = selectedRoot.appendingPathComponent("vendor/\(target)")
        let layoutURL = targetRoot.appendingPathComponent("codex-package.json")
        let entrypoint: String
        if manager.fileExists(atPath: layoutURL.path) {
            struct Layout: Decodable { let layoutVersion: Int; let target: String; let entrypoint: String }
            guard let data = try? Data(contentsOf: layoutURL),
                  let layout = try? JSONDecoder().decode(Layout.self, from: data),
                  layout.layoutVersion == 1, layout.target == target, layout.entrypoint == "bin/codex" else { return nil }
            entrypoint = layout.entrypoint
        } else {
            // Legacy files must not mask a broken modern installation.
            guard !usesPlatformPackage else { return nil }
            entrypoint = "codex/codex"
        }
        let executable = targetRoot.appendingPathComponent(entrypoint)
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: executable.path, isDirectory: &directory), !directory.boolValue,
              manager.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }
}

/// Display names from app-owned logins, bound to account/read identity. Never expose tokens.
enum CodexProfileName {
    static func readFromAppOwnedAccount(directory: URL, matchingEmail: String) -> String? {
        let url = directory.appendingPathComponent("auth.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return fullName(fromAuthData: data, matchingEmail: matchingEmail)
    }

    static func fullName(fromAuthData data: Data, matchingEmail: String) -> String? {
        struct Tokens: Decodable { let id_token: String? }
        struct Auth: Decodable { let tokens: Tokens? }
        struct Profile: Decodable { let email: String?; let name: String? }
        struct Claims: Decodable {
            let email: String?
            let name: String?
            let profile: Profile?
            enum CodingKeys: String, CodingKey { case email, name; case profile = "https://api.openai.com/profile" }
        }
        guard data.count <= 1_048_576,
              let auth = try? JSONDecoder().decode(Auth.self, from: data), let token = auth.tokens?.id_token else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, !segments[0].isEmpty, !segments[2].isEmpty else { return nil }
        let encoded = String(segments[1])
        guard !encoded.isEmpty, encoded.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let payload = Data(base64Encoded: base64),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload) else { return nil }
        let candidateEmail = claims.name != nil ? (claims.email ?? claims.profile?.email) : (claims.profile?.email ?? claims.email)
        guard let claimedEmail = candidateEmail else { return nil }
        let expected = matchingEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let observed = claimedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty, !observed.isEmpty, expected.caseInsensitiveCompare(observed) == .orderedSame,
              let claimedName = claims.name ?? claims.profile?.name else { return nil }
        let name = claimedName.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty, name.count <= 160,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}

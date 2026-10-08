@preconcurrency import Foundation

enum BackgroundServiceConstants {
    static let machServiceName = "com.inndevs.codexusageviewer.helper"
    static let appIdentifier = "com.inndevs.codexusageviewer"

    static var helperSigningRequirement: String { signingRequirement(identifier: machServiceName) }
    static var appSigningRequirement: String { signingRequirement(identifier: appIdentifier) }

    private static func signingRequirement(identifier: String) -> String {
        let prefix = CodexUsageViewerConstants.appGroup.split(separator: ".").first.map(String.init) ?? ""
        let validTeam = prefix.utf8.count == 10 && prefix.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0)
        }
        // An invalid group must never weaken verification or become requirement syntax.
        let team = validTeam ? prefix : "INVALID-TEAM"
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc(CodexUsageViewerBackgroundHelperProtocol)
protocol BackgroundHelperProtocol {
    func execute(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

enum BackgroundCommand: Codable, Equatable, Sendable {
    case state
    case refresh
    case connect(accountID: String)
    case cancelLogin
    case disconnect(accountID: String)
    case setExecutable(path: String)
}

/// Transient app/helper state. Only `snapshot` is suitable for widget persistence.
struct BackgroundState: Codable, Sendable {
    var snapshot: UsageSnapshot
    var isRefreshing: Bool
    var busyAccountIDs: [String]
    var login: PendingLogin?
    var availableCodex: Bool
    var localCodexStatus: String?
    var errorMessage: String?
    var codexPath: String
    var helperVersion: String = CodexUsageViewerVersion.display
}

@MainActor
protocol BackgroundServing: AnyObject {
    func send(_ command: BackgroundCommand) async throws -> BackgroundState
    func shutdown()
}

enum BackgroundIPCError: LocalizedError, Equatable {
    case unavailable
    case interrupted
    case timedOut
    case invalidResponse
    case stopped

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The background helper couldn’t be reached. Check Background Updates in Settings."
        case .interrupted: return "The background helper connection was interrupted. Retrying shortly."
        case .timedOut: return "The background helper didn’t respond in time. Retrying shortly."
        case .invalidResponse: return "The background helper returned an unreadable response. Restart the app to reconnect."
        case .stopped: return "The background helper connection is closed."
        }
    }
}

/// Injectable connection boundary keeps unit tests away from launchd and real accounts.
@MainActor
protocol BackgroundIPCConnection: AnyObject {
    var onFailure: ((Error) -> Void)? { get set }
    func send(_ request: Data, reply: @escaping @MainActor @Sendable (Result<Data, Error>) -> Void)
    func invalidate()
}

@MainActor
private final class BackgroundXPCConnection: BackgroundIPCConnection {
    var onFailure: ((Error) -> Void)?
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: BackgroundServiceConstants.machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundHelperProtocol.self)
        connection.setCodeSigningRequirement(BackgroundServiceConstants.helperSigningRequirement)
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.onFailure?(BackgroundIPCError.interrupted) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.onFailure?(BackgroundIPCError.unavailable) }
        }
        connection.resume()
    }

    func send(_ request: Data, reply: @escaping @MainActor @Sendable (Result<Data, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in reply(.failure(BackgroundIPCError.unavailable)) }
        }) as? BackgroundHelperProtocol else {
            reply(.failure(BackgroundIPCError.unavailable))
            return
        }
        proxy.execute(request) { response in
            Task { @MainActor in reply(.success(response)) }
        }
    }

    func invalidate() {
        onFailure = nil
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
    }

    isolated deinit { connection.invalidate() }
}

@MainActor
final class BackgroundClient: BackgroundServing {
    private struct PendingRequest {
        let continuation: CheckedContinuation<BackgroundState, Error>
        let timeout: Task<Void, Never>
    }

    private let requestTimeout: TimeInterval
    private let makeConnection: () -> any BackgroundIPCConnection
    private var connection: (any BackgroundIPCConnection)?
    private var generation = UUID()
    private var pending: [UUID: PendingRequest] = [:]
    private var stopped = false

    convenience init(requestTimeout: TimeInterval = 120) {
        self.init(requestTimeout: requestTimeout, makeConnection: { BackgroundXPCConnection() })
    }

    init(requestTimeout: TimeInterval = 120,
         makeConnection: @escaping () -> any BackgroundIPCConnection) {
        self.requestTimeout = requestTimeout.isFinite ? max(0.001, min(requestTimeout, 120)) : 120
        self.makeConnection = makeConnection
    }

    func send(_ command: BackgroundCommand) async throws -> BackgroundState {
        guard !stopped else { throw BackgroundIPCError.stopped }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(command)
        let requestID = UUID()
        let timeoutInterval: TimeInterval
        switch command {
        case .cancelLogin, .disconnect: timeoutInterval = requestTimeout
        default: timeoutInterval = min(requestTimeout, 15)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let transport = currentConnection()
                let requestGeneration = generation
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeoutInterval)) }
                    catch { return }
                    self?.requestTimedOut(requestID, generation: requestGeneration)
                }
                pending[requestID] = PendingRequest(continuation: continuation, timeout: timeout)
                transport.send(data) { [weak self] result in
                    self?.receive(result, requestID: requestID, generation: requestGeneration)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(requestID, result: .failure(CancellationError()))
            }
        }
    }

    /// Closes this app's IPC connection; the launch agent continues polling independently.
    func shutdown() {
        stopped = true
        disconnect(with: BackgroundIPCError.stopped)
    }

    private func currentConnection() -> any BackgroundIPCConnection {
        if let connection { return connection }
        let newConnection = makeConnection()
        let connectionGeneration = UUID()
        generation = connectionGeneration
        newConnection.onFailure = { [weak self] error in
            guard let self, self.generation == connectionGeneration else { return }
            self.disconnect(with: error as? BackgroundIPCError ?? BackgroundIPCError.interrupted)
        }
        connection = newConnection
        return newConnection
    }

    private func receive(_ result: Result<Data, Error>, requestID: UUID, generation: UUID) {
        guard self.generation == generation, pending[requestID] != nil else { return }
        switch result {
        case .success(let data):
            guard data.count <= 1_048_576,
                  let state = try? JSONDecoder().decode(BackgroundState.self, from: data) else {
                finish(requestID, result: .failure(BackgroundIPCError.invalidResponse))
                return
            }
            finish(requestID, result: .success(state))
        case .failure:
            disconnect(with: BackgroundIPCError.unavailable)
        }
    }

    private func requestTimedOut(_ requestID: UUID, generation: UUID) {
        guard self.generation == generation, pending[requestID] != nil else { return }
        // A hung peer must not keep later requests on the same connection.
        disconnect(with: BackgroundIPCError.timedOut)
    }

    private func finish(_ requestID: UUID, result: Result<BackgroundState, Error>) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func disconnect(with error: Error) {
        let oldConnection = connection
        connection = nil
        generation = UUID()
        oldConnection?.onFailure = nil
        oldConnection?.invalidate()
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

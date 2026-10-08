import AppKit
import Foundation
import Darwin

@MainActor
final class BackgroundHelperService: NSObject, BackgroundHelperProtocol {
    let store: CodexUsageViewerStore
    private var refreshTask: Task<Void, Never>?

    init(store: CodexUsageViewerStore) { self.store = store }

    nonisolated func execute(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor in
            guard request.count <= 65_536, let command = try? JSONDecoder().decode(BackgroundCommand.self, from: request) else {
                var state = store.backgroundState
                state.errorMessage = "The app sent an unreadable background request. Reopen the app."
                reply((try? JSONEncoder().encode(state)) ?? Data())
                return
            }
            switch command {
            case .state: break
            case .refresh: requestRefresh()
            case .connect(let accountID): await store.connect(accountID)
            case .cancelLogin: await store.cancelLogin()
            case .disconnect(let accountID): await store.disconnect(accountID)
            case .setExecutable(let path):
                guard path.utf8.count <= 4_096 else { reply(Data()); return }
                store.codexPath = path
                requestRefresh()
            }
            reply((try? JSONEncoder().encode(store.backgroundState)) ?? Data())
        }
    }

    func requestRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while store.isRefreshing {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { refreshTask = nil; return }
            }
            await store.refresh()
            refreshTask = nil
        }
    }

    func shutdown() {
        refreshTask?.cancel()
        store.shutdown()
    }
}

private final class HelperListener: NSObject, NSXPCListenerDelegate {
    private let service: BackgroundHelperService
    init(service: BackgroundHelperService) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(BackgroundServiceConstants.appSigningRequirement)
        connection.exportedInterface = NSXPCInterface(with: BackgroundHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

@main
enum CodexUsageViewerHelperMain {
    @MainActor static func main() {
        CodexConnection.runWorkerIfRequested()
        // launchd may pass a bundle-relative argv[0] while the working directory
        // is /. Ask the kernel for the running image instead of resolving argv.
        var executablePath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &executablePath, UInt32(executablePath.count)) > 0 else { exit(EXIT_FAILURE) }
        let helperURL = URL(fileURLWithPath: String(cString: executablePath))
        CodexConnection.workerLauncherURL = helperURL
        let widgetReloader = WidgetReloadProcess(executable: helperURL.deletingLastPathComponent().appendingPathComponent("Codex Usage Viewer"))
        var dependencies = CodexUsageViewerStoreDependencies.live
        dependencies.reloadWidgets = { widgetReloader.reload() }
        let preferences = UserDefaults(suiteName: BackgroundServiceConstants.appIdentifier)!
        let store = CodexUsageViewerStore(dependencies: dependencies, preferences: preferences, startsPolling: true, managesChromeProfiles: false)
        let service = BackgroundHelperService(store: store)
        let delegate = HelperListener(service: service)
        let listener = NSXPCListener(machServiceName: BackgroundServiceConstants.machServiceName)
        listener.delegate = delegate
        listener.resume()

        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in service.requestRefresh() }
        }
        // launchd sends SIGTERM on unregister/update; stop all app-owned workers first.
        let signals = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { service.shutdown(); widgetReloader.shutdown() }
                listener.invalidate()
                exit(EXIT_SUCCESS)
            }
            source.resume()
            return source
        }
        withExtendedLifetime((delegate, service, wake, signals, widgetReloader)) { RunLoop.main.run() }
    }
}

/// WidgetKit resolves the containing app from the caller's executable identity.
/// A brief UI-free invocation of that executable requests the widget reload.
@MainActor
private final class WidgetReloadProcess {
    private let executable: URL
    private var process: Process?
    private var pending = false
    private var timeout: Task<Void, Never>?

    init(executable: URL) { self.executable = executable }

    func reload() {
        if process != nil { pending = true; return }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--reload-widgets"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.timeout?.cancel()
                self.process = nil
                if self.pending { self.pending = false; self.reload() }
            }
        }
        process = child
        do {
            try child.run()
            timeout = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if child.isRunning { child.terminate() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        catch { process = nil }
    }

    func shutdown() {
        pending = false
        timeout?.cancel()
        if process?.isRunning == true { process?.terminate() }
    }
}

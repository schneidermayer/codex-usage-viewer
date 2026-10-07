import AppKit
import SwiftUI

@main
struct CodexUsageViewerApp: App {
    @NSApplicationDelegateAdaptor(CodexUsageViewerAppDelegate.self) private var appDelegate
    @StateObject private var store = CodexUsageViewerStore()

    var body: some Scene {
        Window("Codex Usage Viewer", id: "dashboard") {
            DashboardHost(store: store)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1040, height: 670)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Codex Usage Viewer \(CodexUsageViewerVersion.display)") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Codex Usage Viewer") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: CodexUsageViewerVersion.display])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Usage") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store.isRefreshing || store.isDemo)
            }
        }

        Settings {
            CodexUsageViewerSettingsView(store: store)
        }
    }
}

private struct DashboardHost: View {
    @ObservedObject var store: CodexUsageViewerStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        DashboardView(store: store)
            .frame(minWidth: 900, minHeight: 620)
            .onAppear { store.openDashboardAction = { openWindow(id: "dashboard") } }
            .onOpenURL { _ in store.openDashboard() }
    }
}

@MainActor
final class CodexUsageViewerAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: CodexUsageViewerStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--dark-appearance") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
}

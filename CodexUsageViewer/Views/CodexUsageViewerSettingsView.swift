import AppKit
import SwiftUI

struct CodexUsageViewerSettingsView: View {
    @ObservedObject var store: CodexUsageViewerStore
    @Environment(\.dismiss) private var dismiss
    @State private var executablePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 11) {
                CodexUsageViewerMark(size: 37)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.65)
                    Text("Codex Usage Viewer · Version \(CodexUsageViewerVersion.display)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Codex connection").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Label(store.availableCodex ? "Ready" : "Setup needed", systemImage: store.availableCodex ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(store.availableCodex ? CodexUsageViewerPalette.mint : .orange)
                }
                Text("Codex Usage Viewer uses the Codex command-line app installed on this Mac to securely sign in and read usage.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Automatic detection", text: $executablePath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Codex executable path")
                        .accessibilityIdentifier("codexusageviewer.settings.executable")
                        .onSubmit { store.codexPath = executablePath }
                    Button("Choose…", action: chooseExecutable)
                }
                HStack {
                    Button("Use automatic detection") {
                        executablePath = ""
                        store.codexPath = ""
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    Spacer()
                    if executablePath != store.codexPath {
                        Button("Apply") { store.codexPath = executablePath }
                            .buttonStyle(.glass)
                    }
                }
            }
            .padding(18)
            .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 15) {
                detail(symbol: "arrow.clockwise", title: "Automatic refresh", text: "Codex Usage Viewer checks connected accounts every three minutes while it’s running. macOS chooses when widgets refresh.")
                detail(symbol: "lock.shield", title: "Private account connections", text: "Each account has its own connection on this Mac. Your widget receives usage snapshots; it never receives sign-in credentials.")
                detail(symbol: "clock", title: "Last reported usage", text: "Usage shows the last successful update. A reset countdown never assumes that a limit has recovered.")
            }

            HStack {
                Text("Version \(CodexUsageViewerVersion.display)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") {
                    if executablePath != store.codexPath { store.codexPath = executablePath }
                    dismiss()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("codexusageviewer.settings.done")
            }
        }
        .padding(28)
        .frame(width: 500)
        .onAppear { executablePath = store.codexPath }
        .onExitCommand { dismiss() }
    }

    private func detail(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex executable"
        panel.message = "Select the codex command-line executable installed on this Mac."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
            store.codexPath = url.path
        }
    }
}

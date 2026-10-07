import AppKit
import SwiftUI

struct ConnectionSheet: View {
    @ObservedObject var store: CodexUsageViewerStore
    @State private var copied = false

    private var accent: Color {
        CodexUsageViewerPalette.accent(for: CodexUsageViewerPalette.index(for: store.login?.id ?? "account-1"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                CodexUsageViewerMark(size: 41)
                Spacer()
                Button { Task { await store.cancelLogin() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 19, height: 22)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Cancel sign-in")
                .accessibilityIdentifier("codexusageviewer.connection.close")
            }

            VStack(alignment: .leading, spacing: 9) {
                CodexUsageViewerEyebrow(text: "A NEW CONNECTION")
                Text("Bring \(store.login?.accountName ?? "your account") into view.")
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text(store.chromeProfiles.isEmpty
                     ? "Use the browser profile that’s signed in to this Codex account."
                     : "Choose the Chrome profile that’s signed in to this Codex account.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 19) {
                if store.chromeProfiles.isEmpty {
                    step("1", title: "Copy your sign-in link", detail: "Each account gets its own connection.")
                    step("2", title: "Open the matching browser profile", detail: "Paste the link into a new tab in that profile.")
                } else {
                    step("1", title: "Choose the matching Chrome profile", detail: "Keep each of your three logins in its own profile.")
                    step("2", title: "Open your secure sign-in", detail: "We’ll open a tab in the profile you choose below.")
                }
                step("3", title: "Sign in, then return here", detail: "Check the account email shown after connecting.")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))

            if !store.chromeProfiles.isEmpty {
                Picker("Chrome profile", selection: Binding(
                    get: { store.selectedChromeProfileID },
                    set: { store.selectedChromeProfileID = $0 }
                )) {
                    Text("Choose a profile…").tag("")
                    ForEach(store.chromeProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.large)
                .accessibilityIdentifier("codexusageviewer.connection.chromeProfile")
            }

            if let error = store.login?.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(store.login?.authURL == nil ? "Getting your sign-in link ready…" : "Waiting for you to finish signing in…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 18)
                .accessibilityElement(children: .combine)
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 10) {
                    Button("Cancel") { Task { await store.cancelLogin() } }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("codexusageviewer.connection.cancel")
                    Spacer()
                    Button {
                        guard let url = store.login?.authURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Link copied" : "Copy sign-in link", systemImage: copied ? "checkmark" : "link")
                    }
                    .buttonStyle(.glass)
                    .disabled(store.login?.authURL == nil)
                    .accessibilityIdentifier("codexusageviewer.connection.copy")
                    if store.chromeProfiles.isEmpty {
                        Button {
                            guard let url = store.login?.authURL else { return }
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open browser", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(accent)
                        .disabled(store.login?.authURL == nil)
                        .help("Opens your default browser. For another profile, copy the sign-in link instead.")
                        .accessibilityIdentifier("codexusageviewer.connection.open")
                    } else {
                        Button { store.openSignInInChrome() } label: {
                            Label("Open in Chrome", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(accent)
                        .disabled(store.login?.authURL == nil || store.selectedChromeProfileID.isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("codexusageviewer.connection.chrome")
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 490)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(store.login?.isWaiting == true)
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .frame(width: 25, height: 25)
                .background(accent.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: CodexUsageViewerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 8) {
                CodexUsageViewerMark(size: 26)
                Text("Codex Usage Viewer").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.glass)
                .disabled(store.isDemo || store.isRefreshing || !store.accounts.contains(where: \.isConnected))
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")
            }
            if store.isDemo {
                Label("Preview · sample usage", systemImage: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexUsageViewerPalette.lilac)
            } else {
                CodexUsageViewerEyebrow(text: "A LITTLE ROOM TO CREATE")
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 10) {
                    ForEach(store.accounts) { account in
                        menuAccount(account, now: context.date)
                    }
                }
            }
            if !store.isDemo && !store.accounts.contains(where: { store.isLocalAccount($0) }) {
                Label(store.localCodexStatus ?? "Checking local Codex…", systemImage: "desktopcomputer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                store.openDashboard()
            } label: {
                HStack {
                    Text("Open Codex Usage Viewer")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 350)
    }

    private func menuAccount(_ account: AccountSnapshot, now: Date) -> some View {
        let accent = CodexUsageViewerPalette.accent(for: CodexUsageViewerPalette.index(for: account.id))
        let hasElapsed = [account.primaryBucket?.primary, account.primaryBucket?.secondary].compactMap { $0 }.contains { $0.hasElapsed(at: now) }
        let isHistorical = account.issue != nil || account.isStale(at: now) || hasElapsed
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(account.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if store.isLocalAccount(account) {
                    LocalCodexBadge()
                        .accessibilityLabel("Logged In to local Codex")
                        .accessibilityIdentifier("codexusageviewer.menu.loggedIn.\(account.id)")
                }
                Spacer()
                if account.isConnected, let window = account.primaryBucket?.primary ?? account.primaryBucket?.secondary {
                    Text("\(window.remainingPercent)% \(isHistorical ? "reported" : "left")")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                } else {
                    Text(account.state == .needsSignIn ? "Sign in again" : "Not connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if account.isConnected, let bucket = account.primaryBucket {
                ForEach(Array([bucket.primary, bucket.secondary].compactMap { $0 }.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 9) {
                        Text(window.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 43, alignment: .leading)
                        CodexUsageViewerQuotaTrack(remaining: window.remainingPercent, accent: accent, height: 4)
                        Text("\(window.remainingPercent)%")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 29, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(window.label), \(window.remainingPercent) percent remaining, last reported")
                }
                Text(isHistorical ? "Refresh needed · last reported usage" : CodexUsageViewerFormatting.updated(account.updatedAt, now: now))
                    .font(.system(size: 9))
                    .foregroundStyle(isHistorical ? Color.orange : Color.secondary)
            } else {
                Button("Connect in app") { store.openDashboard() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(13)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
    }
}

import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: CodexUsageViewerStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var renaming: AccountSnapshot?
    @State private var disconnecting: AccountSnapshot?
    @State private var inspectingLimits: AccountSnapshot?
    @State private var showsSettings = false

    private var connectedCount: Int { store.accounts.filter(\.isConnected).count }

    var body: some View {
        ZStack {
            backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    header
                    if store.isDemo { previewBanner }
                    if let error = store.errorMessage {
                        notice(error, symbol: "exclamationmark.circle", color: .orange)
                    }
                    accountSection
                    footer
                }
                .padding(.horizontal, 36)
                .padding(.top, 27)
                .padding(.bottom, 25)
                .frame(maxWidth: 1_180)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 610)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(item: Binding(
            get: { store.login },
            set: { value in if value == nil { Task { await store.cancelLogin() } } }
        ), onDismiss: { Task { await store.cancelLogin() } }) { _ in
            ConnectionSheet(store: store)
        }
        .sheet(item: $renaming) { account in
            RenameAccountSheet(account: account) { name in store.rename(account.id, to: name) }
        }
        .sheet(item: $inspectingLimits) { account in
            AccountLimitsSheet(account: account, isDemo: store.isDemo)
        }
        .sheet(isPresented: $showsSettings) { CodexUsageViewerSettingsView(store: store) }
        .confirmationDialog(
            "Disconnect \(disconnecting?.name ?? "account")?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect account", role: .destructive) {
                guard let account = disconnecting else { return }
                Task { await store.disconnect(account.id) }
                disconnecting = nil
            }
        } message: {
            Text("This removes this account’s connection from Codex Usage Viewer. You can sign in again at any time.")
        }
    }

    private var backdrop: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [CodexUsageViewerPalette.mint.opacity(colorScheme == .dark ? 0.065 : 0.055), .clear, CodexUsageViewerPalette.lilac.opacity(0.035)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .center) {
                HStack(spacing: 9) {
                    CodexUsageViewerMark(size: 30)
                    Text("Codex Usage Viewer")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .tracking(-0.5)
                }
                Spacer()
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { store.setDemo(!store.isDemo) }
                        } label: {
                            Label(store.isDemo ? "Exit preview" : "Preview", systemImage: store.isDemo ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("codexusageviewer.preview")
                        .help("Explore Codex Usage Viewer with clearly labeled sample accounts")

                        Button { showsSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: 17)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Codex Usage Viewer settings")
                        .accessibilityIdentifier("codexusageviewer.settings")
                        .help("Settings")
                    }
                    .controlSize(.large)
                }
            }
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    CodexUsageViewerEyebrow(text: "CODEX USAGE, IN ONE PLACE")
                    Text("A little more headspace.")
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-1.15)
                    Text("Three accounts. A clear view of what’s left.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await store.refresh() }
                } label: {
                    HStack(spacing: 7) {
                        if store.isRefreshing {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(store.isRefreshing ? "Refreshing…" : "Refresh")
                    }
                    .frame(minWidth: 84)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("codexusageviewer.refresh")
                .controlSize(.large)
                .disabled(store.isRefreshing || store.isDemo || connectedCount == 0)
                .keyboardShortcut("r", modifiers: .command)
                .padding(.bottom, 3)
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CodexUsageViewerEyebrow(text: "YOUR ACCOUNTS")
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(connectedCount > 0 ? CodexUsageViewerPalette.mint : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(store.isDemo ? "Sample accounts" : "\(connectedCount) of 3 connected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(store.accounts) { account in
                    AccountCard(
                        account: account,
                        isDemo: store.isDemo,
                        isLocalAccount: { store.isLocalAccount(account) },
                        connect: { Task { await store.connect(account.id) } },
                        showLimits: { inspectingLimits = account },
                        rename: { renaming = account },
                        disconnect: { disconnecting = account }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var previewBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(CodexUsageViewerPalette.lilac)
            Text("Preview mode")
                .fontWeight(.semibold)
            Text("These are sample accounts and usage figures.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(CodexUsageViewerPalette.lilac.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview mode. These are sample accounts and usage figures.")
        .accessibilityIdentifier("codexusageviewer.preview.banner")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 24) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: connectedCount == 0 ? "person.crop.rectangle.stack" : "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(connectedCount == 0 ? "A home for all three logins." : "Keep Codex Usage Viewer on your desktop.")
                        .font(.system(size: 12, weight: .medium))
                    Text(connectedCount == 0
                         ? "Connect each account using its matching browser profile."
                         : "Control-click your desktop → Edit Widgets → Codex Usage Viewer.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text("Private by design")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .help("Codex Usage Viewer stores your account connections on this Mac. Widgets receive only the usage information they need.")
        }
        if !store.isDemo && !store.accounts.contains(where: { store.isLocalAccount($0) }) {
            Label(store.localCodexStatus ?? "Checking the account signed in to local Codex…", systemImage: "desktopcomputer")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("codexusageviewer.localStatus")
        }
        }
        .padding(.top, 1)
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(12)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AccountCard: View {
    var account: AccountSnapshot
    var isDemo: Bool
    var isLocalAccount: () -> Bool
    var connect: () -> Void
    var showLimits: () -> Void
    var rename: () -> Void
    var disconnect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var index: Int { CodexUsageViewerPalette.index(for: account.id) }
    private var accent: Color { CodexUsageViewerPalette.accent(for: index) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                if account.isConnected {
                    connectedContent(now: timeline.date)
                } else {
                    disconnectedContent
                }
            }
            .padding(20)
            .frame(height: 353, alignment: .top)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.62 : 0.84))
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [accent.opacity(colorScheme == .dark ? 0.08 : 0.045), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(.primary.opacity(colorScheme == .dark ? 0.075 : 0.055), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.025), radius: 15, x: 0, y: 5)
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(account.email ?? (account.state == .needsSignIn ? "Sign in again" : "Your next connection"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.email ?? "")
            }
            Spacer(minLength: 0)
            Menu {
                if account.isConnected {
                    Button("All usage limits", systemImage: "chart.bar.xaxis", action: showLimits)
                        .accessibilityIdentifier("codexusageviewer.limits.\(account.id)")
                    Divider()
                }
                Button("Rename account", systemImage: "pencil", action: rename)
                    .disabled(isDemo)
                    .accessibilityIdentifier("codexusageviewer.rename.\(account.id)")
                if account.state != .disconnected {
                    Button("Reconnect", systemImage: "arrow.trianglehead.2.clockwise", action: connect)
                        .disabled(isDemo)
                    Divider()
                    Button("Disconnect…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: disconnect)
                        .disabled(isDemo)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(account.name)")
            .accessibilityIdentifier("codexusageviewer.options.\(account.id)")
        }
    }

    private func connectedContent(now: Date) -> some View {
        VStack(spacing: 0) {
            if let bucket = account.primaryBucket, let primary = bucket.primary ?? bucket.secondary {
                ZStack {
                    CodexUsageViewerQuotaRing(remaining: primary.remainingPercent, accent: accent, lineWidth: 7)
                        .frame(width: 130, height: 130)
                    VStack(spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(primary.remainingPercent)")
                                .font(.system(size: 39, weight: .medium, design: .rounded))
                                .tracking(-1.5)
                            Text("%")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Text(isHistorical(primary, now: now) ? "last reported" : "remaining")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 21)
                .padding(.bottom, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(account.name), \(primary.label), \(primary.remainingPercent) percent remaining, last reported")
                .accessibilityIdentifier("codexusageviewer.usage.\(account.id)")

                HStack {
                    Text(primary.label)
                        .fontWeight(.medium)
                    Spacer()
                    Text(CodexUsageViewerFormatting.reset(primary, now: now))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.system(size: 10))
                .padding(.bottom, 15)

                if let secondary = bucket.secondary, bucket.primary != nil {
                    VStack(spacing: 7) {
                        HStack {
                            Text(secondary.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(secondary.remainingPercent)% \(isHistorical(secondary, now: now) ? "reported" : "left")")
                                .fontWeight(.medium)
                        }
                        .font(.system(size: 11))
                        CodexUsageViewerQuotaTrack(remaining: secondary.remainingPercent, accent: accent)
                        HStack {
                            Spacer()
                            Text(CodexUsageViewerFormatting.reset(secondary, now: now))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("One usage window reported")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 29, weight: .ultraLight))
                        .foregroundStyle(accent)
                    Text("Waiting for a clear picture.")
                        .font(.system(size: 13, weight: .medium))
                    Text("This account hasn’t reported its usage limits yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 233)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                if account.issue != nil || account.isStale(at: now) || hasElapsedWindow(now: now) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                } else {
                    Circle().fill(accent.opacity(0.8)).frame(width: 4, height: 4)
                }
                Text(isDemo ? "Sample data" : status(now: now))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isLocalAccount() {
                    LocalCodexBadge()
                        .accessibilityIdentifier("codexusageviewer.loggedIn.\(account.id)")
                } else if let plan = account.plan {
                    Text(plan.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.035), in: Capsule())
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .help(account.issue ?? "Usage is the last value reported by this account. Reset times don’t confirm recovered usage until the next successful refresh.")
        }
    }

    private var disconnectedContent: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .strokeBorder(accent.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
                    .frame(width: 116, height: 116)
                Circle()
                    .fill(accent.opacity(0.055))
                    .frame(width: 87, height: 87)
                Image(systemName: account.state == .needsSignIn ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.plus")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(accent)
            }
            .padding(.top, 26)
            Text(account.state == .needsSignIn ? "Let’s reconnect." : "Make room for this account.")
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 16)
            Text(account.state == .needsSignIn ? "Sign in to see current usage again." : "Your Codex limits, a glance away.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            Spacer()
            Button(action: connect) {
                Label(account.state == .needsSignIn ? "Sign in again" : "Connect account", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(isDemo)
            .accessibilityLabel("Connect \(account.name)")
            .accessibilityIdentifier("codexusageviewer.connect.\(account.id)")
            Text("Use browser profile \(index + 1)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private func status(now: Date) -> String {
        if account.issue != nil { return "Update unavailable · last known usage" }
        if account.isStale(at: now) { return "Out of date · \(CodexUsageViewerFormatting.updated(account.updatedAt, now: now).lowercased())" }
        if hasElapsedWindow(now: now) { return "Reset passed · last reported usage" }
        return CodexUsageViewerFormatting.updated(account.updatedAt, now: now)
    }

    private func isHistorical(_ window: QuotaWindow, now: Date) -> Bool {
        account.issue != nil || account.isStale(at: now) || window.hasElapsed(at: now)
    }

    private func hasElapsedWindow(now: Date) -> Bool {
        guard let bucket = account.primaryBucket else { return false }
        return [bucket.primary, bucket.secondary].compactMap { $0 }.contains { $0.hasElapsed(at: now) }
    }
}

struct LocalCodexBadge: View {
    var body: some View {
        Label("Logged In", systemImage: "desktopcomputer")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            .help("Currently signed in to local Codex")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Logged In")
            .accessibilityHint("Currently signed in to local Codex")
    }
}

private struct AccountLimitsSheet: View {
    let account: AccountSnapshot
    let isDemo: Bool
    @Environment(\.dismiss) private var dismiss

    private var accent: Color {
        CodexUsageViewerPalette.accent(for: CodexUsageViewerPalette.index(for: account.id))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(accent)
                        .frame(width: 43, height: 43)
                        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("All usage limits")
                            .font(.system(size: 24, weight: .semibold))
                            .tracking(-0.65)
                            .accessibilityIdentifier("codexusageviewer.limits.title")
                        Text(account.name)
                            .font(.system(size: 13, weight: .medium))
                        if let email = account.email {
                            Text(email)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if isDemo {
                    Label("Sample usage · preview mode", systemImage: "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexUsageViewerPalette.lilac)
                }

                if let warning = historicalWarning(now: context.date) {
                    Label(warning, systemImage: "clock.badge.exclamationmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if account.buckets.isEmpty {
                            Text("This account hasn’t reported any usage limits yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 16)
                        }
                        ForEach(account.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 15) {
                                Text(bucket.title)
                                    .font(.system(size: 14, weight: .semibold))
                                if let primary = bucket.primary {
                                    limitWindow(primary, id: "\(bucket.id).primary", now: context.date)
                                }
                                if let secondary = bucket.secondary {
                                    limitWindow(secondary, id: "\(bucket.id).secondary", now: context.date)
                                }
                                if bucket.primary == nil && bucket.secondary == nil {
                                    Text("No usage windows reported")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(17)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
                .frame(maxHeight: 330)

                HStack {
                    Text(isDemo ? "Sample data" : CodexUsageViewerFormatting.updated(account.updatedAt, now: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("codexusageviewer.limits.done")
                }
            }
            .padding(28)
        }
        .frame(width: 500, height: 560)
        .onExitCommand { dismiss() }
    }

    private func limitWindow(_ window: QuotaWindow, id: String, now: Date) -> some View {
        let historical = account.isStale(at: now) || account.issue != nil || window.hasElapsed(at: now)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(window.remainingPercent)% \(historical ? "last reported" : "remaining")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            CodexUsageViewerQuotaTrack(remaining: window.remainingPercent, accent: accent)
            Text(CodexUsageViewerFormatting.reset(window, now: now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(window.remainingPercent)% \(historical ? "last reported" : "remaining"). \(CodexUsageViewerFormatting.reset(window, now: now))")
        .accessibilityIdentifier("codexusageviewer.limit.\(id)")
    }

    private func historicalWarning(now: Date) -> String? {
        if account.issue != nil || account.isStale(at: now) {
            return "This is the last reported usage. Refresh the account for a current view."
        }
        let elapsed = account.buckets.flatMap { [$0.primary, $0.secondary].compactMap { $0 } }
            .contains { $0.hasElapsed(at: now) }
        return elapsed ? "A reset time has passed. Its usage stays historical until the next successful refresh." : nil
    }
}

private struct RenameAccountSheet: View {
    var account: AccountSnapshot
    var save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A name that feels familiar.")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.6)
            Text("Give this account a name that’s easy to spot in Codex Usage Viewer and your widgets.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Account name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityIdentifier("codexusageviewer.rename.name")
                .onSubmit(saveAndDismiss)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("codexusageviewer.rename.cancel")
                Button("Save", action: saveAndDismiss)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("codexusageviewer.rename.save")
            }
        }
        .padding(28)
        .frame(width: 390)
        .onAppear { name = account.name; nameFocused = true }
    }

    private func saveAndDismiss() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(String(value.prefix(40)))
        dismiss()
    }
}

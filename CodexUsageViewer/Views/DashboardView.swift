import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: CodexUsageViewerStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var disconnecting: AccountSnapshot?
    @State private var inspectingLimits: AccountSnapshot?
    @State private var showsSettings = false

    private var connectedCount: Int { store.accounts.filter(\.isConnected).count }

    var body: some View {
        ZStack {
            backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if store.isDemo { previewBanner }
                    if let error = store.errorMessage {
                        notice(error, symbol: "exclamationmark.circle", color: .orange)
                    }
                    accountSection
                    footer
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 24)
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
        .sheet(item: $inspectingLimits) { account in
            AccountLimitsSheet(account: account, isDemo: store.isDemo)
        }
        .sheet(isPresented: $showsSettings) { CodexUsageViewerSettingsView(store: store) }
        .confirmationDialog(
            "Disconnect \(disconnecting?.displayName ?? "account")?",
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
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 12) {
                CodexUsageViewerMark(size: 39)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codex Usage Viewer")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .tracking(-0.6)
                        .accessibilityIdentifier("codexusageviewer.title")
                    HStack(spacing: 8) {
                        Text("Version \(CodexUsageViewerVersion.display)")
                            .accessibilityIdentifier("codexusageviewer.version")
                        Circle().fill(.tertiary).frame(width: 2, height: 2)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(connectedCount > 0 ? CodexUsageViewerPalette.mint : Color.secondary.opacity(0.5))
                                .frame(width: 4, height: 4)
                            Text(store.isDemo ? "Sample accounts" : "\(connectedCount) of 3 connected")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 9) {
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
                        .frame(minWidth: 82)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("codexusageviewer.refresh")
                    .disabled(store.isRefreshing || store.isDemo || connectedCount == 0)
                    .keyboardShortcut("r", modifiers: .command)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { store.setDemo(!store.isDemo) }
                    } label: {
                        Label(store.isDemo ? "Exit preview" : "Preview", systemImage: store.isDemo ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("codexusageviewer.preview")
                    .help("Explore the interface with clearly labeled sample accounts")

                    Button { showsSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 17)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Codex Usage Viewer settings")
                    .accessibilityIdentifier("codexusageviewer.settings")
                    .help("Settings")
                }
                .controlSize(.large)
            }
        }
    }

    private var accountSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(store.accounts) { account in
                AccountCard(
                    account: account,
                    isDemo: store.isDemo,
                    isLocalAccount: { store.isLocalAccount(account) },
                    connect: { Task { await store.connect(account.id) } },
                    showLimits: { inspectingLimits = account },
                    disconnect: { disconnecting = account }
                )
                .frame(maxWidth: .infinity)
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
            HStack(alignment: .top, spacing: 18) {
                Label(connectedCount == 0
                      ? "Connect each account using its matching Chrome profile."
                      : "Add a widget: control-click your desktop → Edit Widgets → Codex Usage Viewer.",
                      systemImage: connectedCount == 0 ? "person.crop.rectangle.stack" : "rectangle.on.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Label("Stored on this Mac", systemImage: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .help("Each account connection stays on this Mac. Widgets receive usage snapshots, never credentials.")
            }
            if !store.isDemo && !store.accounts.contains(where: { store.isLocalAccount($0) }) {
                Label(store.localCodexStatus ?? "Checking the account signed in to local Codex…", systemImage: "desktopcomputer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codexusageviewer.localStatus")
            }
        }
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
    var disconnect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var index: Int { CodexUsageViewerPalette.index(for: account.id) }
    private var accent: Color { CodexUsageViewerPalette.accent(for: index) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                accountBadges
                    .padding(.top, 12)
                if account.isConnected {
                    connectedContent(now: timeline.date)
                } else {
                    disconnectedContent
                }
            }
            .padding(20)
            .frame(height: 405, alignment: .top)
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
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(account.displayName)
                    .accessibilityIdentifier("codexusageviewer.name.\(account.id)")
                if let email = account.email, email != account.displayName {
                    Text(email)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(email)
                } else if !account.isConnected {
                    Text(account.state == .needsSignIn ? "Sign in again" : "Not connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if account.state != .disconnected {
                Menu {
                    if account.isConnected {
                        Button("All usage limits", systemImage: "chart.bar.xaxis", action: showLimits)
                            .accessibilityIdentifier("codexusageviewer.limits.\(account.id)")
                        Divider()
                    }
                    Button("Reconnect", systemImage: "arrow.trianglehead.2.clockwise", action: connect)
                        .disabled(isDemo)
                    Button("Disconnect…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: disconnect)
                        .disabled(isDemo)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 17, height: 23)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for \(account.displayName)")
                .accessibilityIdentifier("codexusageviewer.options.\(account.id)")
            }
        }
        .frame(height: 60, alignment: .top)
    }

    private var accountBadges: some View {
        HStack(spacing: 7) {
            if account.isConnected, let plan = account.plan {
                Text(plan.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.09), in: Capsule())
                    .accessibilityLabel("Subscription plan: \(plan.capitalized)")
                    .accessibilityIdentifier("codexusageviewer.plan.\(account.id)")
            }
            if isLocalAccount() {
                LocalCodexBadge()
                    .accessibilityIdentifier("codexusageviewer.loggedIn.\(account.id)")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 23, alignment: .leading)
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
                .accessibilityLabel("\(account.displayName), \(primary.label), \(primary.remainingPercent) percent remaining, last reported")
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
                    Text("Usage not reported")
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
            Text(account.state == .needsSignIn ? "Reconnect this account" : "Connect a Codex account")
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 16)
            Text(account.state == .needsSignIn ? "Sign in to see current usage again." : "Choose the matching Chrome profile.")
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
            .accessibilityLabel("Connect \(account.displayName)")
            .accessibilityIdentifier("codexusageviewer.connect.\(account.id)")
            Text("Account slot \(index + 1) of 3")
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
                        Text(account.displayName)
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

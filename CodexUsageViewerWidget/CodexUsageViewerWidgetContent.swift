import SwiftUI
import WidgetKit

/// Sanitized snapshot presentation, shared by the extension and visual harness.
struct CodexUsageViewerWidgetContent: View {
    let snapshot: UsageSnapshot
    var family: WidgetFamily?
    var referenceDate: Date = .now

    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var effectiveFamily: WidgetFamily { family ?? environmentFamily }
    private var accounts: [AccountSnapshot] {
        CodexUsageViewerConstants.accountIDs.enumerated().map { index, id in
            snapshot.accounts.first(where: { $0.id == id })
                ?? AccountSnapshot(id: id, name: "Account \(index + 1)")
        }
    }
    private var isSmall: Bool { effectiveFamily == .systemSmall }
    private var isLarge: Bool { effectiveFamily == .systemLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 14 : 9) {
            header
            if isLarge {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().opacity(0.5) }
                    Link(destination: accountURL(account)) {
                        largeAccount(account, index: index)
                    }
                    .buttonStyle(.plain)
                    .frame(maxHeight: .infinity)
                }
            } else {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if isSmall {
                        compactAccount(account, index: index)
                    } else {
                        Link(destination: accountURL(account)) {
                            compactAccount(account, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .fontDesign(.rounded)
    }

    private var header: some View {
        HStack(spacing: 5) {
            CodexUsageViewerMark(size: isSmall ? 16 : 19)
                .widgetAccentable()
            Text(isSmall ? "Weekly" : "Weekly usage")
                .font(.system(size: isSmall ? 12 : 14, weight: .semibold))
            Spacer(minLength: 0)
            if !isSmall {
                Text("CODEX")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Codex weekly usage and time until reset")
    }

    private func compactAccount(_ account: AccountSnapshot, index: Int) -> some View {
        let state = account.weeklyUsage(at: referenceDate)
        let reset = state.window.flatMap { WeeklyResetProgress(window: $0, at: referenceDate) }
        return VStack(alignment: .leading, spacing: isSmall ? 4 : 5) {
            HStack(spacing: isSmall ? 4 : 6) {
                accountDot(index, size: isSmall ? 4 : 5)
                Text(account.displayName)
                    .font(.system(size: isSmall ? 10 : 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !isSmall, snapshot.isLocalAccount(account, at: referenceDate) {
                    loggedInBadge
                }
                Spacer(minLength: 2)
                if let window = state.window {
                    Text("\(window.remainingPercent)% left")
                        .font(.system(size: isSmall ? 10 : 12, weight: .semibold))
                        .monospacedDigit()
                        .fixedSize()
                } else {
                    Text("—")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let window = state.window {
                HStack(spacing: isSmall ? 6 : 9) {
                    if !isSmall {
                        Text("Reset in")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    resetTrack(reset, color: accent(index), height: isSmall ? 3 : 4)
                    HStack(spacing: 2) {
                        if isSmall {
                            Image(systemName: "clock")
                                .font(.system(size: 7))
                                .accessibilityHidden(true)
                        }
                        Text(reset?.countdown ?? "Unknown")
                            .font(.system(size: isSmall ? 8 : 10, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(reset.map { "Reset in \($0.countdown), out of seven days" } ?? "Reset time not reported")
                .accessibilityValue("\(window.remainingPercent) percent weekly usage remaining")
            } else {
                Text(state.status ?? "Usage unknown")
                    .font(.system(size: isSmall ? 8 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.leading, isSmall ? 8 : 11)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func largeAccount(_ account: AccountSnapshot, index: Int) -> some View {
        let state = account.weeklyUsage(at: referenceDate)
        let reset = state.window.flatMap { WeeklyResetProgress(window: $0, at: referenceDate) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                accountDot(index, size: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if snapshot.isLocalAccount(account, at: referenceDate) { loggedInBadge }
                }
                Spacer(minLength: 4)
                if let window = state.window {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(window.remainingPercent)%")
                            .font(.system(size: 27, weight: .light))
                            .monospacedDigit()
                        Text("left")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityLabel("\(window.remainingPercent) percent weekly usage remaining")
                } else {
                    Text("—")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            if state.window != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text(reset == nil ? "Reset time not reported" : "Time until reset")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(reset?.countdown ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                VStack(spacing: 4) {
                    resetTrack(reset, color: accent(index), height: 5)
                    HStack {
                        Text("0")
                        Spacer()
                        Text("7 days")
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                }
                .accessibilityLabel(reset.map { "\(Int(($0.fractionRemaining * 100).rounded())) percent of seven days until reset" } ?? "Reset time unknown")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.status ?? "Usage unknown")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if account.isConnected, let updatedAt = account.updatedAt, state != .notReported {
                        Text(CodexUsageViewerFormatting.updated(updatedAt, now: referenceDate))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Seven quiet day segments. Their fill encodes time, not token usage.
    private func resetTrack(_ progress: WeeklyResetProgress?, color: Color, height: CGFloat) -> some View {
        HStack(spacing: isSmall ? 2 : 3) {
            ForEach(0..<7) { day in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.075))
                        if let progress {
                            Capsule()
                                .fill(color)
                                .frame(width: geometry.size.width * min(1, max(0, progress.fractionRemaining * 7 - Double(day))))
                                .widgetAccentable()
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func accountDot(_ index: Int, size: CGFloat) -> some View {
        Circle().fill(accent(index)).frame(width: size, height: size)
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    private var loggedInBadge: some View {
        Label("Logged In", systemImage: "desktopcomputer")
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.055), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Logged In to local Codex")
    }

    private func accent(_ index: Int) -> Color {
        renderingMode == .accented ? .primary : CodexUsageViewerPalette.accent(for: index)
    }

    private func accountURL(_ account: AccountSnapshot) -> URL {
        URL(string: "codexusageviewer://account/\(account.id)")!
    }
}

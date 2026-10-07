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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex weekly usage and time until reset")
    }

    private func compactAccount(_ account: AccountSnapshot, index: Int) -> some View {
        let state = account.weeklyUsage(at: referenceDate)
        let reset = state.window.flatMap { WeeklyResetProgress(window: $0, at: referenceDate) }
        let subscription = account.subscriptionDisplayName ?? "Unknown plan"
        let resetDescription = reset.map { "Reset in \($0.countdown), out of seven days" } ?? "Reset time not reported"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: isSmall ? 4 : 6) {
                accountIndicator(account, index: index)
                Text(account.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                if let window = state.window {
                    Text("\(window.remainingPercent)%")
                        .font(.system(size: isSmall ? 11 : 12, weight: .semibold))
                        .monospacedDigit()
                        .fixedSize()
                        .accessibilityLabel("\(window.remainingPercent) percent weekly usage remaining")
                } else {
                    Text("—")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let window = state.window {
                HStack(spacing: isSmall ? 5 : 9) {
                    Text(subscription)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    resetTrack(reset, color: accent(index), height: isSmall ? 3 : 4)
                        .frame(minWidth: isSmall ? 30 : 50)
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
                .accessibilityLabel("\(subscription) subscription. \(resetDescription)")
                .accessibilityValue("\(window.remainingPercent) percent weekly usage remaining")
            } else {
                Text(state.status ?? "Usage unknown")
                    .font(.system(size: isSmall ? 8 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.leading, isSmall ? 14 : 18)
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
                accountIndicator(account, index: index)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let subscription = account.subscriptionDisplayName {
                        Text(subscription)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("Subscription plan: \(subscription)")
                    }
                }
                Spacer(minLength: 4)
                if let window = state.window {
                    Text("\(window.remainingPercent)%")
                        .font(.system(size: 27, weight: .light))
                        .monospacedDigit()
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

    private func accountIndicator(_ account: AccountSnapshot, index: Int) -> some View {
        Group {
            if snapshot.isLocalAccount(account, at: referenceDate) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: isSmall ? 9 : (isLarge ? 12 : 10), weight: .medium))
                    .foregroundStyle(accent(index))
                    .widgetAccentable()
                    .accessibilityLabel("Logged In")
            } else {
                Circle().fill(accent(index))
                    .frame(width: isSmall ? 4 : (isLarge ? 6 : 5), height: isSmall ? 4 : (isLarge ? 6 : 5))
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
        }
        .frame(width: isSmall ? 10 : (isLarge ? 14 : 12))
    }

    private func accent(_ index: Int) -> Color {
        renderingMode == .accented ? .primary : CodexUsageViewerPalette.accent(for: index)
    }

    private func accountURL(_ account: AccountSnapshot) -> URL {
        URL(string: "codexusageviewer://account/\(account.id)")!
    }
}

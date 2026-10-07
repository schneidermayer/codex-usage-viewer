import SwiftUI
import WidgetKit

/// Reads only the sanitized shared snapshot. Also reusable by the app's visual
/// verification harness without constructing a WidgetKit extension.
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
    private var connectedCount: Int { accounts.filter(\.isConnected).count }
    private var currentCount: Int {
        accounts.filter { account in
            account.isConnected && !account.isStale(at: referenceDate) && account.issue == nil
                && [account.primaryBucket?.primary, account.primaryBucket?.secondary]
                    .compactMap { $0 }
                    .contains { $0.usedPercent.isFinite && !$0.hasElapsed(at: referenceDate) }
        }.count
    }

    var body: some View {
        Group {
            if effectiveFamily == .systemSmall {
                smallContent
            } else if effectiveFamily == .systemLarge {
                largeContent
            } else {
                mediumContent
            }
        }
        .fontDesign(.rounded)
    }

    private var header: some View {
        HStack(spacing: 6) {
            CodexUsageViewerMark(size: 20)
                .widgetAccentable()
            Text(effectiveFamily == .systemSmall ? "Codex Usage" : "Codex Usage Viewer")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 4)
            if effectiveFamily != .systemSmall {
                Text("Codex usage")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var smallContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(connectedCount)")
                    .font(.system(size: 43, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("/ 3")
                    .font(.system(size: 19, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text("accounts connected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            HStack(spacing: 5) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    Capsule()
                        .fill(account.isConnected ? accent(index) : Color.secondary.opacity(0.18))
                        .frame(height: 4)
                        .widgetAccentable()
                }
            }
            Text(smallStatus)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 7)
        }
        .accessibilityElement(children: .combine)
    }

    private var smallStatus: String {
        if connectedCount == 0 {
            return accounts.contains(where: { $0.state == .needsSignIn }) ? "Sign in again in app" : "Connect in app"
        }
        if currentCount == connectedCount { return "\(currentCount) with recent usage" }
        return "\(currentCount) current · open for details"
    }

    private var mediumContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                Link(destination: accountURL(account)) {
                    compactRow(account, index: index)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func compactRow(_ account: AccountSnapshot, index: Int) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(accent(index))
                .frame(width: 6, height: 6)
                .widgetAccentable()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if snapshot.isLocalAccount(account, at: referenceDate) {
                    loggedInBadge
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = unavailableStatus(account) {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 148, alignment: .trailing)
            } else {
                compactWindow(account.primaryBucket?.primary)
                compactWindow(account.primaryBucket?.secondary)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func compactWindow(_ window: QuotaWindow?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(window?.label ?? "Not reported")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let window, isCurrent(window) {
                Text("\(window.remainingPercent)% left")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            } else {
                Text(window?.hasElapsed(at: referenceDate) == true ? "Refresh needed" : "—")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(window?.hasElapsed(at: referenceDate) == true ? "Reset passed; usage unknown until refreshed" : "Usage not reported")
            }
        }
        .frame(width: 70, alignment: .trailing)
    }

    private var largeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().opacity(0.65) }
                Link(destination: accountURL(account)) {
                    detailedRow(account, index: index)
                }
                .buttonStyle(.plain)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func detailedRow(_ account: AccountSnapshot, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(accent(index))
                    .frame(width: 7, height: 7)
                    .widgetAccentable()
                    .accessibilityHidden(true)
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if snapshot.isLocalAccount(account, at: referenceDate) {
                    loggedInBadge
                }
                Spacer(minLength: 4)
                if let plan = account.plan, account.isConnected {
                    Text(plan.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let status = unavailableStatus(account) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status)
                            .font(.system(size: 12, weight: .medium))
                        if account.isConnected, let updatedAt = account.updatedAt {
                            HStack(spacing: 3) {
                                Text("Last fetched")
                                Text(updatedAt, style: .relative)
                                Text("ago")
                            }
                            .font(.system(size: 9))
                        }
                    }
                    Spacer()
                    Image(systemName: account.state == .needsSignIn ? "person.crop.circle.badge.exclamationmark" : "arrow.up.right")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 15) {
                    detailedWindow(account.primaryBucket?.primary, color: accent(index))
                    detailedWindow(account.primaryBucket?.secondary, color: accent(index))
                }
                if account.buckets.count > 1 {
                    Text("\(account.buckets.count - 1) more \(account.buckets.count == 2 ? "limit" : "limits") in app")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailedWindow(_ window: QuotaWindow?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window?.label ?? "Not reported")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let window, isCurrent(window) {
                    Text("\(window.remainingPercent)% left")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .fixedSize()
                } else {
                    Text("—")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                Capsule().fill(Color.secondary.opacity(0.13))
                if let window, isCurrent(window) {
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * Double(window.remainingPercent) / 100)
                        .widgetAccentable()
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            resetCaption(window)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resetCaption(_ window: QuotaWindow?) -> some View {
        if let window, window.hasElapsed(at: referenceDate) {
            Text("Reset passed · refresh needed")
        } else if let window, isCurrent(window), let resetDate = window.resetDate {
            HStack(spacing: 3) {
                Text("Resets in")
                Text(resetDate, style: .relative)
            }
        } else {
            Text(window == nil ? "Usage not reported" : "Reset time unavailable")
        }
    }

    private func unavailableStatus(_ account: AccountSnapshot) -> String? {
        switch account.state {
        case .disconnected: return "Connect in app"
        case .needsSignIn: return "Sign in again in app"
        case .connected:
            if account.issue != nil { return "Update unavailable · open app" }
            guard account.updatedAt != nil else { return "Waiting for usage" }
            if account.isStale(at: referenceDate) { return "Usage out of date · open app" }
            guard let bucket = account.primaryBucket,
                  bucket.primary != nil || bucket.secondary != nil else { return "Usage not reported" }
            return nil
        }
    }

    private func isCurrent(_ window: QuotaWindow) -> Bool {
        window.usedPercent.isFinite && !window.hasElapsed(at: referenceDate)
    }

    private var loggedInBadge: some View {
        Label("Logged In", systemImage: "desktopcomputer")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.065), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Logged In to local Codex")
    }

    private func accent(_ index: Int) -> Color {
        if renderingMode == .accented { return .primary }
        return CodexUsageViewerPalette.accent(for: index)
    }

    private func accountURL(_ account: AccountSnapshot) -> URL {
        URL(string: "codexusageviewer://account/\(account.id)")!
    }
}

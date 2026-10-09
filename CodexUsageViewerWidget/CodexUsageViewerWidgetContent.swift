import SwiftUI
import WidgetKit

struct CodexUsageViewerWidgetContent: View {
    let snapshot: UsageSnapshot
    var family: WidgetFamily?
    var referenceDate: Date = .now

    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var isSmall: Bool { (family ?? environmentFamily) == .systemSmall }
    private var accounts: [AccountSnapshot] {
        CodexUsageViewerConstants.accountIDs.enumerated().map { index, id in
            snapshot.accounts.first(where: { $0.id == id })
                ?? AccountSnapshot(id: id, name: "Account \(index + 1)")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = isSmall ? 4 : 12
            let columnWidth = max(0, (geometry.size.width - 2 * spacing) / 3)
            HStack(spacing: spacing) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    Group {
                        if isSmall {
                            accountColumn(account, index: index)
                        } else {
                            Link(destination: accountURL(account)) {
                                accountColumn(account, index: index)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: columnWidth, height: geometry.size.height)
                }
            }
        }
        .fontDesign(.rounded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex weekly usage, credits, available resets, and time until reset")
    }

    private func accountColumn(_ account: AccountSnapshot, index: Int) -> some View {
        let color = accent(index)
        let state = account.weeklyUsage(at: referenceDate)
        let reset = state.window.flatMap { WeeklyResetProgress(window: $0, at: referenceDate) }
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                if snapshot.isLocalAccount(account, at: referenceDate) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: isSmall ? 7 : 10, weight: .semibold))
                        .foregroundStyle(color)
                        .widgetAccentable()
                        .accessibilityLabel("Logged In")
                }
                Text(widgetName(account))
                    .font(.system(size: isSmall ? 10 : 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(account.displayName)
                    .help(account.displayName)
            }
            .frame(height: 16)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(state.window.map { String($0.remainingPercent) } ?? "—")
                    .font(.system(size: isSmall ? 19.5 : 31, weight: .semibold))
                    .monospacedDigit()
                if state.window != nil {
                    Text("%")
                        .font(.system(size: isSmall ? 9 : 13, weight: .medium))
                }
            }
            .foregroundStyle(state.window == nil ? Color.secondary : color)
            .widgetAccentable()
            .fixedSize()
            .frame(height: isSmall ? 30 : 36)
            .padding(.top, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.window.map { "\($0.remainingPercent) percent weekly usage remaining" } ?? "Weekly usage unknown")

            Spacer(minLength: 3)

            Text(account.subscriptionDisplayName ?? "—")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.13), in: Capsule())
                .frame(height: 14)
                .accessibilityLabel("Subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")
                .help("Subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")

            if state.window != nil {
                CodexUsageViewerResetTrack(fractionRemaining: reset?.fractionRemaining,
                                          accent: color, height: 4, spacing: isSmall ? 1 : 3,
                                          widgetAccentable: true)
                    .padding(.top, 5)
                Text(reset?.countdown ?? "—")
                    .font(.system(size: isSmall ? 9 : 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: 14)
                    .padding(.top, 3)
                    .accessibilityLabel(reset.map { "Reset in \($0.countdown), out of seven days" } ?? "Reset time not reported")
                    .help(reset.map { "Reset in \($0.countdown), out of seven days" } ?? "Reset time not reported")
            } else {
                Text(compactStatus(state))
                    .font(.system(size: isSmall ? 9 : 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(height: 26)
                    .accessibilityLabel(state.status ?? "Usage unknown")
                    .help(state.status ?? "Usage unknown")
            }

            Spacer(minLength: 5)

            if isSmall {
                VStack(spacing: 3) {
                    credits(account)
                    availableResets(account)
                }
            } else {
                HStack(spacing: 3) {
                    credits(account)
                    Spacer(minLength: 0)
                    availableResets(account)
                }
                .frame(height: 17)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func credits(_ account: AccountSnapshot) -> some View {
        resource(account.creditsValue(at: referenceDate), symbol: "c.circle", alignment: .leading,
                 label: "Available credits", help: "Credits available for additional usage")
    }

    private func availableResets(_ account: AccountSnapshot) -> some View {
        resource(account.resetsValue(at: referenceDate), symbol: "arrow.counterclockwise", alignment: isSmall ? .center : .trailing,
                 label: "Available usage resets", help: "Earned usage resets available to use")
    }

    private func resource(_ value: AccountResourceValue, symbol: String, alignment: Alignment,
                          label: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: isSmall ? 9 : 10, weight: .medium))
                .accessibilityHidden(true)
            Text(compactResourceText(value))
                .font(.system(size: isSmall ? 9 : 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value.accessibilityText)")
        .help("\(help): \(value.accessibilityText)")
    }

    private func widgetName(_ account: AccountSnapshot) -> String {
        // Shorten only the verified profile name; preserve official email and slot fallbacks.
        account.fullName?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? account.displayName
    }

    private func compactResourceText(_ value: AccountResourceValue) -> String {
        let text = value.compactText
        // Keep scientific values readable in a column: 1.0E+030 becomes 1e30.
        let parts = text.split(separator: "E")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        let mantissa = parts[0].hasSuffix(".0") ? String(parts[0].dropLast(2)) : String(parts[0])
        return "\(mantissa)e\(exponent)"
    }

    private func compactStatus(_ state: WeeklyUsageState) -> String {
        switch state {
        case .disconnected: return "Connect\nin app"
        case .needsSignIn: return "Sign in\nagain"
        case .waiting: return "Waiting\nfor usage"
        case .stale: return "Out of\ndate"
        case .unavailable: return "Update\nunavailable"
        case .notReported: return "Not\nreported"
        case .resetElapsed: return "Refresh\nto check"
        case .available: return "—"
        }
    }

    private func accent(_ index: Int) -> Color {
        renderingMode == .accented ? .primary : CodexUsageViewerPalette.accent(for: index)
    }

    private func accountURL(_ account: AccountSnapshot) -> URL {
        URL(string: "codexusageviewer://account/\(account.id)")!
    }
}

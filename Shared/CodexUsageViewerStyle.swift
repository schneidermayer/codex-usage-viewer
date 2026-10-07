import SwiftUI
import WidgetKit

enum CodexUsageViewerPalette {
    static let mint = Color(red: 0.24, green: 0.68, blue: 0.53)
    static let lilac = Color(red: 0.60, green: 0.47, blue: 0.85)
    static let apricot = Color(red: 0.88, green: 0.53, blue: 0.32)

    static func accent(for index: Int) -> Color {
        [mint, lilac, apricot][abs(index) % 3]
    }

    static func index(for accountID: String) -> Int {
        CodexUsageViewerConstants.accountIDs.firstIndex(of: accountID) ?? 0
    }
}

struct CodexUsageViewerMark: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.primary.opacity(0.16), lineWidth: size * 0.035)
                .padding(size * 0.15)
            Circle()
                .fill(.primary.opacity(0.9))
                .frame(width: size * 0.19, height: size * 0.19)
            Circle()
                .fill(CodexUsageViewerPalette.mint)
                .frame(width: size * 0.20, height: size * 0.20)
                .offset(x: 0, y: -size * 0.34)
            Circle()
                .fill(CodexUsageViewerPalette.lilac)
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: -size * 0.29, y: size * 0.18)
            Circle()
                .fill(CodexUsageViewerPalette.apricot)
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: size * 0.29, y: size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerQuotaTrack: View {
    var remaining: Int
    var accent: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.13))
                Capsule()
                    .fill(accent.gradient)
                    .frame(width: max(0, geometry.size.width * CGFloat(max(0, min(100, remaining))) / 100))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerQuotaRing: View {
    var remaining: Int
    var accent: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, remaining))) / 100)
                .stroke(accent.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerResetTrack: View {
    var fractionRemaining: Double?
    var accent: Color
    var segments = 7
    var height: CGFloat = 6
    var spacing: CGFloat = 4
    var widgetAccentable = false

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<segments, id: \.self) { segment in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.075))
                        if let fractionRemaining {
                            Capsule()
                                .fill(accent)
                                .frame(width: geometry.size.width * min(1, max(0, fractionRemaining * Double(segments) - Double(segment))))
                                .widgetAccentable(widgetAccentable)
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerEyebrow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.8)
            .foregroundStyle(.secondary)
    }
}

enum CodexUsageViewerFormatting {
    static func reset(_ window: QuotaWindow, now: Date = .now) -> String {
        guard let reset = window.resetDate else { return "Reset time unavailable" }
        guard reset > now else { return "Reset passed · refresh to check" }
        let minutes = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if minutes < 1_440 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "Resets in \(hours)h" : "Resets in \(hours)h \(remainder)m"
        }
        return "Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    static func updated(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Not updated yet" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3_600)h ago" }
        return "Updated \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

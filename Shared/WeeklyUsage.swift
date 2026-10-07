import Foundation

extension AccountSnapshot {
    /// Weekly quota may occupy either slot; never substitute session usage.
    var weeklyWindow: QuotaWindow? {
        guard let bucket = primaryBucket else { return nil }
        return [bucket.primary, bucket.secondary].compactMap { $0 }
            .first { $0.windowDurationMins == 10_080 }
    }

    func weeklyUsage(at date: Date = .now) -> WeeklyUsageState {
        switch state {
        case .disconnected: return .disconnected
        case .needsSignIn: return .needsSignIn
        case .connected:
            guard issue == nil else { return .unavailable }
            guard updatedAt != nil else { return .waiting }
            guard !isStale(at: date) else { return .stale }
            guard let window = weeklyWindow else { return .notReported }
            guard window.usedPercent.isFinite, window.usedPercent >= 0 else { return .unavailable }
            guard !window.hasElapsed(at: date) else { return .resetElapsed }
            return .available(window)
        }
    }
}

enum WeeklyUsageState: Equatable {
    case available(QuotaWindow)
    case disconnected, needsSignIn, waiting, stale, unavailable, notReported, resetElapsed

    var window: QuotaWindow? {
        if case .available(let window) = self { return window }
        return nil
    }

    var status: String? {
        switch self {
        case .available: return nil
        case .disconnected: return "Connect in app"
        case .needsSignIn: return "Sign in again"
        case .waiting: return "Waiting for usage"
        case .stale: return "Usage out of date"
        case .unavailable: return "Update unavailable"
        case .notReported: return "Weekly not reported"
        case .resetElapsed: return "Reset passed · refresh"
        }
    }
}

struct WeeklyResetProgress: Equatable {
    static let duration: TimeInterval = 7 * 24 * 60 * 60
    private let progress: QuotaResetProgress

    init?(window: QuotaWindow, at date: Date = .now) {
        guard window.windowDurationMins == 10_080,
              let progress = QuotaResetProgress(window: window, at: date) else { return nil }
        self.progress = progress
    }

    var secondsRemaining: TimeInterval { progress.secondsRemaining }
    var fractionRemaining: Double { progress.fractionRemaining }
    var countdown: String { progress.countdown }
}

struct QuotaResetProgress: Equatable {
    let duration: TimeInterval
    let secondsRemaining: TimeInterval

    init?(window: QuotaWindow, at date: Date = .now) {
        guard let minutes = window.windowDurationMins, minutes > 0,
              let resetDate = window.resetDate else { return nil }
        let remaining = resetDate.timeIntervalSince(date)
        guard remaining.isFinite, remaining > 0 else { return nil }
        duration = Double(minutes) * 60
        secondsRemaining = remaining
    }

    var fractionRemaining: Double { min(1, max(0, secondsRemaining / duration)) }

    var countdown: String {
        if secondsRemaining < 60 { return "<1m" }
        // Round down to avoid overstating time remaining.
        let minutes = Int(min(secondsRemaining / 60, Double(Int.max / 60)))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

enum WeeklyWidgetTimeline {
    static func dates(snapshot: UsageSnapshot, now: Date, reloadAt: Date) -> [Date] {
        var dates = [now, reloadAt]
        // Update countdowns from cached data; the host controls delivery.
        var tick = now.addingTimeInterval(5 * 60)
        while tick < reloadAt {
            dates.append(tick)
            tick = tick.addingTimeInterval(5 * 60)
        }
        let timestamps = snapshot.accounts.compactMap(\.updatedAt) + [snapshot.localCodexCheckedAt].compactMap { $0 }
        for timestamp in timestamps {
            let staleAt = timestamp.addingTimeInterval(CodexUsageViewerConstants.staleInterval + 1)
            if staleAt > now && staleAt < reloadAt { dates.append(staleAt) }
        }
        for account in snapshot.accounts {
            if let resetAt = account.weeklyWindow?.resetDate, resetAt > now && resetAt < reloadAt {
                dates.append(resetAt)
            }
        }
        return Set(dates).sorted()
    }
}

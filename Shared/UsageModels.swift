import Foundation

enum CodexUsageViewerConstants {
    static let widgetKind = "CodexUsageViewerUsageWidget"
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "CodexUsageViewerAppGroup") as? String ?? "AW7ZNT442J.com.inndevs.codexusageviewer"
    }
    static let accountIDs = ["account-1", "account-2", "account-3"]
    static let refreshInterval: TimeInterval = 180
    static let staleInterval: TimeInterval = 600
}

struct QuotaWindow: Codable, Equatable, Sendable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Int?

    var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent)).rounded()) }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: Double($0)) } }
    var label: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Usage window" }
        if minutes == 10_080 { return "Weekly" }
        if minutes >= 1_440 && minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
    func hasElapsed(at date: Date = .now) -> Bool { resetDate.map { $0 <= date } ?? false }
}

extension QuotaWindow {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try values.decode(Double.self, forKey: .usedPercent)
        guard usedPercent.isFinite, usedPercent >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .usedPercent, in: values, debugDescription: "Usage must be a finite, nonnegative percentage.")
        }
        windowDurationMins = try values.decodeIfPresent(Int.self, forKey: .windowDurationMins)
        resetsAt = try values.decodeIfPresent(Int.self, forKey: .resetsAt)
    }
}

struct CreditBalance: Codable, Equatable, Sendable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

struct UsageBucket: Codable, Equatable, Identifiable, Sendable {
    var limitId: String?
    var limitName: String?
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
    var credits: CreditBalance?
    var planType: String?
    var rateLimitReachedType: String?
    var id: String { limitId ?? "codex" }
    var title: String { limitName ?? (id == "codex" ? "Codex" : id.replacingOccurrences(of: "_", with: " ").capitalized) }
}

struct RateLimitsResponse: Codable, Sendable {
    var rateLimits: UsageBucket
    var rateLimitsByLimitId: [String: UsageBucket]?
    var accountId: String?
    var ordinaryUsageAllowed: Bool?

    var buckets: [UsageBucket] {
        guard let all = rateLimitsByLimitId, !all.isEmpty else { return [rateLimits] }
        return all.map { key, value in
            var bucket = value
            if bucket.limitId == nil { bucket.limitId = key }
            return bucket
        }.sorted { lhs, rhs in
            if lhs.id == "codex" { return rhs.id != "codex" }
            if rhs.id == "codex" { return false }
            return lhs.id < rhs.id
        }
    }
}

enum AccountConnectionState: String, Codable, Sendable {
    case disconnected, connected, needsSignIn
}

struct AccountSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var email: String?
    var plan: String?
    var state: AccountConnectionState = .disconnected
    var buckets: [UsageBucket] = []
    var updatedAt: Date?
    var issue: String?

    var primaryBucket: UsageBucket? { buckets.first(where: { $0.id == "codex" }) ?? buckets.first }
    var isConnected: Bool { state == .connected }
    func isStale(at date: Date = .now) -> Bool {
        guard let updatedAt else { return true }
        let age = date.timeIntervalSince(updatedAt)
        return age > CodexUsageViewerConstants.staleInterval || age < -60
    }
    static var emptyAccounts: [AccountSnapshot] {
        CodexUsageViewerConstants.accountIDs.enumerated().map { AccountSnapshot(id: $0.element, name: "Account \($0.offset + 1)") }
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var accounts: [AccountSnapshot]
    var savedAt: Date
    var localCodexEmail: String? = nil
    var localCodexCheckedAt: Date? = nil
    func isLocalAccount(_ account: AccountSnapshot, at date: Date = .now) -> Bool {
        guard account.isConnected, let email = account.email, let localCodexEmail,
              let checkedAt = localCodexCheckedAt,
              date.timeIntervalSince(checkedAt) <= CodexUsageViewerConstants.staleInterval,
              date.timeIntervalSince(checkedAt) >= -60 else { return false }
        let accountEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let localEmail = localCodexEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return !accountEmail.isEmpty && !localEmail.isEmpty && accountEmail.caseInsensitiveCompare(localEmail) == .orderedSame
    }
    static var empty: UsageSnapshot { UsageSnapshot(accounts: AccountSnapshot.emptyAccounts, savedAt: .now) }

    // Deliberate fixture, only used by previews and the explicitly labeled demo mode.
    static var preview: UsageSnapshot {
        let now = Date.now
        var accounts = AccountSnapshot.emptyAccounts
        let names = ["Personal", "Studio", "Projects"]
        for index in accounts.indices {
            accounts[index].name = names[index]
            accounts[index].email = ["personal@example.com", "studio@example.com", "projects@example.com"][index]
            accounts[index].plan = ["pro", "plus", "pro"][index]
            accounts[index].state = .connected
            accounts[index].updatedAt = now
            accounts[index].buckets = [UsageBucket(limitId: "codex", primary: QuotaWindow(usedPercent: [28, 64, 12][index], windowDurationMins: 300, resetsAt: Int(now.timeIntervalSince1970) + [7_620, 3_240, 12_600][index]), secondary: QuotaWindow(usedPercent: [42, 79, 23][index], windowDurationMins: 10_080, resetsAt: Int(now.timeIntervalSince1970) + 172_800))]
        }
        return UsageSnapshot(accounts: accounts, savedAt: now)
    }
}

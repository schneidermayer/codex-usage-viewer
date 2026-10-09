import Foundation

enum CodexUsageViewerConstants {
    // Keep this kind stable for installed wide widgets.
    static let widgetKind = "CodexUsageViewerUsageWidget"
    static let smallWidgetKind = "CodexUsageViewerSmallWidget"
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

/// Widget-safe summary; excludes redemption IDs.
struct RateLimitResetCredits: Codable, Equatable, Sendable {
    var availableCount: Int?
    var earliestExpiresAt: Int?

    init(availableCount: Int?, earliestExpiresAt: Int? = nil) {
        self.availableCount = availableCount
        self.earliestExpiresAt = earliestExpiresAt
    }

    var expiryDate: Date? { earliestExpiresAt.map { Date(timeIntervalSince1970: Double($0)) } }

    private enum CodingKeys: String, CodingKey { case availableCount, earliestExpiresAt, credits }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try values.decodeIfPresent(Int.self, forKey: .availableCount)
        earliestExpiresAt = try values.decodeIfPresent(Int.self, forKey: .earliestExpiresAt)
        struct Detail: Decodable {
            var status: String?
            var expiresAt: Int?
        }
        if let details = try values.decodeIfPresent([Detail].self, forKey: .credits) {
            let expiry = details.filter { $0.status == "available" }.compactMap(\.expiresAt).min()
            earliestExpiresAt = [earliestExpiresAt, expiry].compactMap { $0 }.min()
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(availableCount, forKey: .availableCount)
        try values.encodeIfPresent(earliestExpiresAt, forKey: .earliestExpiresAt)
    }
}

enum AccountResourceValue: Equatable, Sendable {
    case unknown, amount(String), available, unlimited

    var text: String {
        switch self {
        case .unknown: return "Unknown"
        case .amount(let value): return Self.decimal(value).map(Self.decimalText) ?? value
        case .available: return "Available"
        case .unlimited: return "Unlimited"
        }
    }

    var compactText: String {
        switch self {
        case .unknown: return "—"
        case .available: return "Yes"
        case .unlimited: return "∞"
        case .amount(let value): return Self.compactAmount(value)
        }
    }

    var accessibilityText: String { text }

    fileprivate static func decimal(_ value: String) -> Decimal? {
        // Decimal accepts numeric prefixes; validate the whole string first.
        guard value.count <= 256,
              value.range(of: #"^[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !number.isNaN, number >= 0 else { return nil }
        return number
    }

    private static func compactAmount(_ value: String) -> String {
        guard let number = decimal(value) else { return value }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.roundingMode = .down
        formatter.maximumFractionDigits = 1
        for (threshold, suffix) in [(Decimal(1_000_000_000_000), "T"), (Decimal(1_000_000_000), "B"), (Decimal(1_000_000), "M"), (Decimal(1_000), "K")] {
            if number >= threshold {
                if number >= Decimal(1_000_000_000_000_000) {
                    formatter.numberStyle = .scientific
                    return formatter.string(from: NSDecimalNumber(decimal: number)) ?? value
                }
                return (formatter.string(from: NSDecimalNumber(decimal: number / threshold)) ?? value) + suffix
            }
        }
        return decimalText(number)
    }

    private static func decimalText(_ number: Decimal) -> String {
        if number > 0, number < Decimal(string: "0.01")! { return "<0.01" }
        var original = number
        var rounded = Decimal()
        NSDecimalRound(&rounded, &original, 2, .down)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
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
    var rateLimitResetCredits: RateLimitResetCredits?

    var buckets: [UsageBucket] {
        guard let all = rateLimitsByLimitId, !all.isEmpty else { return [rateLimits] }
        var buckets = all.map { key, value in
            var bucket = value
            if bucket.limitId == nil { bucket.limitId = key }
            if bucket.id == rateLimits.id, bucket.credits == nil { bucket.credits = rateLimits.credits }
            return bucket
        }
        if rateLimits.credits != nil, !buckets.contains(where: { $0.id == rateLimits.id }) {
            buckets.append(rateLimits)
        }
        return buckets.sorted { lhs, rhs in
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
    var fullName: String? = nil
    var resetCredits: RateLimitResetCredits? = nil

    // Legacy slot labels remain decodable but are never used as account names.
    var displayName: String {
        if let value = fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        if let value = email?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        if let index = CodexUsageViewerConstants.accountIDs.firstIndex(of: id) { return "Account \(index + 1)" }
        return "Account"
    }

    /// Display labels; preserve the reported plan in storage.
    var subscriptionDisplayName: String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        switch plan.lowercased() {
        case "prolite": return "100"
        case "pro": return "200"
        case "promax": return "500"
        default: return plan
        }
    }

    var primaryBucket: UsageBucket? { buckets.first(where: { $0.id == "codex" }) ?? buckets.first }
    var isConnected: Bool { state == .connected }

    func creditsValue(at date: Date = .now) -> AccountResourceValue {
        guard isConnected, issue == nil, !isStale(at: date), let credits = primaryBucket?.credits else { return .unknown }
        if credits.unlimited { return .unlimited }
        if !credits.hasCredits { return .amount("0") }
        guard let rawBalance = credits.balance else { return .available }
        let value = rawBalance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let balance = AccountResourceValue.decimal(value) else { return .unknown }
        return .amount(NSDecimalNumber(decimal: balance).stringValue)
    }

    func resetsValue(at date: Date = .now) -> AccountResourceValue {
        guard isConnected, issue == nil, !isStale(at: date),
              let resets = resetCredits, let count = resets.availableCount, count >= 0 else { return .unknown }
        if let expiry = resets.expiryDate, expiry <= date { return .unknown }
        return .amount(String(count))
    }

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

    // Synthetic preview/test data; never persisted.
    static var preview: UsageSnapshot {
        let now = Date.now
        var accounts = AccountSnapshot.emptyAccounts
        let names = ["Alex Morgan", "Sam Rivera", "Jordan Lee"]
        for index in accounts.indices {
            accounts[index].fullName = names[index]
            accounts[index].email = ["personal@example.com", "studio@example.com", "projects@example.com"][index]
            accounts[index].plan = ["pro", "plus", "pro"][index]
            accounts[index].state = .connected
            accounts[index].updatedAt = now
            accounts[index].buckets = [UsageBucket(limitId: "codex", primary: QuotaWindow(usedPercent: [28, 64, 12][index], windowDurationMins: 300, resetsAt: Int(now.timeIntervalSince1970) + [7_620, 3_240, 12_600][index]), secondary: QuotaWindow(usedPercent: [42, 79, 23][index], windowDurationMins: 10_080, resetsAt: Int(now.timeIntervalSince1970) + 172_800))]
            accounts[index].buckets[0].credits = [CreditBalance(hasCredits: true, unlimited: false, balance: "125.5"), CreditBalance(hasCredits: false, unlimited: false, balance: "0"), CreditBalance(hasCredits: true, unlimited: true, balance: nil)][index]
            accounts[index].resetCredits = RateLimitResetCredits(availableCount: [2, 0, 1][index], earliestExpiresAt: Int(now.timeIntervalSince1970) + 86_400)
        }
        return UsageSnapshot(accounts: accounts, savedAt: now)
    }
}

import AppKit
import Foundation

struct ChromeProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    /// Reads Chrome's profile index, without cookies or sign-in data.
    static func discover() -> [ChromeProfile] {
        let state = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let size = try? state.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 10_485_760, let data = try? Data(contentsOf: state) else { return [] }
        return parseMetadata(data)
    }

    static func parseMetadata(_ data: Data) -> [ChromeProfile] {
        struct ProfileInfo: Decodable { let name: String? }
        struct ProfileIndex: Decodable { let info_cache: [String: ProfileInfo]? }
        struct LocalState: Decodable { let profile: ProfileIndex? }
        guard let state = try? JSONDecoder().decode(LocalState.self, from: data),
              let profiles = state.profile?.info_cache else { return [] }
        return profiles.compactMap { directory, info -> ChromeProfile? in
            guard isValidDirectory(directory) else { return nil }
            let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChromeProfile(id: directory, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? directory)
        }.sorted { left, right in
            if left.id == "Default" { return right.id != "Default" }
            if right.id == "Default" { return false }
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    static func isValidDirectory(_ value: String) -> Bool {
        value.range(of: #"\A(Default|Profile [0-9]+)\z"#, options: .regularExpression) != nil
    }

    /// Routes sign-in to the selected Chrome profile.
    @MainActor
    static func open(_ url: URL, profileID: String) async throws {
        guard isValidDirectory(profileID), discover().contains(where: { $0.id == profileID }) else {
            throw ChromeProfileError.invalidProfile
        }
        guard CodexConnection.validatedLoginURL(url.absoluteString) != nil else { throw ChromeProfileError.invalidURL }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw ChromeProfileError.notInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--profile-directory=\(profileID)", url.absoluteString]
        _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
    }
}

enum ChromeProfileError: LocalizedError {
    case invalidProfile, invalidURL, notInstalled

    var errorDescription: String? {
        switch self {
        case .invalidProfile: return "Choose an existing Chrome profile, then try again."
        case .invalidURL: return "The sign-in link is invalid. Start sign-in again."
        case .notInstalled: return "Google Chrome could not be found. Copy the sign-in link into your browser instead."
        }
    }
}

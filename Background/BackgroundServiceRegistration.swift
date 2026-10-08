import CryptoKit
import Foundation
import ServiceManagement

/// Register the bundled agent once, and replace its registration when its binary changes.
@MainActor
final class BackgroundServiceRegistration {
    private let service = SMAppService.agent(plistName: "com.inndevs.codexusageviewer.helper.plist")
    private var registrationError: String?
    private var registering = false

    var needsApproval: Bool { service.status == .requiresApproval }

    var issue: String? {
        switch service.status {
        case .enabled: return nil
        case .requiresApproval:
            return "Allow Codex Usage Viewer in System Settings → General → Login Items & Extensions to keep usage updated."
        default:
            return registrationError ?? "Background updates aren’t running. Retry in Settings."
        }
    }

    func registerIfNeeded() async {
        guard !registering else { return }
        registering = true
        defer { registering = false }
        // Respect a user disabling the service in System Settings.
        guard service.status != .requiresApproval else { return }
        do {
            let root = Bundle.main.bundleURL
            let executable = root.appendingPathComponent("Contents/MacOS/CodexUsageViewerHelper")
            let plist = root.appendingPathComponent("Contents/Library/LaunchAgents/com.inndevs.codexusageviewer.helper.plist")
            var content = try Data(contentsOf: executable)
            content.append(try Data(contentsOf: plist))
            let fingerprint = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            let key = "backgroundHelperFingerprint"
            if service.status == .enabled, UserDefaults.standard.string(forKey: key) != fingerprint {
                try await service.unregister()
            }
            if service.status != .enabled { try service.register() }
            if service.status == .enabled { UserDefaults.standard.set(fingerprint, forKey: key) }
            registrationError = nil
        } catch {
            registrationError = "The background helper couldn’t start. Keep the app in Applications, then retry in Settings."
        }
    }
}

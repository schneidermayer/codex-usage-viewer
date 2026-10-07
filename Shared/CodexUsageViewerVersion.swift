import Foundation

enum CodexUsageViewerVersion {
    private struct BuildVersion: Decodable { let display: String }

    static var display: String {
        guard let url = Bundle.main.url(forResource: "BuildVersion", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let version = try? JSONDecoder().decode(BuildVersion.self, from: data) else {
            return "Development"
        }
        return version.display
    }
}

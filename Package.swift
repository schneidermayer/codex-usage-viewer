// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageViewerCore",
    platforms: [.macOS("27.0")],
    products: [.library(name: "CodexUsageViewerCore", targets: ["CodexUsageViewerCore"])],
    targets: [
        .target(name: "CodexUsageViewerCore", path: ".", exclude: ["build", "dist", "VERSION", "docs", "README.md", "CodexUsageViewer.xcodeproj", "CodexUsageViewer/Assets.xcassets", "Shared/CodexUsageViewerStyle.swift", "CodexUsageViewer/Views", "CodexUsageViewer/CodexUsageViewerApp.swift", "CodexUsageViewerWidget", "Config", "Tests", "scripts", "AGENTS.md"], sources: ["Shared/UsageModels.swift", "Shared/WeeklyUsage.swift", "Shared/CodexUsageViewerVersion.swift", "Shared/SharedSnapshotStore.swift", "CodexUsageViewer/Services", "CodexUsageViewer/CodexUsageViewerStore.swift"]),
        .testTarget(name: "CodexUsageViewerCoreTests", dependencies: ["CodexUsageViewerCore"], path: "Tests", exclude: ["UI"])
    ],
    swiftLanguageModes: [.v5]
)

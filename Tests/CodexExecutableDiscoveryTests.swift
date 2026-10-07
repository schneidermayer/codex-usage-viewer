import Foundation
import XCTest
@testable import CodexUsageViewerCore

@MainActor
final class CodexExecutableDiscoveryTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("codex-discovery-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Discovery must inspect this dummy binary without executing it.
        try Data("discovery-fixture-only".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func install(home: URL, nodeVersion: String, codexVersion: String, nativePresent: Bool = true, optionalPackage: Bool = false) throws -> URL {
        let node = home.appendingPathComponent(".nvm/versions/node/\(nodeVersion)")
        let root = node.appendingPathComponent("lib/node_modules/@openai/codex")
        let script = root.appendingPathComponent("bin/codex.js")
        try makeExecutable(script)
        #if arch(arm64)
        let target = "aarch64-apple-darwin"
        let platformPackage = "codex-darwin-arm64"
        #else
        let target = "x86_64-apple-darwin"
        let platformPackage = "codex-darwin-x64"
        #endif
        var fields: [String: Any] = ["name": "@openai/codex", "version": codexVersion]
        if optionalPackage {
            fields["optionalDependencies"] = ["@openai/\(platformPackage)": "npm:@openai/codex@\(codexVersion)"]
            let optionalRoot = root.appendingPathComponent("node_modules/@openai/\(platformPackage)")
            try FileManager.default.createDirectory(at: optionalRoot, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: optionalRoot.appendingPathComponent("package.json"))
            let targetRoot = optionalRoot.appendingPathComponent("vendor/\(target)")
            try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["layoutVersion": 1, "target": target, "entrypoint": "bin/codex"])
                .write(to: targetRoot.appendingPathComponent("codex-package.json"))
        }
        try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent("package.json"))
        let wrapper = node.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: wrapper, withDestinationURL: script)
        if nativePresent {
            let native = optionalPackage
                ? root.appendingPathComponent("node_modules/@openai/\(platformPackage)/vendor/\(target)/bin/codex")
                : root.appendingPathComponent("vendor/\(target)/codex/codex")
            try makeExecutable(native)
        }
        return wrapper
    }

    func testNVMSelectsNewestCodexInsteadOfNewestNode() throws {
        try withDirectory { home in
            _ = try install(home: home, nodeVersion: "v25.2.1", codexVersion: "0.92.0")
            let newest = try install(home: home, nodeVersion: "v24.19.0", codexVersion: "0.160.1", optionalPackage: true)
            _ = try install(home: home, nodeVersion: "v24.13.0", codexVersion: "0.148.0")
            let selected = CodexConnection.locateExecutable(override: nil, environment: [:], userDirectory: home, standardPaths: [])
            XCTAssertEqual(selected?.resolvingSymlinksInPath(), newest.resolvingSymlinksInPath())
        }
    }

    func testWrapperWhoseNativeBinaryWasRemovedIsRejectedEverywhere() throws {
        try withDirectory { home in
            let incomplete = try install(home: home, nodeVersion: "v25.2.1", codexVersion: "0.999.0", nativePresent: false)
            let complete = try install(home: home, nodeVersion: "v24.19.0", codexVersion: "0.160.1", optionalPackage: true)
            let environment = ["PATH": incomplete.deletingLastPathComponent().path]
            XCTAssertEqual(CodexConnection.locateExecutable(override: nil, environment: environment, userDirectory: home, standardPaths: [])?.resolvingSymlinksInPath(), complete.resolvingSymlinksInPath())
            XCTAssertNil(CodexConnection.locateExecutable(override: incomplete.path, environment: environment, userDirectory: home, standardPaths: []))
        }
    }

    func testValidExplicitOverrideAndPATHKeepTheirPrecedence() throws {
        try withDirectory { home in
            let preferred = try install(home: home, nodeVersion: "v25.2.1", codexVersion: "0.148.0")
            let newer = try install(home: home, nodeVersion: "v24.19.0", codexVersion: "0.160.1", optionalPackage: true)
            let environment = ["PATH": preferred.deletingLastPathComponent().path]
            XCTAssertEqual(CodexConnection.locateExecutable(override: nil, environment: environment, userDirectory: home, standardPaths: []), preferred)
            XCTAssertEqual(CodexConnection.locateExecutable(override: newer.path, environment: environment, userDirectory: home, standardPaths: []), newer)
            XCTAssertNil(CodexConnection.locateExecutable(override: home.appendingPathComponent("missing").path, environment: environment, userDirectory: home, standardPaths: []))
        }
    }

    func testReleaseIsPreferredOverSameVersionPrerelease() throws {
        try withDirectory { home in
            _ = try install(home: home, nodeVersion: "v25.2.1", codexVersion: "0.160.1-alpha.1")
            let release = try install(home: home, nodeVersion: "v24.19.0", codexVersion: "0.160.1")
            XCTAssertEqual(CodexConnection.locateExecutable(override: nil, environment: [:], userDirectory: home, standardPaths: [])?.resolvingSymlinksInPath(), release.resolvingSymlinksInPath())
        }
    }

    func testNativeCommandOnPATHDoesNotRequireNPMPackageMetadata() throws {
        try withDirectory { home in
            let native = home.appendingPathComponent("tools/codex")
            try makeExecutable(native)
            XCTAssertEqual(CodexConnection.locateExecutable(override: nil, environment: ["PATH": native.deletingLastPathComponent().path],
                                                          userDirectory: home, standardPaths: []), native)
        }
    }

    func testBrokenResolvedOptionalPackageCannotUseStaleEmbeddedBinary() throws {
        try withDirectory { home in
            let broken = try install(home: home, nodeVersion: "v25.2.1", codexVersion: "0.160.1", nativePresent: false, optionalPackage: true)
            let root = broken.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            #if arch(arm64)
            let target = "aarch64-apple-darwin"
            #else
            let target = "x86_64-apple-darwin"
            #endif
            try makeExecutable(root.appendingPathComponent("vendor/\(target)/bin/codex"))
            XCTAssertNil(CodexConnection.locateExecutable(override: broken.path, environment: [:], userDirectory: home, standardPaths: []))
        }
    }

    func testModernPackageCannotUseLeftoverLegacyLayout() throws {
        try withDirectory { home in
            let broken = try install(home: home, nodeVersion: "v25.2.1", codexVersion: "0.160.1", nativePresent: false, optionalPackage: true)
            let root = broken.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            #if arch(arm64)
            let target = "aarch64-apple-darwin"
            let platformPackage = "codex-darwin-arm64"
            #else
            let target = "x86_64-apple-darwin"
            let platformPackage = "codex-darwin-x64"
            #endif
            let targetRoot = root.appendingPathComponent("node_modules/@openai/\(platformPackage)/vendor/\(target)")
            try makeExecutable(targetRoot.appendingPathComponent("codex/codex"))
            XCTAssertNil(CodexConnection.locateExecutable(override: broken.path, environment: [:], userDirectory: home, standardPaths: []))
        }
    }
}

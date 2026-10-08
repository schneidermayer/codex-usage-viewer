import Foundation
import Darwin
import XCTest
@testable import CodexUsageViewerCore

final class CodexRPCFramerTests: XCTestCase {
    func testSplitUTF8AndMultipleLines() throws {
        var framer = CodexRPCFramer()
        let first = Data("{\"email\":\"café@example.com\"}".utf8)
        let split = first.firstIndex(of: 0xC3)! + 1
        XCTAssertTrue(try framer.append(first[..<split]).isEmpty)
        let frames = try framer.append(first[split...] + Data("\n\r\n{\"id\":2}\n".utf8))
        XCTAssertEqual(frames, [first, Data("{\"id\":2}".utf8)])
    }

    func testUnterminatedAndTerminatedOversizedFramesAreRejected() throws {
        var partial = CodexRPCFramer(maximumLineBytes: 8)
        XCTAssertThrowsError(try partial.append(Data(repeating: 0x61, count: 9)))
        var complete = CodexRPCFramer(maximumLineBytes: 8)
        XCTAssertThrowsError(try complete.append(Data("123456789\n".utf8)))
    }
}

@MainActor
final class CodexConnectionTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let executable: URL
        var accountRoot: URL { base.appendingPathComponent("CodexUsageViewer/Accounts", isDirectory: true) }

        @MainActor func connection(accountID: String = "account-1", timeout: TimeInterval = 10, loginTimeout: TimeInterval = 2) -> CodexConnection {
            CodexConnection(accountID: accountID, executableURL: executable, accountRoot: accountRoot,
                            requestTimeout: timeout, loginTimeout: loginTimeout)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private func fixture(_ mode: String) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codexusageviewer-rpc-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let executable = base.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import json, os, signal, subprocess, sys, time
        mode = "\(mode)"
        if mode == "ignore-term":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if mode in ("ignore-term", "descendant"):
            pids = [os.getpid()]
            if mode == "descendant":
                worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                pids.append(worker.pid)
            with open(os.path.join(os.path.dirname(sys.argv[0]), "worker-pids"), "w") as marker:
                json.dump(pids, marker)
        ready = False
        def send(payload):
            data = (json.dumps(payload, ensure_ascii=False) + "\\n").encode("utf-8")
            if mode == "fragmented":
                for i in range(0, len(data), 3):
                    os.write(1, data[i:i+3])
                    time.sleep(0.001)
            else:
                os.write(1, data)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            request_id = message.get("id")
            if mode.startswith("local-") or mode == "timeout":
                with open(os.path.join(os.path.dirname(sys.argv[0]), "rpc-methods"), "a") as transcript:
                    transcript.write(method + "\\n")
            if method == "initialize":
                send({"id": request_id, "result": {"userAgent": "fixture"}})
            elif method == "initialized":
                ready = True
            elif method == "account/read":
                storage_override = 'cli_auth_credentials_store="file"' in sys.argv
                expected_override = not mode.startswith("local-")
                if not ready or os.getcwd() != os.path.realpath(os.environ["CODEX_HOME"]) or storage_override != expected_override or message.get("params", {}).get("refreshToken") is not False:
                    send({"id": request_id, "error": {"code": -999, "message": "Isolation/handshake failure"}})
                elif mode == "malformed":
                    os.write(1, b"not-json\\n")
                elif mode == "error":
                    send({"id": request_id, "error": {"code": -32001, "message": "private token must not be surfaced"}})
                elif mode == "exit":
                    sys.exit(17)
                elif mode in ("timeout", "local-timeout"):
                    pass
                else:
                    email = os.path.basename(os.environ["CODEX_HOME"]) + "@example.com"
                    if mode == "fragmented":
                        email = "café@example.com"
                    send({"id": request_id, "result": {"account": {"type": "chatgpt", "email": email, "planType": "pro"}, "requiresOpenaiAuth": True}})
            elif method == "account/rateLimits/read":
                send({"id": request_id, "result": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 28, "windowDurationMins": 300, "resetsAt": 1900000000}, "secondary": None}}})
            elif method == "account/login/start":
                if mode in ("early-login", "failed-login"):
                    send({"method": "account/login/completed", "params": {"loginId": "fixture-login", "success": mode == "early-login"}})
                send({"id": request_id, "result": {"type": "chatgpt", "loginId": "fixture-login", "authUrl": "https://auth.openai.com/oauth/authorize?state=fixture"}})
            elif method == "account/login/cancel":
                with open(os.path.join(os.environ["CODEX_HOME"], "cancel-received"), "w") as marker:
                    marker.write("yes")
                send({"id": request_id, "result": {"status": "canceled"}})
            elif method == "account/logout":
                send({"id": request_id, "result": {}})
        while mode == "ignore-term":
            time.sleep(1)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return Fixture(base: base, executable: executable)
    }

    func testHandshakeAndFragmentedUnicodeResponse() async throws {
        let fixture = try fixture("fragmented")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        let identity = try await connection.account()
        XCTAssertEqual(identity?.email, "café@example.com")
        let limits = try await connection.readLimits()
        XCTAssertEqual(limits.rateLimits.primary?.usedPercent, 28)
        XCTAssertNil(limits.rateLimits.secondary)
    }

    private func writeNameFixture(at directory: URL, email: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = try JSONSerialization.data(withJSONObject: ["email": email, "name": "Alex Morgan"]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "fixture.\(payload).fixture"]])
        try data.write(to: directory.appendingPathComponent("auth.json"))
    }

    func testManagedAccountReadsMatchingProfileName() async throws {
        let fixture = try fixture("normal")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        try writeNameFixture(at: fixture.accountRoot.appendingPathComponent("account-1"), email: "account-1@example.com")
        let identity = try await connection.account()
        XCTAssertEqual(identity?.fullName, "Alex Morgan")
    }

    func testLocalIdentityOnlyReadsAccountWithoutChangingHomeOrAuthStorage() async throws {
        let fixture = try fixture("local-readonly")
        defer { fixture.remove() }
        let codexHome = fixture.base.appendingPathComponent("local-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let marker = codexHome.appendingPathComponent("unrelated-preference")
        try Data("unchanged".utf8).write(to: marker)
        try writeNameFixture(at: codexHome, email: "local-home@example.com")
        let identity = try await CodexConnection.readLocalIdentity(executableURL: fixture.executable, codexHome: codexHome, requestTimeout: 10)
        XCTAssertEqual(identity?.email, "local-home@example.com")
        XCTAssertNil(identity?.fullName, "Normal-home read-only detection must not inspect tokens for a name")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "unchanged")
        let attributes = try FileManager.default.attributesOfItem(atPath: codexHome.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: codexHome.path).sorted(), ["auth.json", "unrelated-preference"])
        let transcript = try String(contentsOf: fixture.base.appendingPathComponent("rpc-methods"), encoding: .utf8)
        XCTAssertEqual(transcript, "initialize\ninitialized\naccount/read\n")
    }

    func testLocalIdentityDoesNotCreateAMissingHome() async throws {
        let fixture = try fixture("local-readonly")
        defer { fixture.remove() }
        let missing = fixture.base.appendingPathComponent("missing-home")
        let identity = try await CodexConnection.readLocalIdentity(executableURL: fixture.executable, codexHome: missing)
        XCTAssertNil(identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("rpc-methods").path))
    }

    func testThreeAccountsUseDistinctRestrictedHomes() async throws {
        let fixture = try fixture("normal")
        let connections = CodexUsageViewerConstants.accountIDs.map { fixture.connection(accountID: $0) }
        defer { connections.forEach { $0.stop() }; fixture.remove() }
        for (index, connection) in connections.enumerated() {
            let identity = try await connection.account()
            XCTAssertEqual(identity?.email, "account-\(index + 1)@example.com")
            let folder = fixture.accountRoot.appendingPathComponent("account-\(index + 1)")
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testCredentialsAreRemovedFromInheritedEnvironment() {
        let url = URL(fileURLWithPath: "/opt/node/bin/codex")
        let folder = URL(fileURLWithPath: "/isolated/account-2")
        let environment = CodexConnection.isolatedEnvironment(executableURL: url, accountDirectory: folder, inherited: [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/example", "CODEX_HOME": "/existing/private",
            "OPENAI_API_KEY": "fixture-secret", "CODEX_ACCESS_TOKEN": "fixture-secret", "CHATGPT_TOKEN": "fixture-secret",
            "AZURE_OPENAI_API_KEY": "fixture-secret", "ACCESS_TOKEN": "fixture-secret", "NODE_OPTIONS": "--require unsafe.js"
        ])
        XCTAssertEqual(environment["CODEX_HOME"], folder.path)
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["PATH"]?.components(separatedBy: ":").first, "/opt/node/bin")
        for name in ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "CHATGPT_TOKEN", "AZURE_OPENAI_API_KEY", "ACCESS_TOKEN", "NODE_OPTIONS"] {
            XCTAssertNil(environment[name])
        }
    }

    func testLoginURLAllowsOfficialHostsAndRejectsSpoofs() {
        for url in ["https://auth.openai.com/oauth/authorize?state=fixture", "https://chatgpt.com/auth/login", "https://auth.chatgpt.com/login"] {
            XCTAssertNotNil(CodexConnection.validatedLoginURL(url))
        }
        for url in ["http://auth.openai.com/login", "https://auth.openai.com.evil.test/login", "https://evilchatgpt.com/login",
                    "https://chatgpt.com@evil.test/login", "https://user:password@auth.openai.com/login", "https://chatgpt.com:8080/login", "not a URL"] {
            XCTAssertNil(CodexConnection.validatedLoginURL(url))
        }
    }

    func testLoginNotificationBeforeStartResponseIsBuffered() async throws {
        let fixture = try fixture("early-login")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        let login = try await connection.beginLogin()
        XCTAssertEqual(login.loginId, "fixture-login")
        try await connection.waitForLogin(loginID: login.loginId)
    }

    func testFailedEarlyLoginIsNotMistakenForSuccess() async throws {
        let fixture = try fixture("failed-login")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        let login = try await connection.beginLogin()
        do {
            try await connection.waitForLogin(loginID: login.loginId)
            XCTFail("Expected failed login")
        } catch { XCTAssertEqual(error as? CodexConnectionError, .loginFailed) }
    }

    func testLoginTimeoutCompletesWaiter() async throws {
        let fixture = try fixture("normal")
        let connection = fixture.connection(loginTimeout: 0.08)
        defer { connection.stop(); fixture.remove() }
        let login = try await connection.beginLogin()
        do {
            try await connection.waitForLogin(loginID: login.loginId)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? CodexConnectionError, .loginTimedOut) }
        let marker = fixture.accountRoot.appendingPathComponent("account-1/cancel-received")
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Timed-out browser login must be canceled at the server")
    }

    func testRPCErrorDoesNotExposeServerErrorText() async throws {
        let fixture = try fixture("error")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        do {
            _ = try await connection.account()
            XCTFail("Expected RPC error")
        } catch {
            XCTAssertEqual(error as? CodexConnectionError, .requestFailed(-32001))
            XCTAssertFalse(error.localizedDescription.contains("private token"))
        }
    }

    func testMalformedResponseClosesConnection() async throws {
        let fixture = try fixture("malformed")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        do {
            _ = try await connection.account()
            XCTFail("Expected protocol failure")
        } catch { XCTAssertEqual(error as? CodexConnectionError, .invalidResponse) }
    }

    func testProcessExitFailsPendingRequest() async throws {
        let fixture = try fixture("exit")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        do {
            _ = try await connection.account()
            XCTFail("Expected process failure")
        } catch { XCTAssertEqual(error as? CodexConnectionError, .stopped) }
    }

    func testRequestTimeoutCompletesPendingRequest() async throws {
        let fixture = try fixture("timeout")
        let connection = fixture.connection(timeout: 0.15)
        defer { connection.stop(); fixture.remove() }
        do {
            _ = try await connection.account()
            XCTFail("Expected request timeout")
        } catch { XCTAssertEqual(error as? CodexConnectionError, .timedOut) }
    }

    func testCancellationCompletesPendingRequest() async throws {
        let fixture = try fixture("timeout")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        // Complete startup before canceling an in-flight account request.
        _ = try await connection.readLimits()
        let task = Task { try await connection.account() }
        let transcript = fixture.base.appendingPathComponent("rpc-methods")
        func accountRequestReceived() -> Bool {
            (try? String(contentsOf: transcript, encoding: .utf8).contains("account/read\n")) == true
        }
        for _ in 0..<300 where !accountRequestReceived() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(accountRequestReceived())
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStoppedConnectionCanRestart() async throws {
        let fixture = try fixture("normal")
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        _ = try await connection.account()
        connection.stop()
        let identity = try await connection.account()
        XCTAssertEqual(identity?.type, "chatgpt")
    }

    func testStopTerminatesWorkerDescendants() async throws {
        try await checkStoppedWorkers(mode: "descendant", expectedWorkerCount: 2)
    }

    func testStopEscalatesWhenWorkerIgnoresTermination() async throws {
        try await checkStoppedWorkers(mode: "ignore-term", expectedWorkerCount: 1)
    }

    private func checkStoppedWorkers(mode: String, expectedWorkerCount: Int) async throws {
        let fixture = try fixture(mode)
        let connection = fixture.connection()
        var pids: [pid_t] = []
        defer {
            connection.stop()
            // Bound the fixture lifetime even if an assertion fails.
            pids.filter { kill($0, 0) == 0 }.forEach { _ = kill($0, SIGKILL) }
            fixture.remove()
        }
        _ = try await connection.account()
        pids = try JSONDecoder().decode([pid_t].self, from: Data(contentsOf: fixture.base.appendingPathComponent("worker-pids")))
        XCTAssertEqual(pids.count, expectedWorkerCount)
        connection.stop()
        for _ in 0..<400 where pids.contains(where: { kill($0, 0) == 0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 }, "Stopping a connection must also stop its workers")
    }

    func testAccountPathTraversalIsRejected() async throws {
        let fixture = try fixture("normal")
        let connection = fixture.connection(accountID: "../../existing")
        defer { connection.stop(); fixture.remove() }
        do {
            _ = try await connection.account()
            XCTFail("Expected invalid account")
        } catch { XCTAssertEqual(error as? CodexConnectionError, .invalidAccount) }
    }

    func testAccountDirectorySymlinkIsRejected() async throws {
        let fixture = try fixture("normal")
        try FileManager.default.createDirectory(at: fixture.accountRoot, withIntermediateDirectories: true)
        let outside = fixture.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.accountRoot.appendingPathComponent("account-1"), withDestinationURL: outside)
        let connection = fixture.connection()
        defer { connection.stop(); fixture.remove() }
        do {
            _ = try await connection.account()
            XCTFail("Expected unsafe account folder rejection")
        } catch { XCTAssertEqual(error as? CodexConnectionError, .invalidAccount) }
    }
}

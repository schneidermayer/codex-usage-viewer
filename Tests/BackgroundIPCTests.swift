import Foundation
import XCTest
@testable import CodexUsageViewerCore

@MainActor
private final class FixtureBackgroundConnection: BackgroundIPCConnection {
    var onFailure: ((Error) -> Void)?
    var requests: [Data] = []
    var replies: [@MainActor @Sendable (Result<Data, Error>) -> Void] = []
    var didSend: (() -> Void)?
    var invalidated = false

    func send(_ request: Data, reply: @escaping @MainActor @Sendable (Result<Data, Error>) -> Void) {
        requests.append(request)
        replies.append(reply)
        didSend?()
    }

    func invalidate() { invalidated = true }
}

@MainActor
final class BackgroundIPCTests: XCTestCase {
    private func response() throws -> Data {
        try JSONEncoder().encode(BackgroundState(
            snapshot: .preview, isRefreshing: false, busyAccountIDs: [], login: nil,
            availableCodex: true, localCodexStatus: nil, errorMessage: nil,
            codexPath: "/fixture/codex", helperVersion: "fixture-version"))
    }

    func testCommandsAndVersionCrossTheConnectionWithoutStartingAHelper() async throws {
        let connection = FixtureBackgroundConnection()
        let expected = try response()
        connection.didSend = { connection.replies.last?(.success(expected)) }
        let client = BackgroundClient(makeConnection: { connection })
        defer { client.shutdown() }
        let commands: [BackgroundCommand] = [
            .state, .refresh, .connect(accountID: "account-2"), .cancelLogin,
            .disconnect(accountID: "account-3"), .setExecutable(path: "/fixture/codex")
        ]
        for command in commands {
            let state = try await client.send(command)
            XCTAssertEqual(state.helperVersion, "fixture-version")
            XCTAssertEqual(state.snapshot.accounts.first?.email, "personal@example.com")
        }
        XCTAssertEqual(try connection.requests.map { try JSONDecoder().decode(BackgroundCommand.self, from: $0) }, commands)
    }

    func testInterruptionFailsPendingRequestAndNextRequestReconnects() async throws {
        let firstConnection = FixtureBackgroundConnection()
        let secondConnection = FixtureBackgroundConnection()
        var connections = [firstConnection, secondConnection]
        let client = BackgroundClient(makeConnection: { connections.removeFirst() })
        defer { client.shutdown() }
        let sent = expectation(description: "first request sent")
        firstConnection.didSend = { sent.fulfill() }
        let first = Task { try await client.send(.state) }
        await fulfillment(of: [sent], timeout: 1)
        let staleFailure = firstConnection.onFailure
        firstConnection.onFailure?(BackgroundIPCError.interrupted)
        do {
            _ = try await first.value
            XCTFail("Interrupted request must fail")
        } catch { XCTAssertEqual(error as? BackgroundIPCError, .interrupted) }
        XCTAssertTrue(firstConnection.invalidated)

        let reconnected = expectation(description: "second connection sent")
        secondConnection.didSend = { reconnected.fulfill() }
        let second = Task { try await client.send(.state) }
        await fulfillment(of: [reconnected], timeout: 1)
        staleFailure?(BackgroundIPCError.unavailable)
        firstConnection.replies[0](.success(try response()))
        secondConnection.replies[0](.success(try response()))
        let state = try await second.value
        XCTAssertEqual(state.helperVersion, "fixture-version")
        XCTAssertFalse(secondConnection.invalidated)
    }

    func testTimeoutIsBoundedAndLateRepliesDoNotResumeAgain() async throws {
        let connection = FixtureBackgroundConnection()
        let client = BackgroundClient(requestTimeout: 0.01, makeConnection: { connection })
        defer { client.shutdown() }
        do {
            _ = try await client.send(.disconnect(accountID: "account-1"))
            XCTFail("Unanswered request must time out")
        } catch { XCTAssertEqual(error as? BackgroundIPCError, .timedOut) }
        XCTAssertTrue(connection.invalidated)
        connection.replies[0](.success(try response()))
    }

    func testCancellationOnlyCancelsWaitingAndDoesNotSendALogout() async throws {
        let connection = FixtureBackgroundConnection()
        let client = BackgroundClient(makeConnection: { connection })
        defer { client.shutdown() }
        let sent = expectation(description: "request sent")
        connection.didSend = { sent.fulfill() }
        let request = Task { try await client.send(.connect(accountID: "account-1")) }
        await fulfillment(of: [sent], timeout: 1)
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Cancelled wait must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(connection.invalidated)
        XCTAssertEqual(connection.requests.count, 1)
        connection.replies[0](.success(try response()))
    }

    func testShutdownFinishesAllPendingRequestsAndRejectsNewRequests() async throws {
        let connection = FixtureBackgroundConnection()
        let client = BackgroundClient(makeConnection: { connection })
        let sent = expectation(description: "both requests sent")
        sent.expectedFulfillmentCount = 2
        connection.didSend = { sent.fulfill() }
        let first = Task { try await client.send(.state) }
        let second = Task { try await client.send(.refresh) }
        await fulfillment(of: [sent], timeout: 1)
        client.shutdown()
        for request in [first, second] {
            do {
                _ = try await request.value
                XCTFail("Stopped client must finish outstanding work")
            } catch { XCTAssertEqual(error as? BackgroundIPCError, .stopped) }
        }
        do {
            _ = try await client.send(.state)
            XCTFail("Stopped client must reject new work")
        } catch { XCTAssertEqual(error as? BackgroundIPCError, .stopped) }
        XCTAssertTrue(connection.invalidated)
        XCTAssertEqual(connection.requests.count, 2)
    }

    func testInvalidReplyDoesNotExposeRawPayload() async throws {
        let connection = FixtureBackgroundConnection()
        connection.didSend = {
            connection.replies.last?(.success(Data("private-fixture-payload".utf8)))
        }
        let client = BackgroundClient(makeConnection: { connection })
        defer { client.shutdown() }
        do {
            _ = try await client.send(.state)
            XCTFail("Malformed response must fail")
        } catch {
            XCTAssertEqual(error as? BackgroundIPCError, .invalidResponse)
            XCTAssertFalse(error.localizedDescription.contains("private-fixture-payload"))
        }
    }
}

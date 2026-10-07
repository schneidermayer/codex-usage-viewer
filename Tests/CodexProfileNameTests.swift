import Foundation
import XCTest
@testable import CodexUsageViewerCore

final class CodexProfileNameTests: XCTestCase {
    private func authData(claims: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // Synthetic, deliberately unsigned fixture. Never used for authentication.
        return try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "fixture-header.\(payload).fixture-signature"]])
    }

    func testNameClaimRequiresMatchingOfficialAccountEmail() throws {
        let data = try authData(claims: ["email": "person@fixture.test", "name": "  José  Müller\nSmith  "])
        XCTAssertEqual(CodexProfileName.fullName(fromAuthData: data, matchingEmail: "PERSON@FIXTURE.TEST"), "José Müller Smith")
        XCTAssertNil(CodexProfileName.fullName(fromAuthData: data, matchingEmail: "different@fixture.test"))
        XCTAssertNil(CodexProfileName.fullName(fromAuthData: data, matchingEmail: ""))
    }

    func testNamespacedProfileClaimsAreBoundToAccountEmail() throws {
        let data = try authData(claims: ["https://api.openai.com/profile": ["email": "person@fixture.test", "name": "Alex Morgan"]])
        XCTAssertEqual(CodexProfileName.fullName(fromAuthData: data, matchingEmail: "person@fixture.test"), "Alex Morgan")
        let mixed = try authData(claims: ["email": "person@fixture.test", "https://api.openai.com/profile": ["email": "someone-else@fixture.test", "name": "Different person"]])
        XCTAssertNil(CodexProfileName.fullName(fromAuthData: mixed, matchingEmail: "person@fixture.test"))
    }

    func testMissingNameIsNotInferredFromEmailOrGivenNames() throws {
        for claims: [String: Any] in [["email": "alex.morgan@fixture.test"],
                                     ["email": "alex.morgan@fixture.test", "given_name": "Alex", "family_name": "Morgan"],
                                     ["name": "Alex Morgan"]] {
            XCTAssertNil(CodexProfileName.fullName(fromAuthData: try authData(claims: claims), matchingEmail: "alex.morgan@fixture.test"))
        }
    }

    func testMalformedAndExcessiveProfileDataIsRejected() throws {
        for value in ["not-json", "{}", #"{"tokens":{"id_token":"not-a-jwt"}}"#,
                      #"{"tokens":{"id_token":"header.%%%%.signature"}}"#] {
            XCTAssertNil(CodexProfileName.fullName(fromAuthData: Data(value.utf8), matchingEmail: "person@fixture.test"))
        }
        XCTAssertNil(CodexProfileName.fullName(fromAuthData: try authData(claims: ["email": "person@fixture.test", "name": String(repeating: "a", count: 161)]), matchingEmail: "person@fixture.test"))
        XCTAssertNil(CodexProfileName.fullName(fromAuthData: Data(repeating: 0x41, count: 1_048_577), matchingEmail: "person@fixture.test"))
    }

    func testOlderSnapshotDecodesAndIgnoresLegacyCustomLabel() throws {
        let account = try JSONDecoder().decode(AccountSnapshot.self, from: Data(#"{"id":"account-2","name":"My nickname","email":"person@fixture.test","state":"connected","buckets":[]}"#.utf8))
        XCTAssertNil(account.fullName)
        XCTAssertEqual(account.displayName, "person@fixture.test")
        var empty = account
        empty.email = nil
        XCTAssertEqual(empty.displayName, "Account 2")
        empty.fullName = "Alex Morgan"
        XCTAssertEqual(empty.displayName, "Alex Morgan")
    }

    func testNameLookupRejectsAuthFileSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-name-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("fixture.json")
        try authData(claims: ["email": "person@fixture.test", "name": "Alex Morgan"]).write(to: actual)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("auth.json"), withDestinationURL: actual)
        XCTAssertNil(CodexProfileName.readFromAppOwnedAccount(directory: root, matchingEmail: "person@fixture.test"))
    }
}

import Foundation
import XCTest
@testable import CodexUsageViewerCore

final class CodexChromeProfileTests: XCTestCase {
    func testOnlyDisplayNamesAndSafeProfileDirectoriesAreParsed() {
        let data = Data(#"{"profile":{"info_cache":{"Profile 2":{"name":"Studio","user_name":"ignored@example.com","gaia_id":"ignored"},"Default":{"name":"Personal"},"Profile 1":{"name":""},"../outside":{"name":"Unsafe"},"Profile 3/other":{"name":"Unsafe"}}},"os_crypt":{"encrypted_key":"ignored"}}"#.utf8)
        let profiles = ChromeProfile.parseMetadata(data)
        XCTAssertEqual(profiles, [ChromeProfile(id: "Default", name: "Personal"),
                                  ChromeProfile(id: "Profile 1", name: "Profile 1"),
                                  ChromeProfile(id: "Profile 2", name: "Studio")])
    }

    func testMissingOrMalformedMetadataReturnsNoProfiles() {
        for value in ["not-json", "{}", #"{"profile":{}}"#, #"{"profile":{"info_cache":null}}"#] {
            XCTAssertTrue(ChromeProfile.parseMetadata(Data(value.utf8)).isEmpty)
        }
    }

    func testProfileDirectoryValidationRejectsArgumentsAndTraversal() {
        for name in ["Default", "Profile 1", "Profile 127"] {
            XCTAssertTrue(ChromeProfile.isValidDirectory(name))
        }
        for name in ["", ".", "..", "../Default", "Profile 1/other", "--incognito", "Default\n", "Profile 1 --incognito", "Profile -1"] {
            XCTAssertFalse(ChromeProfile.isValidDirectory(name))
        }
    }
}

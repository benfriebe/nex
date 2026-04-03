@testable import Nex
import XCTest

@MainActor
final class HelpDataTests: XCTestCase {
    func testGitHubURLIsValid() {
        XCTAssertNotNil(HelpData.githubURL.host)
    }
}

import XCTest
@testable import BridgeCore

final class SkillPortraitTests: XCTestCase {
    func testStableSemanticDefaultsAndPrecedence() {
        let fixtures: [(String, SkillPortrait)] = [
            ("release-sample-site", .release), ("security-diff-scan", .review),
            ("search-sample-events", .research), ("figma-design-to-code", .design),
            ("openai-docs", .knowledge), ("skill-creator", .build),
            ("release-test-runner", .release), ("PREVIEW-tools", .build),
            ("", .build), ("未知", .build), ("../search/events", .research),
        ]
        for (name, expected) in fixtures {
            XCTAssertEqual(SkillPortrait.automatic(for: name), expected, name)
            XCTAssertEqual(SkillPortrait.resolve(name: name, override: "invalid"), expected)
        }
    }
    func testManualOverrideAndReset() {
        for portrait in SkillPortrait.allCases {
            XCTAssertEqual(SkillPortrait.resolve(name: "release", override: portrait.rawValue), portrait)
        }
        XCTAssertEqual(SkillPortrait.resolve(name: "release", override: ""), .release)
    }
}

import AppKit
import XCTest
import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class SkillPortraitArtworkTests: XCTestCase {
    func testEveryPortraitIsSmallSquareWithRealAlphaAndSafeMargins() throws {
        var totalBytes = 0
        for portrait in SkillPortrait.allCases {
            let url = try XCTUnwrap(SkillPortraitArtwork.url(for: portrait))
            let data = try Data(contentsOf: url)
            totalBytes += data.count
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, 256)
            XCTAssertEqual(bitmap.pixelsHigh, 256)
            XCTAssertTrue(bitmap.hasAlpha)
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<256 { for x in 0..<256 {
                let alpha = try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
                if x < 16 || x >= 240 || y < 16 || y >= 240 { XCTAssertEqual(alpha, 0, accuracy: 0.001) }
                if alpha > 0.5 { xs.append(x); ys.append(y) }
            } }
            XCTAssertFalse(xs.isEmpty)
            let extent = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            XCTAssertTrue((210...220).contains(extent), "\(portrait): extent \(extent)")
            let first = try XCTUnwrap(SkillPortraitArtwork.image(for: portrait))
            XCTAssertTrue(first === SkillPortraitArtwork.image(for: portrait))
            XCTAssertFalse(first.isTemplate)
        }
        XCTAssertLessThan(totalBytes, 1_000_000, "Do not ship generation-sized artwork")
    }
}

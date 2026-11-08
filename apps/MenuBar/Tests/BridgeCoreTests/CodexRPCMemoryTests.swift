import Foundation
import XCTest
@testable import BridgeCore

final class CodexRPCMemoryTests: XCTestCase {
    func testFragmentedFramesPreserveUTF8BytesAndFollowingMessages() throws {
        var reader = CodexRPCFrameBuffer(maximumBytes: 64)
        let first = Data("{\"text\":\"สวัสดี\"}".utf8)
        var received: [Data] = []
        for byte in first + Data([10]) + Data("{}\n".utf8) {
            received += try reader.append(Data([byte]))
        }
        XCTAssertEqual(received, [first, Data("{}".utf8)])
        XCTAssertEqual(reader.pending.count, 0)
    }

    func testOversizedUnterminatedFrameReleasesCarryBeforeDecode() throws {
        var reader = CodexRPCFrameBuffer(maximumBytes: 32)
        for _ in 0..<4 { XCTAssertTrue(try reader.append(Data(repeating: 65, count: 8)).isEmpty) }
        XCTAssertEqual(reader.pending.count, 32)
        XCTAssertThrowsError(try reader.append(Data([65])))
        XCTAssertEqual(reader.pending.count, 0)
    }

    func testFrameCapAppliesToOneFrameNotCumulativeTraffic() throws {
        var reader = CodexRPCFrameBuffer(maximumBytes: 8)
        for _ in 0..<1_000 {
            XCTAssertEqual(try reader.append(Data("12345678\n".utf8)), [Data("12345678".utf8)])
        }
        XCTAssertThrowsError(try reader.append(Data("123456789\n".utf8)))
    }
}

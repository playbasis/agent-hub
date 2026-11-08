import Foundation
import XCTest

final class PackagingScriptTests: XCTestCase {
    func testIsolatedPackagingFailureAndRecoveryFixtures() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("scripts/tests/packaging-fixtures.sh").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertTrue(message.contains("Packaging fixtures passed: 13"), message)
    }
}

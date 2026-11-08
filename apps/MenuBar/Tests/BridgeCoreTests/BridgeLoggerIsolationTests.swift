import Foundation
import XCTest
@testable import BridgeCore

final class BridgeLoggerIsolationTests: XCTestCase {
    func testDefaultSharedPathRecognizesTestBundleExecutablesButNotLookalikes() {
        let temporary = URL(fileURLWithPath: "/tmp/logger-isolation-fixture", isDirectory: true)
        let production = BridgePaths.logs.appendingPathComponent("bridge.jsonl")
        for path in ["/tmp/HubTests.xctest/Contents/MacOS/HubTests", "/tmp/HubTests.xctest", "/tmp/HubTests.XCTEST/Contents/MacOS/HubTests"] {
            let file = BridgeLogger.defaultSharedFile(executablePath: path, temporaryDirectory: temporary, processID: 42)
            XCTAssertNotEqual(file, production)
            XCTAssertTrue(file.path.hasPrefix(temporary.path + "/ClaudeCodexBridgeTests-42-"))
            XCTAssertEqual(file.lastPathComponent, "bridge.jsonl")
        }
        for path in ["/Applications/ClaudeCodexBridge.app/Contents/MacOS/ClaudeCodexBridgeMenuBar", "/usr/bin/xctest", "/tmp/HubTests.xctest-helper/bridge", "/tmp/.xctest-cache/bridge"] {
            XCTAssertEqual(BridgeLogger.defaultSharedFile(executablePath: path, temporaryDirectory: temporary, processID: 42), production)
        }
    }

    func testSeparateTestLoggerDefaultsUseProcessPrivateUUIDDirectories() {
        let temporary = FileManager.default.temporaryDirectory
        let first = BridgeLogger.defaultSharedFile(executablePath: "/tmp/Tests.xctest", temporaryDirectory: temporary, processID: 42)
        let second = BridgeLogger.defaultSharedFile(executablePath: "/tmp/Tests.xctest", temporaryDirectory: temporary, processID: 42)
        let otherProcess = BridgeLogger.defaultSharedFile(executablePath: "/tmp/Tests.xctest", temporaryDirectory: temporary, processID: 43)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, otherProcess)
        let directory = first.deletingLastPathComponent().lastPathComponent
        XCTAssertNotNil(UUID(uuidString: String(directory.dropFirst("ClaudeCodexBridgeTests-42-".count))))
    }

    func testActualXCTestSharedLoggerWritesOnlyInsidePrivateTemporaryDirectory() async throws {
        let file = await BridgeLogger.shared.file
        let production = BridgePaths.logs.appendingPathComponent("bridge.jsonl")
        guard file != production, file.deletingLastPathComponent() != BridgePaths.logs,
              file.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            XCTFail("The test process must never append fixtures to the user's runtime log")
            return // A failed isolation assertion must never perform the write.
        }
        let marker = "Logger isolation fixture \(UUID().uuidString)"
        await BridgeLogger.shared.log("INFO", marker)
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains(marker))
        let filePermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        let directoryPermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
        // Do not remove the shared directory: other tests in this process may
        // still be writing to it. The OS owns temporary-directory cleanup.
    }

    func testExplicitLoggerFileRemainsHonoredAndAppendOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExplicitLoggerFixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("custom.jsonl")
        let logger = BridgeLogger(file: file)
        let actual = await logger.file
        XCTAssertEqual(actual, file)
        await logger.log("INFO", "First fixture")
        let first = try Data(contentsOf: file)
        await logger.log("INFO", "Second fixture")
        let appended = try Data(contentsOf: file)
        XCTAssertTrue(appended.starts(with: first))
        let records = await logger.recent(limit: 10)
        XCTAssertEqual(records.count, 2)
    }
}

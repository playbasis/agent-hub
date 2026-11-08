import Foundation
import XCTest

/// Offline fake-transport checks only: never discover a key or call JEV.
final class JevTelemetryPilotTests: XCTestCase {
    func testPrivateOfflineClassificationPilotFixtures() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "unittest", "discover", "-s", root.appendingPathComponent("scripts/tests").path,
                             "-p", "test_jev_telemetry_pilot.py"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TYPESAFE_API_KEY")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertTrue(message.contains("OK"), message)
    }
}

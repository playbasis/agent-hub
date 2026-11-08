import Darwin
import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

/// Notification names are unique per test so a running Agent Hub never sees
/// them; the lock file lives in a temporary directory.
@MainActor
final class SingleInstanceHandOffTests: XCTestCase {
    private func lockFile() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HandOff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("menubar.lock").path
    }

    private func names() -> (Notification.Name, Notification.Name) {
        let id = UUID().uuidString
        return (Notification.Name("test.activate.\(id)"), Notification.Name("test.ack.\(id)"))
    }

    func testLaunchTakesOverWhenTheRunningInstanceFinishesQuitting() throws {
        let path = try lockFile()
        let holder = open(path, O_CREAT | O_RDWR, 0o644)
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let owner = SingleInstanceGuard.InstanceOwner(executablePath: "/fixture/AgentHub")
        let ownerData = try JSONEncoder().encode(owner)
        XCTAssertEqual(ownerData.withUnsafeBytes { Darwin.pwrite(holder, $0.baseAddress, $0.count, 0) }, ownerData.count)
        let contender = open(path, O_CREAT | O_RDWR, 0o644)
        defer { close(contender) }
        // The "running instance" quits a moment later and releases its lock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { close(holder) }
        let (activation, ack) = names()
        XCTAssertEqual(SingleInstanceGuard.handOff(lockFD: contender, timeout: 3, activation: activation, acknowledgement: ack), .acquired)
    }

    func testLaunchExitsAsSoonAsTheRunningInstanceAcknowledges() throws {
        let path = try lockFile()
        let holder = open(path, O_CREAT | O_RDWR, 0o644)
        defer { close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let owner = SingleInstanceGuard.InstanceOwner(executablePath: "/fixture/AgentHub")
        let data = try JSONEncoder().encode(owner)
        XCTAssertEqual(data.withUnsafeBytes { Darwin.pwrite(holder, $0.baseAddress, $0.count, 0) }, data.count)
        let contender = open(path, O_CREAT | O_RDWR, 0o644)
        defer { close(contender) }
        let (activation, ack) = names()
        let center = DistributedNotificationCenter.default()
        let responder = center.addObserver(forName: activation, object: nil, queue: nil) { request in
            center.postNotificationName(ack, object: nil, userInfo: request.userInfo, deliverImmediately: true)
        }
        defer { center.removeObserver(responder) }
        let started = Date()
        XCTAssertEqual(SingleInstanceGuard.handOff(lockFD: contender, timeout: 5, activation: activation, acknowledgement: ack), .runningInstanceActivated)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "a healthy instance answers quickly")
    }

    func testUnresponsiveInstanceTimesOutWithoutStealingTheLock() throws {
        let path = try lockFile()
        let holder = open(path, O_CREAT | O_RDWR, 0o644)
        defer { close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let contender = open(path, O_CREAT | O_RDWR, 0o644)
        defer { close(contender) }
        let (activation, ack) = names()
        XCTAssertEqual(SingleInstanceGuard.handOff(lockFD: contender, timeout: 0.4, activation: activation, acknowledgement: ack), .timedOut)
    }
}

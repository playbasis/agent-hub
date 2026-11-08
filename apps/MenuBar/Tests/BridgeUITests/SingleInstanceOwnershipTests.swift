import Darwin
import Foundation
import XCTest
@testable import ClaudeCodexBridgeMenuBar

@MainActor
final class SingleInstanceOwnershipTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HubOwnership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testOwnedRegularFileIsPrivateAndCloseOnExecAndStaleTextDoesNotBlock() throws {
        let path = try directory().appendingPathComponent("menubar.lock").path
        try Data("old or malformed metadata".utf8).write(to: URL(fileURLWithPath: path))
        let lease = try SingleInstanceGuard.InstanceLease(path: path)
        XCTAssertNil(lease.readOwner())
        let owner = SingleInstanceGuard.InstanceOwner(executablePath: "/fixture/Hub")
        XCTAssertTrue(try lease.acquire(owner: owner))
        XCTAssertEqual(lease.readOwner(), owner)
        var info = stat()
        XCTAssertEqual(fstat(lease.fd, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertNotEqual(fcntl(lease.fd, F_GETFD) & FD_CLOEXEC, 0)
    }

    func testDirectoriesSymlinksAndHardlinksAreRejectedWithoutDeletingTargets() throws {
        let root = try directory()
        XCTAssertThrowsError(try SingleInstanceGuard.InstanceLease(path: root.path))
        let target = root.appendingPathComponent("target")
        try Data("preserve".utf8).write(to: target)
        let symbolic = root.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
        XCTAssertThrowsError(try SingleInstanceGuard.InstanceLease(path: symbolic.path))
        let hard = root.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: target, to: hard)
        XCTAssertThrowsError(try SingleInstanceGuard.InstanceLease(path: hard.path))
        XCTAssertEqual(try String(contentsOf: target), "preserve")
    }

    func testReplacedLockPathCannotAcquireDifferentInodeSilently() throws {
        let root = try directory()
        let path = root.appendingPathComponent("menubar.lock")
        let lease = try SingleInstanceGuard.InstanceLease(path: path.path)
        try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("original"))
        try Data().write(to: path)
        XCTAssertThrowsError(try lease.acquire(owner: .init(executablePath: "/fixture/Hub")))
    }

    func testAcknowledgementRequiresExactOwnerRequestAndProductionLease() throws {
        let owner = SingleInstanceGuard.InstanceOwner(executablePath: "/fixture/Hub")
        let request = UUID().uuidString
        let notification = Notification(name: .init("fixture.activate"), userInfo: owner.payload(requestID: request))
        let accepted = SingleInstanceGuard.activationAcknowledgement(for: notification, owner: owner, isQuitRequested: false)
        XCTAssertTrue(owner.matches(accepted, requestID: request))
        XCTAssertFalse(owner.matches(accepted, requestID: UUID().uuidString))
        XCTAssertNil(SingleInstanceGuard.activationAcknowledgement(for: notification, owner: nil, isQuitRequested: false), "A renderer without a production lease must never answer")
        XCTAssertNil(SingleInstanceGuard.activationAcknowledgement(for: notification, owner: owner, isQuitRequested: true))
        let other = SingleInstanceGuard.InstanceOwner(executablePath: "/fixture/old-copy")
        XCTAssertNil(SingleInstanceGuard.activationAcknowledgement(for: notification, owner: other, isQuitRequested: false))
        XCTAssertNil(SingleInstanceGuard.activationAcknowledgement(for: Notification(name: notification.name), owner: owner, isQuitRequested: false))
    }

    func testEmptyDiagnosticFlagsDoNotBypassProductionOwnership() {
        XCTAssertFalse(SingleInstanceGuard.isDiagnosticLaunch([:]))
        XCTAssertFalse(SingleInstanceGuard.isDiagnosticLaunch(["BRIDGE_UI_INTERACTION_REPORT": "  "]))
        XCTAssertTrue(SingleInstanceGuard.isDiagnosticLaunch(["BRIDGE_UI_INTERACTION_REPORT": "/tmp/fixture.json"]))
        XCTAssertTrue(SingleInstanceGuard.isDiagnosticLaunch(["BRIDGE_UI_PREVIEW": "1"]))
    }

    func testQuitIsMarkedSynchronouslyWithoutRunningShutdownOrTouchingLiveApp() {
        let model = BridgeViewModel(automaticallyConnect: false)
        XCTAssertTrue(model.beginQuitRequest())
        XCTAssertTrue(model.isQuitRequested)
        XCTAssertFalse(model.isShuttingDown, "This fixture does not schedule cleanup or terminate an app")
        XCTAssertFalse(model.beginQuitRequest())
    }

    func testInvalidDescriptorAndUncorrelatedAcknowledgementCannotReportSuccess() throws {
        XCTAssertEqual(SingleInstanceGuard.handOff(lockFD: -1, timeout: 0.1), .failed)
        XCTAssertEqual(SingleInstanceGuard.handOff(lockFD: -1, timeout: .infinity), .timedOut)
        let path = try directory().appendingPathComponent("menubar.lock").path
        let holder = try SingleInstanceGuard.InstanceLease(path: path)
        let owner = SingleInstanceGuard.InstanceOwner(executablePath: "/fixture/Hub")
        XCTAssertTrue(try holder.acquire(owner: owner))
        let contender = try SingleInstanceGuard.InstanceLease(path: path)
        let activation = Notification.Name("fixture.activate.\(UUID().uuidString)")
        let acknowledgement = Notification.Name("fixture.ack.\(UUID().uuidString)")
        let center = DistributedNotificationCenter.default()
        let responder = center.addObserver(forName: activation, object: nil, queue: nil) { _ in
            center.postNotificationName(acknowledgement, object: nil, userInfo: owner.payload(requestID: UUID().uuidString), deliverImmediately: true)
        }
        defer { center.removeObserver(responder); withExtendedLifetime(holder) {} }
        XCTAssertEqual(SingleInstanceGuard.handOff(lockFD: contender.fd, timeout: 0.2, activation: activation, acknowledgement: acknowledgement), .timedOut)
        XCTAssertFalse(try contender.acquire(owner: .init(executablePath: "/fixture/second")))
    }
}

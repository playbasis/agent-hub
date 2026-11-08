import AppKit
import BridgeCore
import CoreFoundation
import Darwin
import Foundation

/// Kernel ownership, not a PID file, determines which production instance may
/// run. Owner metadata only addresses activation requests; stale metadata can
/// never prevent acquiring a lock released by a crash.
@MainActor
enum SingleInstanceGuard {
    static let activationNotification = BridgeLifecycleNotifications.activateApp
    private static var lease: InstanceLease?
    static var productionOwner: InstanceOwner? { lease?.owner }

    struct InstanceOwner: Codable, Equatable, Sendable {
        let version: Int
        let instanceID: String
        let pid: Int32
        let executablePath: String

        init(instanceID: String = UUID().uuidString, pid: Int32 = getpid(), executablePath: String = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]) {
            version = BridgeLifecycleNotifications.protocolVersion
            self.instanceID = instanceID
            self.pid = pid
            self.executablePath = executablePath
        }

        var isValid: Bool {
            version == BridgeLifecycleNotifications.protocolVersion && UUID(uuidString: instanceID) != nil
                && pid > 0 && executablePath.hasPrefix("/") && executablePath.utf8.count <= 4096
        }

        func payload(requestID: String) -> [String: Any] {
            [BridgeLifecycleNotifications.protocolVersionKey: version,
             BridgeLifecycleNotifications.requestIDKey: requestID,
             BridgeLifecycleNotifications.instanceIDKey: instanceID,
             BridgeLifecycleNotifications.ownerPIDKey: Int(pid),
             BridgeLifecycleNotifications.ownerExecutableKey: executablePath]
        }

        func matches(_ payload: [AnyHashable: Any]?, requestID: String? = nil) -> Bool {
            guard isValid, let payload,
                  (payload[BridgeLifecycleNotifications.protocolVersionKey] as? NSNumber)?.intValue == version,
                  payload[BridgeLifecycleNotifications.instanceIDKey] as? String == instanceID,
                  (payload[BridgeLifecycleNotifications.ownerPIDKey] as? NSNumber)?.int32Value == pid,
                  payload[BridgeLifecycleNotifications.ownerExecutableKey] as? String == executablePath,
                  let request = payload[BridgeLifecycleNotifications.requestIDKey] as? String,
                  UUID(uuidString: request) != nil else { return false }
            return requestID == nil || request == requestID
        }
    }

    enum OwnershipError: LocalizedError {
        case filesystem(String), invalidLock, timedOut
        var errorDescription: String? {
            switch self {
            case let .filesystem(message): return "Agent Hub couldn't safely check whether it is already running. \(message)"
            case .invalidLock: return "Agent Hub's startup lock is not a private, regular file owned by this account. No second instance was started."
            case .timedOut: return "Another Agent Hub is still starting, closing, or not responding. No second instance was started. Try again shortly, or quit the existing Hub from its menu before reopening."
            }
        }
    }

    /// Testable ownership primitive. Never unlink a lock to recover it: doing
    /// that creates another inode that a second process could lock in parallel.
    final class InstanceLease {
        let fd: Int32
        let path: String
        private(set) var owner: InstanceOwner?

        init(path: String) throws {
            self.path = path
            let opened = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard opened >= 0 else { throw OwnershipError.filesystem(String(cString: strerror(errno))) }
            fd = opened
            do {
                try validatePath()
                guard fchmod(fd, 0o600) == 0 else { throw OwnershipError.invalidLock }
            } catch { close(fd); throw error }
        }

        deinit { close(fd) }

        func validatePath() throws {
            var descriptor = stat(), named = stat()
            guard fstat(fd, &descriptor) == 0, lstat(path, &named) == 0,
                  descriptor.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  descriptor.st_uid == geteuid(), descriptor.st_nlink == 1,
                  named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  descriptor.st_dev == named.st_dev, descriptor.st_ino == named.st_ino else { throw OwnershipError.invalidLock }
        }

        func acquire(owner: InstanceOwner) throws -> Bool {
            guard owner.isValid else { throw OwnershipError.invalidLock }
            guard try Self.tryLock(fd) else { return false }
            do {
                try validatePath()
                let data = try JSONEncoder().encode(owner)
                guard data.count <= 8192, ftruncate(fd, 0) == 0 else { throw OwnershipError.invalidLock }
                let written = data.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }
                guard written == data.count, fsync(fd) == 0 else { throw OwnershipError.invalidLock }
                self.owner = owner
                return true
            } catch { _ = flock(fd, LOCK_UN); throw error }
        }

        func readOwner() -> InstanceOwner? {
            guard (try? validatePath()) != nil else { return nil }
            return Self.readOwner(fd: fd)
        }

        static func readOwner(fd: Int32) -> InstanceOwner? {
            var bytes = [UInt8](repeating: 0, count: 8193)
            let count = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0, count <= 8192,
                  let owner = try? JSONDecoder().decode(InstanceOwner.self, from: Data(bytes.prefix(count))), owner.isValid else { return nil }
            return owner
        }

        static func tryLock(_ fd: Int32) throws -> Bool {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK || errno == EAGAIN { return false }
                throw OwnershipError.filesystem(String(cString: strerror(errno)))
            }
            return true
        }
    }

    static func isDiagnosticLaunch(_ environment: [String: String]) -> Bool {
        environment["BRIDGE_UI_PREVIEW"] == "1"
            || environment["BRIDGE_UI_INTERACTION_REPORT"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func acquireOrExit() {
        guard lease == nil, !isDiagnosticLaunch(ProcessInfo.processInfo.environment) else { return }
        do {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw OwnershipError.filesystem("Application Support could not be located.")
            }
            let directory = support.appendingPathComponent("ClaudeCodexBridge", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let candidate = try InstanceLease(path: directory.appendingPathComponent("menubar.lock").path)
            let owner = InstanceOwner()
            if try candidate.acquire(owner: owner) == false {
                switch handOff(lockFD: candidate.fd) {
                case .acquired:
                    guard try candidate.acquire(owner: owner) else { throw OwnershipError.invalidLock }
                case .runningInstanceActivated: exit(0)
                case .timedOut: throw OwnershipError.timedOut
                case .failed: throw OwnershipError.invalidLock
                }
            }
            lease = candidate
        } catch {
            NSLog("Agent Hub startup refused: %@", error.localizedDescription)
            NSApplication.shared.setActivationPolicy(.regular)
            let alert = NSAlert()
            alert.messageText = "Agent Hub couldn't open safely"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Close")
            alert.runModal()
            exit(1)
        }
    }

    enum HandOff: Equatable { case acquired, runningInstanceActivated, timedOut, failed }

    /// Asks the running instance to come forward, then waits briefly. It
    /// acknowledges within milliseconds when healthy. If instead it is in the
    /// middle of quitting, its lock frees up and this launch carries on as the
    /// only instance — so "quit and reopen" never ends with nothing running.
    static func handOff(lockFD fd: Int32, timeout: TimeInterval = 6,
                        activation: Notification.Name = activationNotification,
                        acknowledgement: Notification.Name = BridgeLifecycleNotifications.activationAcknowledged) -> HandOff {
        final class ResponseState: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            private var owner: InstanceOwner?
            func expect(_ owner: InstanceOwner?) { lock.lock(); self.owner = owner; lock.unlock() }
            func accept(_ payload: [AnyHashable: Any]?, requestID: String) {
                lock.lock(); defer { lock.unlock() }
                if owner?.matches(payload, requestID: requestID) == true { value = true }
            }
            func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { return .timedOut }
        let notifications = DistributedNotificationCenter.default()
        let acknowledged = ResponseState()
        let requestID = UUID().uuidString
        let observer = notifications.addObserver(forName: acknowledgement, object: nil, queue: nil) { response in
            acknowledged.accept(response.userInfo, requestID: requestID)
        }
        defer { notifications.removeObserver(observer) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var nextRequest: TimeInterval = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            do { if try InstanceLease.tryLock(fd) { return .acquired } }
            catch { return .failed }
            if acknowledged.read() { return .runningInstanceActivated }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextRequest {
                let owner = InstanceLease.readOwner(fd: fd)
                acknowledged.expect(owner)
                notifications.postNotificationName(activation, object: nil, userInfo: owner?.payload(requestID: requestID), deliverImmediately: true)
                nextRequest = now + 0.25
            }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, min(0.05, max(0, deadline - now)), true)
        }
        return .timedOut
    }

    /// Only a real owner can reply, and only to a request naming that exact
    /// incarnation. Diagnostic renderers never acquire a production lease.
    static func activationAcknowledgement(for notification: Notification, owner: InstanceOwner?, isQuitRequested: Bool) -> [String: Any]? {
        guard !isQuitRequested, let owner, owner.matches(notification.userInfo),
              let requestID = notification.userInfo?[BridgeLifecycleNotifications.requestIDKey] as? String else { return nil }
        return owner.payload(requestID: requestID)
    }
}

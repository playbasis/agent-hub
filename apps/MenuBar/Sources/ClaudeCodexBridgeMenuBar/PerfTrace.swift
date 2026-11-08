import BridgeCore
import Foundation

/// Developer timing trace for page changes and report preparation. Off
/// unless a preview sets `BRIDGE_PERF_TRACE=1`; then each mark prints its
/// offset from the previous navigation to standard error.
enum PerfTrace {
    static let isActive = ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW"] == "1"
        && ProcessInfo.processInfo.environment["BRIDGE_PERF_TRACE"] == "1"
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var origin = Date()
        var label = "start"
    }
    private static let clock = Clock()

    static func navigation(_ page: String) {
        guard isActive else { return }
        clock.lock.lock(); clock.origin = Date(); clock.label = page; clock.lock.unlock()
        emit("navigate", detail: page)
    }

    /// A page's content appeared; the next main-queue turn follows its commit.
    static func appeared(_ name: String) {
        guard isActive else { return }
        emit("appear", detail: name)
        DispatchQueue.main.async { emit("drawn", detail: name) }
    }

    static func mark(_ event: String, detail: String = "") {
        guard isActive else { return }
        emit(event, detail: detail)
    }

    /// Times a block and reports it with its duration.
    static func measure<T>(_ event: String, detail: String = "", _ block: () -> T) -> T {
        guard isActive else { return block() }
        let start = Date()
        let value = block()
        emit(event, detail: "\(detail) \(Int(Date().timeIntervalSince(start) * 1_000))ms")
        return value
    }

    private static func emit(_ event: String, detail: String) {
        clock.lock.lock()
        let offset = Int(Date().timeIntervalSince(clock.origin) * 1_000)
        let page = clock.label
        clock.lock.unlock()
        FileHandle.standardError.write(Data("[perf] +\(offset)ms \(page) \(event) \(detail)\n".utf8))
    }
}

import Foundation
import Network

/// Local path observations, not a provider-health probe or a cause of missing
/// tokens. A satisfied route does not prove Internet/DNS/API reachability.
public struct ActivityConnectionHistory: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case routeAvailable, routeUnavailable, needsConnection }
    public struct Interval: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var monitorID: String
        public var start: Date
        public var end: Date
        public var state: State
    }
    public var schemaVersion = "activity-connection-history/1"
    public private(set) var intervals: [Interval] = []
    public static let maximumIntervals = 2_048
    public static let retentionSeconds: TimeInterval = 30 * 86_400
    public static let maximumObservationGap: TimeInterval = 95
    public init() {}

    /// Heartbeats bound observation coverage. Never connect across a restart,
    /// long suspension or clock reversal, even when the two states agree.
    public mutating func observe(_ state: State, at date: Date, monitorID: String) {
        guard schemaVersion == "activity-connection-history/1", date.timeIntervalSince1970.isFinite,
              !monitorID.isEmpty, monitorID.utf8.count <= 128 else { return }
        if let last = intervals.last, date <= last.end { return }
        intervals.removeAll { $0.end < date.addingTimeInterval(-Self.retentionSeconds) }
        if let last = intervals.last, last.monitorID == monitorID,
           date.timeIntervalSince(last.end) <= Self.maximumObservationGap {
            intervals[intervals.count - 1].end = date
            if last.state == state { return }
        }
        intervals.append(Interval(id: "\(monitorID):\(date.timeIntervalSince1970)", monitorID: monitorID,
                                  start: date, end: date, state: state))
        if intervals.count > Self.maximumIntervals { intervals.removeFirst(intervals.count - Self.maximumIntervals) }
    }

    /// Intersections only, no extension to 'now' or invented pre-monitor past.
    public func interruptions(from: Date, to: Date) -> [Interval] {
        guard schemaVersion == "activity-connection-history/1", from < to else { return [] }
        return intervals.suffix(Self.maximumIntervals).compactMap { interval in
            guard interval.state == .routeUnavailable, interval.start.timeIntervalSince1970.isFinite,
                  interval.end.timeIntervalSince1970.isFinite, interval.start < interval.end,
                  interval.end > from, interval.start < to else { return nil }
            var clipped = interval
            clipped.start = max(from, interval.start); clipped.end = min(to, interval.end)
            return clipped
        }
    }

    public static let explanation = "Shading marks a network interruption observed on this Mac, not a confirmed provider outage or the cause of missing tokens. Local saved activity may still be available and can be recovered on refresh. Unshaded periods are not proof of a working Internet connection. Earlier periods, app restarts and long suspensions have no connection coverage."

    public static func gapDescription(hasRecords: Bool, networkInterrupted: Bool) -> String {
        let base = hasRecords ? "Token usage was not recorded for some saved activity; this is not zero usage."
                              : "No dated saved activity was found; this is not confirmed inactivity or zero usage."
        if networkInterrupted { return base + " A network interruption was observed during part of this interval, but the cause of missing usage is not established." }
        return base + " Connection, provider or collection problems are possible; no cause is established by this gap."
    }
}

/// Ignore callbacks from cancelled observers and out-of-order Tasks. An
/// intermediate requiresConnection event must not lose a pending recovery.
struct ActivityConnectionRecoveryPolicy {
    private var activeID: String?
    private var lastDate: Date?
    private var interrupted = false
    private var lastRecovery: Date?
    mutating func start(id: String) { activeID = id; lastDate = nil; interrupted = false; lastRecovery = nil }
    mutating func stop() { activeID = nil; lastDate = nil; interrupted = false; lastRecovery = nil }
    mutating func accept(_ state: ActivityConnectionHistory.State, at date: Date, id: String) -> Bool? {
        guard id == activeID, date.timeIntervalSince1970.isFinite, lastDate.map({ date > $0 }) ?? true else { return nil }
        lastDate = date
        if state == .routeUnavailable { interrupted = true }
        let recovered = state == .routeAvailable && interrupted
        if state == .routeAvailable { interrupted = false }
        guard recovered, lastRecovery.map({ date.timeIntervalSince($0) >= 60 }) ?? true else { return false }
        lastRecovery = date
        return true
    }
}

/// Passive OS route monitoring only: no HTTP probes, addresses, SSIDs or
/// provider requests. One low-frequency heartbeat; callbacks share one queue.
final class ActivityPathMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.claudecodexbridge.connection-history", qos: .utility)
    private let monitor = NWPathMonitor()
    let monitorID = UUID().uuidString
    private var state: ActivityConnectionHistory.State?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private let receive: @Sendable (ActivityConnectionHistory.State, Date, String) -> Void
    init(receive: @escaping @Sendable (ActivityConnectionHistory.State, Date, String) -> Void) { self.receive = receive }
    func start() {
        queue.async { [self] in
            guard !stopped, timer == nil else { return }
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, !self.stopped else { return }
                switch path.status {
                case .satisfied: self.state = .routeAvailable
                case .unsatisfied: self.state = .routeUnavailable
                case .requiresConnection: self.state = .needsConnection
                @unknown default: self.state = nil
                }
                self.sample()
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer; timer.resume()
            monitor.start(queue: queue)
        }
    }
    private func sample() { if !stopped, let state { receive(state, Date(), monitorID) } }
    func stop() { queue.async { [self] in stopped = true; timer?.cancel(); timer = nil; monitor.cancel() } }
}

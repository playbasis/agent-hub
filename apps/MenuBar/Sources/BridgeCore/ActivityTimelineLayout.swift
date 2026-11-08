import Foundation

/// Pure pixel layout shared with the swimlane view. Overlapping receipts are
/// clustered so every turn remains reachable through the chip's details.
public enum ActivityTimelineLayout {
    public struct Chip: Equatable, Identifiable, Sendable {
        public var segments: [ActivityAnalytics.Segment]
        public var x0: Double
        public var x1: Double
        public var id: String { segments.first?.turnID ?? "" }
        public var isCluster: Bool { segments.count > 1 }

        /// Unknown categories participate in the vote. A single known turn
        /// cannot color a whole burst whose other receipts are uncategorized.
        public var category: String? {
            var counts: [String: Int] = [:]
            for segment in segments { counts[segment.category ?? "", default: 0] += 1 }
            let winner = counts.keys.sorted().max { lhs, rhs in
                counts[lhs] == counts[rhs] ? lhs > rhs : counts[lhs, default: 0] < counts[rhs, default: 0]
            }
            return winner.flatMap { $0.isEmpty ? nil : $0 }
        }

        public var recordedSeconds: Double? {
            ActivityMetrics.elapsedSeconds(segments.map {
                ActivityTurn(id: $0.turnID, startedAt: $0.start, completedAt: $0.end)
            })
        }
    }

    public static func chips(_ segments: [ActivityAnalytics.Segment], from: Date, to: Date, width: Double) -> [Chip] {
        let span = to.timeIntervalSince(from)
        guard width.isFinite, width > 0, span.isFinite, span > 0,
              from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite else { return [] }
        var seen = Set<String>()
        let ordered = segments.filter {
            $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start
                && $0.start < to && $0.end > from
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.turnID < $1.turnID
        }
        var result: [Chip] = []
        for var segment in ordered where seen.insert(segment.turnID).inserted {
            segment.start = max(from, segment.start); segment.end = min(to, segment.end)
            let a = min(width, max(0, segment.start.timeIntervalSince(from) / span * width))
            let end = min(width, max(a, segment.end.timeIntervalSince(from) / span * width))
            let b = min(width, max(end, a + min(2, width)))
            guard b > a else { continue }
            if var last = result.last {
                let overlaps = a < last.x1
                let nearbySmallBurst = a - last.x1 < 3 && b - a < 10 && (last.x1 - last.x0 < 10 || last.isCluster)
                if overlaps || nearbySmallBurst {
                    last.segments.append(segment)
                    last.x1 = max(last.x1, b)
                    result[result.count - 1] = last
                    continue
                }
            }
            result.append(Chip(segments: [segment], x0: a, x1: b))
        }
        return result
    }
}

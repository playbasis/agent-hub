import Foundation

/// Presentation of the canonical accounting series. This never infers work
/// from open requests or fills missing measurements with zero.
public enum HourlyAgentChart {
    public struct Bucket: Equatable, Identifiable, Sendable {
        /// Calendar-hour identity, distinct even when a DST hour repeats.
        public var hourStart: Date
        /// The actual, possibly clipped interval represented by the bar.
        public var start: Date
        public var end: Date
        public var averageAgents: Double?
        public var hasObservations: Bool
        public var isPartial: Bool
        public var id: Date { hourStart }
        public var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
        /// The drawn bar: the interval inset on both sides so neighbouring
        /// hours read as separate bars, not one filled area. A partial edge
        /// hour keeps a proportionally narrow bar.
        public var barStart: Date { start.addingTimeInterval(barInset) }
        public var barEnd: Date { end.addingTimeInterval(-barInset) }
        private var barInset: TimeInterval { min(HourlyAgentChart.barGap / 2, end.timeIntervalSince(start) * HourlyAgentChart.barGap / 3_600 / 2) }
    }

    /// Gap between neighbouring full-hour bars, matching the hourly token chart.
    public static let barGap: TimeInterval = 12 * 60

    public static func buckets(_ points: [ActivityAccounting.Point], timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) -> [Bucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return points.compactMap { point in
            guard [point.start, point.windowStart, point.end].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
                  point.windowStart >= point.start, point.end > point.windowStart,
                  let hour = calendar.dateInterval(of: .hour, for: point.start), point.end <= hour.end else { return nil }
            return Bucket(hourStart: point.start, start: point.windowStart, end: point.end,
                          averageAgents: point.averageAgents,
                          hasObservations: point.nativeRecords > 0 || point.modelStepCount > 0,
                          isPartial: point.windowStart > hour.start || point.end < hour.end)
        }.sorted { $0.start < $1.start }
    }

    /// Whole-agent reference lines do not make the underlying time average a
    /// whole-agent count. Keep zero and the upper reference line explicit.
    public struct Scale: Equatable, Sendable {
        public var upperBound: Double
        public var ticks: [Double]

        public init(values: [Double?]) {
            let peak = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
            guard peak > 0 else {
                upperBound = 1; ticks = [0, 1]; return
            }
            let target = peak <= Double.greatestFiniteMagnitude / 1.05 ? peak * 1.05 : peak
            let rawStep = max(1, target / 5)
            let power = pow(10, floor(log10(rawStep)))
            let fraction = rawStep / power
            let multiplier: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
            let step = max(1, power * multiplier)
            let count = ceil(target / step)
            let upper = count * step
            if upper.isFinite, upper >= peak, count >= 1, count <= 6 {
                upperBound = upper
                ticks = (0 ... Int(count)).map { Double($0) * step }
            } else {
                // Even corrupt, near-Double-limit input must produce a finite,
                // bounded axis rather than overflow during drawing or labeling.
                let maximum = Double.greatestFiniteMagnitude
                upperBound = maximum
                ticks = (0 ... 5).map { maximum * (Double($0) / 5) }
            }
        }
    }

    public struct Tick: Equatable, Identifiable, Sendable {
        public var date: Date
        public var timeLabel: String
        public var dateLabel: String
        public var id: Date { date }
    }

    /// Include exact window edges, not another pair of rounded full hours.
    /// Dates on every label distinguish a rolling day's repeated clock time;
    /// zone abbreviations also distinguish the repeated hour at a DST change.
    public static func ticks(from: Date, to: Date, timeZone: TimeZone = ActivityAnalytics.reportingTimeZone,
                             locale: Locale = .current) -> [Tick] {
        let duration = to.timeIntervalSince(from)
        guard from.timeIntervalSinceReferenceDate.isFinite, to.timeIntervalSinceReferenceDate.isFinite,
              duration.isFinite, duration > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hourStep = duration <= 8 * 3_600 ? 1 : duration <= 16 * 3_600 ? 3 : 6
        let minimumGap = duration / 8
        var dates = [from]
        var cursor = calendar.dateInterval(of: .hour, for: from)?.end ?? to
        var inspected = 0
        while cursor < to, inspected < 24 * 366 {
            if calendar.component(.hour, from: cursor).isMultiple(of: hourStep),
               cursor.timeIntervalSince(dates.last ?? from) >= minimumGap,
               to.timeIntervalSince(cursor) >= minimumGap {
                dates.append(cursor)
            }
            guard let next = calendar.dateInterval(of: .hour, for: cursor)?.end, next > cursor else { break }
            cursor = next; inspected += 1
        }
        dates.append(to)
        let showZone = Set(dates.map { timeZone.secondsFromGMT(for: $0) }).count > 1
        let time = DateFormatter(); time.locale = locale; time.timeZone = timeZone
        time.setLocalizedDateFormatFromTemplate(showZone ? "jmmz" : "jmm")
        let day = DateFormatter(); day.locale = locale; day.timeZone = timeZone
        day.setLocalizedDateFormatFromTemplate("dMMM")
        return dates.map { Tick(date: $0, timeLabel: time.string(from: $0), dateLabel: day.string(from: $0)) }
    }

    public static func intervalLabel(_ bucket: Bucket, timeZone: TimeZone = ActivityAnalytics.reportingTimeZone,
                                     locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let surroundingDates = [bucket.start.addingTimeInterval(-86_400), bucket.start, bucket.end, bucket.end.addingTimeInterval(86_400)]
        let changesOffset = Set(surroundingDates.map { timeZone.secondsFromGMT(for: $0) }).count > 1
        let time = DateFormatter(); time.locale = locale; time.timeZone = timeZone
        time.setLocalizedDateFormatFromTemplate(changesOffset ? "jmmz" : "jmm")
        let day = DateFormatter(); day.locale = locale; day.timeZone = timeZone
        day.setLocalizedDateFormatFromTemplate("dMMM")
        let start = "\(day.string(from: bucket.start)), \(time.string(from: bucket.start))"
        let end = calendar.isDate(bucket.start, inSameDayAs: bucket.end)
            ? time.string(from: bucket.end) : "\(day.string(from: bucket.end)), \(time.string(from: bucket.end))"
        return "\(start)–\(end)"
    }
}

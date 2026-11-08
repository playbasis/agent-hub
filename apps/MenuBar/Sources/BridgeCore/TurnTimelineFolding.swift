import Foundation

extension TurnTimeline {
    /// A row in the drawer: one entry, or a run of the same bookkeeping event.
    public enum DisplayItem: Identifiable, Equatable, Sendable {
        case entry(Entry)
        case repeats(Repeat)
        public var id: String {
            switch self {
            case let .entry(entry): return entry.id
            case let .repeats(run): return run.id
            }
        }
    }

    /// Back-to-back hand-offs (or notices) with only model steps between
    /// them, kept in order and expandable. Nothing is dropped or re-counted.
    public struct Repeat: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: WorkEvidenceItem.Kind
        public let title: String
        public let entries: [Entry]
        public var operationCount: Int {
            entries.reduce(0) { if case .operation = $1 { return $0 + 1 }; return $0 }
        }
        public var stepCount: Int {
            entries.reduce(0) { if case let .steps(group) = $1 { return $0 + group.steps.count }; return $0 }
        }
        public var first: Date? { entries.compactMap(\.timestamp).min() }
        public var last: Date? {
            entries.compactMap { entry -> Date? in
                if case let .steps(group) = entry { return group.last ?? group.first }
                return entry.timestamp
            }.max()
        }
    }

    /// Only bookkeeping without an outcome folds. Tool calls, failures,
    /// requests, replies, plans and file changes always keep their own row.
    static let foldableKinds: Set<WorkEvidenceItem.Kind> = [.handoff, .notice]

    /// Folds runs of at least `minimumRepeats` same-kind, same-title
    /// bookkeeping events. A step group joins a run only between two of them.
    public static func fold(_ entries: [Entry], minimumRepeats: Int = 3) -> [DisplayItem] {
        func foldable(_ entry: Entry) -> (WorkEvidenceItem.Kind, String)? {
            guard case let .operation(operation) = entry, operation.outcome == nil, foldableKinds.contains(operation.kind) else { return nil }
            return (operation.kind, operation.title)
        }
        var result: [DisplayItem] = []
        var index = 0
        while index < entries.count {
            guard let key = foldable(entries[index]) else { result.append(.entry(entries[index])); index += 1; continue }
            var end = index, operations = 0
            while end < entries.count {
                if let next = foldable(entries[end]), next == key {
                    operations += 1; end += 1
                } else if case .steps = entries[end], end + 1 < entries.count, let next = foldable(entries[end + 1]), next == key {
                    end += 1
                } else { break }
            }
            if operations >= max(2, minimumRepeats) {
                let run = Array(entries[index ..< end])
                result.append(.repeats(Repeat(id: "repeat:" + entries[index].id, kind: key.0, title: key.1, entries: run)))
                index = end
            } else {
                result.append(.entry(entries[index])); index += 1
            }
        }
        return result
    }
}

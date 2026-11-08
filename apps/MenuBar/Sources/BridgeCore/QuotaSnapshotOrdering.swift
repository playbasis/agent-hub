import Foundation

/// Prevents an older status response from undoing a later account-usage read.
/// This is not an account-switch detector: only verified matching account
/// markers can share an observation order. Unknown or changed accounts always
/// accept the incoming snapshot, and their UI must separately verify scope.
public enum QuotaSnapshotOrdering {
    public static func merging(
        current: [String: QuotaEstimate],
        incoming: [String: QuotaEstimate]
    ) -> [String: QuotaEstimate] {
        // Iterate incoming keys only. An explicit provider removal must not
        // resurrect its old balance from the cache.
        incoming.mapValues { next in
            guard next.agent == .codex,
                  let previous = current[next.agent.rawValue] else { return next }
            let identified = previous.accountIdentityHash.map { !$0.isEmpty && next.accountIdentityHash == $0 } ?? false
            // Identity can be withheld even on successful Codex credit reads.
            // Order those dated bucket observations, without merging optional
            // fields or claiming that they identify a particular person.
            let anonymousBucket = previous.accountIdentityHash == nil && next.accountIdentityHash == nil
                && previous.limitID == "codex" && next.limitID == "codex"
            guard identified || anonymousBucket,
                  let previousDate = observationDate(previous),
                  observationDate(next).map({ $0 < previousDate }) ?? true
            else { return next }

            // Keep the complete newer reading, including an explicit nil
            // balance or a refresh failure. Do not merge optional provider
            // fields individually: nil in a successful response is real.
            var retained = previous
            retained.observedTurns = max(previous.observedTurns, next.observedTurns)
            retained.observedLimits = max(previous.observedLimits, next.observedLimits)
            return retained
        }
    }

    private static func observationDate(_ estimate: QuotaEstimate) -> Date? {
        [estimate.fetchedAt, estimate.refreshFailedAt]
            .compactMap { $0 }
            .filter { $0.timeIntervalSinceReferenceDate.isFinite }
            .max()
    }
}

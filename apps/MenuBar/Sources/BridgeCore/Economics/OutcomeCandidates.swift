import Foundation

/// A suggested delivered outcome: commits that look like one piece of work.
/// Suggestions only: a person accepts, rejects, merges or renames them.
public struct OutcomeCandidate: Codable, Equatable, Identifiable, Sendable {
    public struct CommitRef: Codable, Equatable, Sendable {
        public var repositoryID: String
        public var repositoryName: String
        public var id: String
        public var subject: String
        public var timestamp: Date
        public var additions: Int?
        public var deletions: Int?
        public var filesChanged: Int?
        /// Lock and generated-file lines, included in additions and deletions.
        public var generatedLines: Int
        public var link: String?
        public var sessionIDs: [String]
        /// Equivalent commits folded into this one (cherry-picks, rebased copies).
        public var duplicates: [String]
        /// The commit this one reverts, when it's in the same scan.
        public var reverts: String?
    }

    public var id: String
    public var title: String
    public var repositoryIDs: [String]
    public var repositoryNames: [String]
    public var commits: [CommitRef]
    public var sessionIDs: [String]
    public var goalIDs: [String]
    public var firstCommitAt: Date
    public var lastCommitAt: Date
    public var lines: LineCounts
    public var filesChanged: Int
    /// The root agent session that ties the commits together, when one does.
    public var thread: String?
    /// Outcomes (latest revisions) already holding some of these commits.
    public var decidedOutcomeIDs: [String]
    /// Every commit is in an accepted, rejected or withdrawn outcome.
    public var isDecided: Bool

    public var evidence: [OutcomeEvidence] {
        commits.map { OutcomeEvidence(kind: .commit, repositoryID: $0.repositoryID, ref: $0.id) }
            + sessionIDs.map { OutcomeEvidence(kind: .session, ref: $0) }
    }
}

/// Groups the period's commits into suggested outcomes. Commits tied to the
/// same root agent session (by a co-author trailer or shared files) stay
/// together; anything else groups by repository. A break of more than four
/// hours starts a new suggestion, so a weeks-long thread isn't one outcome.
public enum OutcomeCandidates {
    public static let burstGap: TimeInterval = 4 * 3_600

    public static func build(shipped: ShippedCodeReport.Result, sessions: [ActivitySession], outcomes: [AcceptedOutcomeRecord]) -> [OutcomeCandidate] {
        let parents = Dictionary(sessions.compactMap { session in session.parentSessionID.map { (session.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let goals = Dictionary(sessions.compactMap { session in session.goal.map { (session.id, $0.id) } }, uniquingKeysWith: { first, _ in first })
        func root(_ id: String) -> String {
            var current = id, seen: Set<String> = [id]
            while let parent = parents[current], seen.insert(parent).inserted { current = parent }
            return current
        }

        // Fold equivalent commits (same repository, subject, line counts and
        // files): the same change seen on two branches counts once.
        var refs: [OutcomeCandidate.CommitRef] = []
        var byEquivalence: [String: Int] = [:]
        var bySubject: [String: String] = [:]
        for item in shipped.commits.sorted(by: { ($0.commit.timestamp, $0.id) < ($1.commit.timestamp, $1.id) }) {
            let commit = item.commit
            let key = [item.repositoryID, commit.subject, commit.additions.map(String.init) ?? "?", commit.deletions.map(String.init) ?? "?",
                       commit.paths.sorted().joined(separator: "\u{1f}")].joined(separator: "\u{1e}")
            if let index = byEquivalence[key] { refs[index].duplicates.append(commit.id); continue }
            let generated = (commit.files ?? []).filter { ShippedCodeReport.isGenerated($0.path) }.reduce(0) { $0 + ($1.additions ?? 0) + ($1.deletions ?? 0) }
            var reverts: String?
            if commit.subject.hasPrefix("Revert \""), commit.subject.hasSuffix("\"") {
                let original = String(commit.subject.dropFirst(8).dropLast())
                reverts = bySubject[item.repositoryID + "\u{1e}" + original]
            }
            byEquivalence[key] = refs.count
            bySubject[item.repositoryID + "\u{1e}" + commit.subject] = commit.id
            refs.append(.init(repositoryID: item.repositoryID, repositoryName: item.repositoryName, id: commit.id, subject: commit.subject,
                              timestamp: commit.timestamp, additions: commit.additions, deletions: commit.deletions, filesChanged: commit.filesChanged,
                              generatedLines: generated, link: item.link.map(linkName), sessionIDs: item.sessionIDs.sorted(), duplicates: [], reverts: reverts))
        }

        // Thread: the root session behind a strong link; weak (time-only) links don't tie commits together.
        func thread(_ ref: OutcomeCandidate.CommitRef) -> String? {
            guard ref.link == "co_authored" || ref.link == "same_files", !ref.sessionIDs.isEmpty else { return nil }
            return ref.sessionIDs.map(root).min()
        }
        let groups = Dictionary(grouping: refs) { $0.repositoryID + "\u{1e}" + (thread($0) ?? "") }
        let decided = latestDecisions(outcomes)
        var candidates: [OutcomeCandidate] = []
        for key in groups.keys.sorted() {
            var burst: [OutcomeCandidate.CommitRef] = []
            for ref in groups[key]!.sorted(by: { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }) {
                if let last = burst.last, ref.timestamp.timeIntervalSince(last.timestamp) > burstGap {
                    candidates.append(candidate(burst, thread: thread(burst[0]), goals: goals, decided: decided))
                    burst = []
                }
                burst.append(ref)
            }
            if !burst.isEmpty { candidates.append(candidate(burst, thread: thread(burst[0]), goals: goals, decided: decided)) }
        }
        return candidates.sorted { ($0.lastCommitAt, $0.id) > ($1.lastCommitAt, $1.id) }
    }

    /// Latest revision of each outcome, with the commits it holds.
    static func latestDecisions(_ outcomes: [AcceptedOutcomeRecord]) -> [(record: AcceptedOutcomeRecord, commits: Set<String>)] {
        EconomicLedgerState.latest(outcomes).map { record in
            (record, Set(record.commitRefs.map { ($0.repositoryID ?? "") + ":" + $0.ref }))
        }
    }

    /// True when `ref` (a full or abbreviated hash) names `commitID` in that repository.
    static func holds(_ commits: Set<String>, repositoryID: String, commitID: String) -> Bool {
        if commits.contains(repositoryID + ":" + commitID) { return true }
        let prefix = repositoryID + ":"
        return commits.contains { $0.hasPrefix(prefix) && $0.count - prefix.count >= 7 && commitID.hasPrefix($0.dropFirst(prefix.count)) }
    }

    private static func candidate(_ refs: [OutcomeCandidate.CommitRef], thread: String?, goals: [String: String],
                                  decided: [(record: AcceptedOutcomeRecord, commits: Set<String>)]) -> OutcomeCandidate {
        let identity = refs.map { $0.repositoryID + ":" + $0.id }.sorted().joined(separator: "\n")
        let id = "cand-" + String(ContractDigest.hex(Data(identity.utf8)).prefix(16))
        var lines = LineCounts(), files = 0
        for ref in refs { lines.additions += ref.additions ?? 0; lines.deletions += ref.deletions ?? 0; files += ref.filesChanged ?? 0 }
        // The commit that changed the most hand-written lines names the suggestion.
        let lead = refs.max { lhs, rhs in
            let a = (lhs.additions ?? 0) + (lhs.deletions ?? 0) - lhs.generatedLines, b = (rhs.additions ?? 0) + (rhs.deletions ?? 0) - rhs.generatedLines
            return a == b ? lhs.timestamp < rhs.timestamp : a < b
        }!
        var title = lead.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Commit " + String(lead.id.prefix(7)) }
        if refs.count > 1 { title += " (+\(refs.count - 1) more)" }
        if title.count > 200 { title = String(title.prefix(199)) + "…" }
        let sessions = Array(Set(refs.flatMap(\.sessionIDs))).sorted()
        let holders = decided.filter { entry in refs.contains { holds(entry.commits, repositoryID: $0.repositoryID, commitID: $0.id) } }
        let covered = refs.allSatisfy { ref in decided.contains { holds($0.commits, repositoryID: ref.repositoryID, commitID: ref.id) } }
        return OutcomeCandidate(id: id, title: title, repositoryIDs: Array(Set(refs.map(\.repositoryID))).sorted(),
                                repositoryNames: Array(Set(refs.map(\.repositoryName))).sorted(), commits: refs, sessionIDs: sessions,
                                goalIDs: Array(Set(sessions.compactMap { goals[$0] })).sorted(), firstCommitAt: refs.first!.timestamp,
                                lastCommitAt: refs.last!.timestamp, lines: lines, filesChanged: files, thread: thread,
                                decidedOutcomeIDs: holders.map(\.record.outcomeID).sorted(), isDecided: covered)
    }

    static func linkName(_ link: ShippedCodeReport.Link) -> String {
        switch link {
        case .coAuthored: return "co_authored"
        case .sameFiles: return "same_files"
        case .duringSession: return "during_session"
        }
    }
}

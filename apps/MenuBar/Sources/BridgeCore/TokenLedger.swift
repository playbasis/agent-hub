import Foundation

/// Measured token activity, read from the transcripts Claude Code and Codex
/// already write to disk. This is a local activity ledger, not a billing record
/// and not the provider's plan accounting: neither subscription exposes its
/// window in tokens, so these series explain what was run, never what remains.
public struct TokenComponents: Codable, Equatable, Sendable {
    public var freshInput: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var output: Int

    public init(
        freshInput: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int = 0
    ) {
        self.freshInput = freshInput
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public var total: Int { freshInput + cacheRead + cacheWrite + output }

    /// Cache reads bill at a fraction of fresh input and output bills at a
    /// multiple, so a raw total is ~97% cache read and hides the expensive work.
    /// This restates a bucket in fresh-input-equivalent units.
    public var billableEquivalent: Int {
        let weighted = Double(freshInput)
            + Double(cacheRead) * 0.1
            + Double(cacheWrite) * 1.25
            + Double(output) * 5
        return Int(weighted.rounded())
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        TokenComponents(
            freshInput: lhs.freshInput + rhs.freshInput,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            output: lhs.output + rhs.output
        )
    }

    enum CodingKeys: String, CodingKey {
        case freshInput = "fresh_input"
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case output
    }
}

public struct TokenLedgerSample: Codable, Equatable, Sendable {
    /// Stable per-request identity. Resumed and compacted sessions replay old
    /// turns into new files, so without this the same turn is counted twice.
    public var key: String
    public var timestamp: Date
    public var agent: AgentName
    public var model: String?
    public var components: TokenComponents

    enum CodingKeys: String, CodingKey {
        case key, timestamp, agent, model, components
    }
}

public struct TokenSeriesPoint: Codable, Equatable, Sendable {
    public var start: Date
    public var byAgent: [String: TokenComponents]
    /// Additive canonical fields. New consumers must not turn a missing
    /// composition into zero by summing the legacy `byAgent` dictionary.
    public var end: Date? = nil
    public var authoritativeByAgent: [String: ActivityAccounting.UsageTotals]? = nil
    public var authoritativeTotals: ActivityAccounting.UsageTotals? = nil

    public var combined: TokenComponents {
        byAgent.values.reduce(TokenComponents(), +)
    }

    enum CodingKeys: String, CodingKey {
        case start
        case byAgent = "by_agent"
        case end
        case authoritativeByAgent = "authoritative_by_agent"
        case authoritativeTotals = "authoritative_totals"
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(byAgent, forKey: .byAgent)
        try container.encode(end, forKey: .end)
        try container.encode(authoritativeByAgent, forKey: .authoritativeByAgent)
        try container.encode(authoritativeTotals, forKey: .authoritativeTotals)
    }
}

public enum TokenBucketSize: String, Codable, Sendable {
    case hour, day

    var seconds: TimeInterval { self == .hour ? 3_600 : 86_400 }
}

public struct TokenSeries: Codable, Equatable, Sendable {
    public var bucket: TokenBucketSize
    public var points: [TokenSeriesPoint]
    public var authoritativeTotals: ActivityAccounting.UsageTotals? = nil
    public var unallocated: ActivityAccounting.UsageTotals? = nil
    public var unallocatedByAgent: [String: ActivityAccounting.UsageTotals]? = nil
    public var windowFrom: Date? = nil
    public var windowTo: Date? = nil

    enum CodingKeys: String, CodingKey {
        case bucket, points
        case authoritativeTotals = "authoritative_totals"
        case unallocated
        case unallocatedByAgent = "unallocated_by_agent"
        case windowFrom = "window_from"
        case windowTo = "window_to"
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bucket, forKey: .bucket)
        try container.encode(points, forKey: .points)
        try container.encode(authoritativeTotals, forKey: .authoritativeTotals)
        try container.encode(unallocated, forKey: .unallocated)
        try container.encode(unallocatedByAgent, forKey: .unallocatedByAgent)
        try container.encode(windowFrom, forKey: .windowFrom)
        try container.encode(windowTo, forKey: .windowTo)
    }
}

public struct TokenSeriesSnapshot: Codable, Equatable, Sendable {
    public var hourly: TokenSeries
    public var daily: TokenSeries
    public var generatedAt: Date
    public var bucketCount: Int
    /// Explains unavailable or incomplete history. Partial scans retain only
    /// known measurements and must not be interpreted as reported zeros.
    public var statusMessage: String?
    public var accountingSchemaVersion: String? = nil
    public var sourceScope: ActivityMetricScope? = nil
    public var hourlyScope: ActivityAccountingScope? = nil
    public var dailyScope: ActivityAccountingScope? = nil
    public var historyIsPartial: Bool? = nil
    public var connectionHistory: ActivityConnectionHistory? = nil
    public var status: String? = nil

    enum CodingKeys: String, CodingKey {
        case hourly, daily
        case generatedAt = "generated_at"
        case bucketCount = "bucket_count"
        case statusMessage = "status_message"
        case accountingSchemaVersion = "accounting_schema_version"
        case sourceScope = "source_scope"
        case hourlyScope = "hourly_scope"
        case dailyScope = "daily_scope"
        case historyIsPartial = "history_is_partial"
        case connectionHistory = "connection_history"
        case status
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hourly, forKey: .hourly)
        try container.encode(daily, forKey: .daily)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(bucketCount, forKey: .bucketCount)
        try container.encode(statusMessage, forKey: .statusMessage)
        try container.encode(accountingSchemaVersion, forKey: .accountingSchemaVersion)
        try container.encode(sourceScope, forKey: .sourceScope)
        try container.encode(hourlyScope, forKey: .hourlyScope)
        try container.encode(dailyScope, forKey: .dailyScope)
        try container.encode(historyIsPartial, forKey: .historyIsPartial)
        try container.encodeIfPresent(connectionHistory, forKey: .connectionHistory)
        try container.encode(status, forKey: .status)
    }

    public static let empty = TokenSeriesSnapshot(
        hourly: TokenSeries(bucket: .hour, points: []),
        daily: TokenSeries(bucket: .day, points: []),
        generatedAt: Date(timeIntervalSince1970: 0),
        bucketCount: 0,
        statusMessage: "No local history has been collected; refresh activity first.",
        accountingSchemaVersion: "accounting/1",
        sourceScope: .localNativeHistory,
        status: "unavailable"
    )
}

// MARK: - Incremental scanning

struct TokenLedgerCursor: Codable, Equatable, Sendable {
    var offset: UInt64
    var size: UInt64
    /// Codex only. Prefer the stable session UUID carried by rollout metadata;
    /// old transcripts without metadata fall back to the first reading's full
    /// component tuple. Resume timestamps and rollout IDs are not stable.
    var lineage: String?
    /// How many distinct Codex usage readings have been consumed from this file. Combined with
    /// `lineage` this gives a turn its position in the conversation, which is
    /// the only identity that survives a replay.
    var ordinal: Int
    /// Codex journals usage again when plan/rate-limit information changes.
    /// An unchanged cumulative reading is a snapshot, not another request.
    var cumulativeSignature: String?
    /// Once a line exceeds the memory bound, consume its remaining bytes
    /// without interpreting a later fragment as a new JSON record.
    var discardingOversizedLine: Bool
    var skippedOversizedRecords: Int

    init(
        offset: UInt64,
        size: UInt64,
        lineage: String? = nil,
        ordinal: Int = 0,
        cumulativeSignature: String? = nil,
        discardingOversizedLine: Bool = false,
        skippedOversizedRecords: Int = 0
    ) {
        self.offset = offset
        self.size = size
        self.lineage = lineage
        self.ordinal = ordinal
        self.cumulativeSignature = cumulativeSignature
        self.discardingOversizedLine = discardingOversizedLine
        self.skippedOversizedRecords = skippedOversizedRecords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(UInt64.self, forKey: .offset)
        size = try c.decode(UInt64.self, forKey: .size)
        lineage = try c.decodeIfPresent(String.self, forKey: .lineage)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
        cumulativeSignature = try c.decodeIfPresent(String.self, forKey: .cumulativeSignature)
        discardingOversizedLine = try c.decodeIfPresent(Bool.self, forKey: .discardingOversizedLine) ?? false
        skippedOversizedRecords = try c.decodeIfPresent(Int.self, forKey: .skippedOversizedRecords) ?? 0
    }
}

/// Aggregates, not raw samples. A busy fortnight produces well over a million
/// readings; keeping them individually turned every scan into a 228 MB
/// re-encode. Hour buckets bound the cache to a few hundred rows instead.
struct TokenLedgerCache: Codable, Equatable, Sendable {
    /// Bumped when extraction or dedup semantics change, because a cache
    /// written under an older reader can contain missing or already-wrong
    /// totals. v2 fixed Codex replay counting; v3 recognizes Claude Code's
    /// current wrapped usage records and stable message IDs. v4 preserves idle
    /// cursors, skips unchanged Codex usage snapshots and uses session UUIDs.
    /// A derived local cache is deliberately rebuilt from source rather than migrated.
    static let currentVersion = 4

    var version: Int = TokenLedgerCache.currentVersion
    var cursors: [String: TokenLedgerCursor] = [:]
    /// "<epochHour>|<agent>" → summed components for that hour.
    var buckets: [String: TokenComponents] = [:]
    /// Turn identities already counted, keyed to the hour that lets them be
    /// evicted with their bucket. BOTH agents need this: resumed sessions
    /// replay old turns into new files, which byte cursors cannot detect
    /// because a resumed rollout is a new path starting at offset 0.
    var seenKeys: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case version, cursors, buckets
        case seenKeys = "seen_keys"
    }

    init() {}

    var partialStatusMessage: String? {
        let skipped = cursors.values.reduce(0) { count, cursor in
            let sum = count.addingReportingOverflow(max(0, cursor.skippedOversizedRecords))
            return sum.overflow ? Int.max : sum.partialValue
        }
        guard skipped > 0 else { return nil }
        return "Token history is partial: \(skipped.formatted()) oversized \(skipped == 1 ? "record was" : "records were") skipped to keep memory bounded. Counts are known lower bounds; missing usage is not zero."
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        cursors = try c.decodeIfPresent([String: TokenLedgerCursor].self, forKey: .cursors) ?? [:]
        buckets = try c.decodeIfPresent([String: TokenComponents].self, forKey: .buckets) ?? [:]
        seenKeys = try c.decodeIfPresent([String: Int].self, forKey: .seenKeys) ?? [:]
    }
}

enum TokenBucketKey {
    static func epochHour(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 3_600).rounded(.down))
    }

    static func make(hour: Int, agent: AgentName) -> String {
        "\(hour)|\(agent.rawValue)"
    }

    static func split(_ key: String) -> (hour: Int, agent: String)? {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let hour = Int(parts[0]) else { return nil }
        return (hour, String(parts[1]))
    }
}

/// Walks the two providers' JSONL transcripts and turns them into deduplicated
/// samples. Files are append-only, so each pass reads only the bytes appended
/// since the last one — the first pass is the only expensive one.
public struct TokenLedgerScanner: Sendable {
    public static let retentionDays = 14

    private let claudeRoot: URL
    private let codexRoot: URL
    private let maximumLineBytes: Int

    public init(claudeRoot: URL? = nil, codexRoot: URL? = nil, maximumLineBytes: Int = 1_024 * 1_024) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeRoot = claudeRoot
            ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexRoot = codexRoot
            ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.maximumLineBytes = max(1_024, min(maximumLineBytes, 1_024 * 1_024))
    }

    func scan(cache: TokenLedgerCache, now: Date) -> TokenLedgerCache {
        var cache = cache
        let windowStart = now.addingTimeInterval(
            -Double(Self.retentionDays) * 86_400
        )
        let windowStartHour = TokenBucketKey.epochHour(windowStart)
        // Guards against the same turn appearing twice inside one pass. The
        // persisted `seenKeys` set covers the harder case — the same turn
        // reappearing in a LATER pass, inside a resumed session's new rollout.
        var seenThisPass = Set<String>()

        for (root, agent) in [(claudeRoot, AgentName.claude), (codexRoot, .codex)] {
            for file in transcripts(in: root, modifiedAfter: windowStart) {
                // Directory enumeration resolves symlinks, so the raw URL path
                // and the enumerated one can differ for the same file. Normalise
                // or the cursor is never found and the file is re-read forever.
                let path = file.resolvingSymlinksInPath().path
                var cursor = cache.cursors[path] ?? TokenLedgerCursor(offset: 0, size: 0)
                let size = fileSize(file)
                // A shrunken file was rotated or rewritten; re-read from the top.
                if size < cursor.offset { cursor = TokenLedgerCursor(offset: 0, size: 0) }
                guard size > cursor.offset else {
                    cursor.size = size
                    cache.cursors[path] = cursor
                    continue
                }
                // Fix the conversation identity once, from the head of the file,
                // before reading incrementally. A resumed rollout replays the
                // same opening readings, so two files of one conversation agree
                // here even though every timestamp inside them differs.
                if agent == .codex, cursor.lineage == nil {
                    cursor.lineage = codexLineage(of: file)
                }

                let read = readLines(of: file, from: cursor.offset, discardingOversizedLine: cursor.discardingOversizedLine) { line in
                    guard let parsed = parse(line: line, agent: agent) else { return }
                    let sample = parsed.sample

                    var key = sample.key
                    if agent == .codex {
                        if let signature = parsed.cumulativeSignature {
                            guard signature != cursor.cumulativeSignature else { return }
                            cursor.cumulativeSignature = signature
                        }
                        // Position in the conversation, not wall-clock. Ordinal
                        // advances for distinct usage readings — including ones outside
                        // the retention window — or two rollouts of the same
                        // conversation would number their turns differently and
                        // stop matching.
                        key = "codex:\(cursor.lineage ?? path):\(cursor.ordinal):\(componentSignature(sample.components))"
                        cursor.ordinal += 1
                    }

                    guard sample.timestamp >= windowStart else { return }
                    guard seenThisPass.insert(key).inserted else { return }
                    let hour = TokenBucketKey.epochHour(sample.timestamp)
                    guard cache.seenKeys[key] == nil else { return }
                    cache.seenKeys[key] = hour

                    let bucketKey = TokenBucketKey.make(hour: hour, agent: agent)
                    cache.buckets[bucketKey] =
                        (cache.buckets[bucketKey] ?? TokenComponents()) + sample.components
                }
                cursor.offset += read.consumed
                cursor.size = size
                cursor.discardingOversizedLine = read.discardingOversizedLine
                let skipped = cursor.skippedOversizedRecords.addingReportingOverflow(read.skipped)
                cursor.skippedOversizedRecords = skipped.overflow ? Int.max : skipped.partialValue
                cache.cursors[path] = cursor
            }
        }

        cache.buckets = cache.buckets.filter {
            (TokenBucketKey.split($0.key)?.hour ?? 0) >= windowStartHour
        }
        cache.seenKeys = cache.seenKeys.filter { $0.value >= windowStartHour }
        // Cursors for files that aged out would otherwise grow without bound.
        let live = Set(cache.cursors.keys.filter { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { return false }
            return modified >= windowStart
        })
        cache.cursors = cache.cursors.filter { live.contains($0.key) }
        return cache
    }

    private func transcripts(in root: URL, modifiedAfter: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified >= modifiedAfter
            else { continue }
            result.append(url)
        }
        return result
    }

    /// Identifies a Codex conversation using session_meta.session_id, which
    /// remains stable when a resume writes a new rollout with a different id.
    /// session_meta.id is the fallback for versions without session_id.
    /// Without metadata use one complete component tuple, never just its sum:
    /// unrelated requests can have identical totals with different cache use.
    ///
    /// Returns nil for a rollout with no readings yet; the caller then falls
    /// back to the file path and counts the file on its own.
    private func codexLineage(of url: URL) -> String? {
        var lineage: String?
        _ = readLines(of: url, from: 0, shouldStop: { lineage != nil }) { line in
            if line.contains(marker: Self.sessionMetaMarker),
               let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               root["type"] as? String == "session_meta",
               let metadata = root["payload"] as? [String: Any],
               let identity = firstNonEmpty(string(metadata["session_id"]), string(metadata["id"])) {
                lineage = "session:" + identity
            } else if line.contains(marker: Self.tokenCountMarker), let sample = parseCodex(line: line) {
                lineage = "components:" + componentSignature(sample.sample.components)
            }
        }
        return lineage
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private struct LineRead {
        var consumed: UInt64 = 0
        var discardingOversizedLine = false
        var skipped = 0
    }

    /// Complete, bounded lines only. Ordinary trailing partial lines stay
    /// unconsumed. Oversized lines advance the cursor and persist discard
    /// state across polls until their newline, without retaining their bytes.
    private func readLines(
        of url: URL,
        from offset: UInt64,
        discardingOversizedLine: Bool = false,
        shouldStop: (() -> Bool)? = nil,
        handle: (Data) -> Void
    ) -> LineRead {
        var result = LineRead(discardingOversizedLine: discardingOversizedLine)
        guard let file = try? FileHandle(forReadingFrom: url) else { return result }
        defer { try? file.close() }
        guard (try? file.seek(toOffset: offset)) != nil else { return result }

        var carry = Data()
        while true {
            let read: Data? = autoreleasepool { try? file.read(upToCount: 65_536) }
            guard let chunk = read, !chunk.isEmpty else { break }
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let newline = chunk[start...].firstIndex(of: 0x0A)
                let end = newline ?? chunk.endIndex
                let piece = chunk[start..<end]
                let separatorBytes = newline == nil ? 0 : 1
                if result.discardingOversizedLine {
                    result.consumed += UInt64(piece.count + separatorBytes)
                    if newline != nil { result.discardingOversizedLine = false }
                } else if piece.count > maximumLineBytes - carry.count {
                    result.skipped += 1
                    result.consumed += UInt64(carry.count + piece.count + separatorBytes)
                    carry.removeAll(keepingCapacity: false)
                    result.discardingOversizedLine = newline == nil
                } else {
                    carry.append(piece)
                    if newline != nil {
                        // JSONSerialization creates Foundation objects. Drain
                        // those per line rather than after a multi-GB scan.
                        autoreleasepool { handle(carry) }
                        result.consumed += UInt64(carry.count + 1)
                        carry.removeAll(keepingCapacity: true)
                        if shouldStop?() == true { return result }
                    }
                }
                start = newline.map { chunk.index(after: $0) } ?? chunk.endIndex
            }
        }
        return result
    }

    // MARK: Parsing

    private struct ParsedSample {
        var sample: TokenLedgerSample
        var cumulativeSignature: String?
    }

    private func componentSignature(_ components: TokenComponents) -> String {
        "\(components.freshInput),\(components.cacheRead),\(components.cacheWrite),\(components.output)"
    }

    private func parse(line: Data, agent: AgentName) -> ParsedSample? {
        // A byte-level prefilter keeps JSON decoding off the ~98% of lines that
        // carry no usage at all, which is what makes a 13 GB pass affordable.
        switch agent {
        case .claude:
            guard line.contains(marker: Self.usageMarker) else { return nil }
            guard let sample = parseClaude(line: line) else { return nil }
            return ParsedSample(sample: sample, cumulativeSignature: nil)
        case .codex:
            guard line.contains(marker: Self.tokenCountMarker) else { return nil }
            return parseCodex(line: line)
        default:
            return nil
        }
    }

    private static let usageMarker = Array(#""usage""#.utf8)
    private static let tokenCountMarker = Array(#""token_count""#.utf8)
    private static let sessionMetaMarker = Array(#""session_meta""#.utf8)

    private func parseClaude(line: Data) -> TokenLedgerSample? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let timestamp = date(
                  from: string(root["timestamp"]) ?? string(root["created_at"])
              )
        else { return nil }

        // Claude Code has emitted both assistant transcript entries and
        // print-mode/wrapped assistant envelopes. Keep accepting the original
        // shape, but do not require usage to be nested at exactly one path.
        // This also lets a CLI schema update add metadata without silently
        // turning a live chart into a zero chart.
        let message = root["message"] as? [String: Any] ?? root
        let type = string(root["type"]) ?? string(message["role"])
        guard type == "assistant" || string(message["role"]) == "assistant",
              let usage = (message["usage"] as? [String: Any])
                  ?? (root["usage"] as? [String: Any])
        else { return nil }

        let components = claudeComponents(usage)
        // Synthetic bookkeeping entries use a valid usage object filled with
        // zeros. They are not model turns and must not enter the dedup index.
        guard components.total > 0 else { return nil }

        let key = firstNonEmpty(
            string(root["requestId"]),
            string(root["request_id"]),
            string(message["id"]),
            string(root["uuid"])
        )
        guard let key else { return nil }
        return TokenLedgerSample(
            key: "claude:" + key,
            timestamp: timestamp,
            agent: .claude,
            model: string(message["model"]) ?? string(root["model"]),
            components: components
        )
    }

    private func claudeComponents(_ usage: [String: Any]) -> TokenComponents {
        let cacheCreation = usage["cache_creation"] as? [String: Any]
        // Current Claude usage carries an aggregate creation count. Some
        // transcript versions instead expose its TTL-specific components; use
        // them only when the aggregate is absent, never in addition to it.
        let cacheWrite = integer(usage["cache_creation_input_tokens"])
            ?? cacheCreation.map { creation in
                creation.values.reduce(0) { $0 + (integer($1) ?? 0) }
            }
            ?? 0
        return TokenComponents(
            // Claude reports fresh input separately from cache already.
            freshInput: integer(usage["input_tokens"]) ?? 0,
            cacheRead: integer(usage["cache_read_input_tokens"]) ?? 0,
            cacheWrite: cacheWrite,
            output: integer(usage["output_tokens"]) ?? 0
        )
    }

    private func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        case let value as String:
            Int(value)
        default:
            nil
        }
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first
    }

    private func parseCodex(line: Data) -> ParsedSample? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              // `total_token_usage` is cumulative for the session; only the
              // per-request delta may be summed across events.
              let last = info["last_token_usage"] as? [String: Any],
              let timestamp = date(from: root["timestamp"] as? String)
        else { return nil }
        let input = last["input_tokens"] as? Int ?? 0
        let cached = last["cached_input_tokens"] as? Int ?? 0
        let cumulativeSignature = (info["total_token_usage"] as? [String: Any]).map { total in
            ["input_tokens", "cached_input_tokens", "cache_write_input_tokens",
             "output_tokens", "reasoning_output_tokens", "total_tokens"]
                .map { String(integer(total[$0]) ?? 0) }.joined(separator: ",")
        }
        // Codex has no request id, and the timestamp is NOT usable as identity:
        // resuming a session rewrites every replayed reading with the resume
        // time, so a time-based key sees each replay as fresh work. The real
        // key is (conversation lineage, ordinal) and only the scanner can build
        // it, since it needs the file's position. Left empty deliberately.
        return ParsedSample(sample: TokenLedgerSample(
            key: "",
            timestamp: timestamp,
            agent: .codex,
            model: nil,
            components: TokenComponents(
                // Codex folds cached tokens into its input count.
                freshInput: max(0, input - cached),
                cacheRead: cached,
                cacheWrite: last["cache_write_input_tokens"] as? Int ?? 0,
                output: last["output_tokens"] as? Int ?? 0
            )
        ), cumulativeSignature: cumulativeSignature)
    }

    private func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601.date(value)
    }
}

private extension Data {
    func contains(marker: [UInt8]) -> Bool {
        guard count >= marker.count, let first = marker.first else { return false }
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let limit = count - marker.count
            var index = 0
            while index <= limit {
                if base[index] == first {
                    var offset = 1
                    while offset < marker.count, base[index + offset] == marker[offset] {
                        offset += 1
                    }
                    if offset == marker.count { return true }
                }
                index += 1
            }
            return false
        }
    }
}

// MARK: - Bucketing

public enum TokenSeriesBuilder {
    public static func build(
        buckets: [String: TokenComponents],
        bucket: TokenBucketSize,
        span: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> TokenSeries {
        let anchor = truncate(now, to: bucket, calendar: calendar)
        var totals: [Date: [String: TokenComponents]] = [:]
        for (key, components) in buckets {
            guard let parsed = TokenBucketKey.split(key) else { continue }
            let timestamp = Date(timeIntervalSince1970: Double(parsed.hour) * 3_600)
            let start = truncate(timestamp, to: bucket, calendar: calendar)
            guard start <= anchor,
                  start >= anchor.addingTimeInterval(-Double(span - 1) * bucket.seconds)
            else { continue }
            totals[start, default: [:]][parsed.agent] =
                (totals[start]?[parsed.agent] ?? TokenComponents()) + components
        }
        // Emit every bucket in the span, including empty ones: a gap in the
        // chart must read as "nothing ran", not as missing data.
        let points = (0 ..< span).reversed().map { step -> TokenSeriesPoint in
            let start = anchor.addingTimeInterval(-Double(step) * bucket.seconds)
            let key = truncate(start, to: bucket, calendar: calendar)
            return TokenSeriesPoint(start: key, byAgent: totals[key] ?? [:])
        }
        return TokenSeries(bucket: bucket, points: points)
    }

    private static func truncate(
        _ date: Date,
        to bucket: TokenBucketSize,
        calendar: Calendar
    ) -> Date {
        let units: Set<Calendar.Component> = bucket == .hour
            ? [.year, .month, .day, .hour]
            : [.year, .month, .day]
        return calendar.date(from: calendar.dateComponents(units, from: date)) ?? date
    }
}

// MARK: - Store

/// The normal service reads the same saved activity snapshot as Models and
/// metrics exports. The scanner initializer is an explicit legacy diagnostic
/// seam only; normal GETs never rescan, migrate, overwrite or delete its cache.
public actor TokenLedgerStore {
    public static let shared = TokenLedgerStore()

    private let scanner: TokenLedgerScanner?
    private let activityService: ActivityReportingService
    private let cacheURL: URL
    private let minimumInterval: TimeInterval
    private var snapshot: TokenSeriesSnapshot = .empty
    private var lastScan: Date?

    public init(activityService: ActivityReportingService = .shared) {
        self.activityService = activityService
        scanner = nil
        cacheURL = BridgePaths.tokenLedgerCache
        minimumInterval = 60
    }

    /// Explicit compatibility/testing path, never used by the runtime routes.
    public init(
        scanner: TokenLedgerScanner,
        cacheURL: URL = BridgePaths.tokenLedgerCache,
        minimumInterval: TimeInterval = 60
    ) {
        self.scanner = scanner
        activityService = .shared
        self.cacheURL = cacheURL
        self.minimumInterval = minimumInterval
    }

    public func series(now: Date = Date(), force: Bool = false) async -> TokenSeriesSnapshot {
        guard let scanner else {
            do { return TokenAccountingSeriesAdapter.build(overview: try await activityService.overview()) }
            catch {
                var unavailable = TokenSeriesSnapshot.empty
                unavailable.statusMessage = "Saved activity couldn't be read. " + TraceRedactor.redact(error.localizedDescription, maximumCharacters: 240)
                return unavailable
            }
        }
        if !force,
           let lastScan,
           now >= lastScan,
           now.timeIntervalSince(lastScan) < minimumInterval
        {
            return snapshot
        }
        lastScan = now
        var cache = load()
        cache = scanner.scan(cache: cache, now: now)
        save(cache)
        let partial = cache.partialStatusMessage
        // No successfully measured sample plus a discarded record is unknown
        // history, not a contiguous series of measured zero buckets.
        let unknownOnly = cache.buckets.isEmpty && partial != nil
        snapshot = TokenSeriesSnapshot(
            hourly: unknownOnly ? TokenSeries(bucket: .hour, points: []) : TokenSeriesBuilder.build(
                buckets: cache.buckets, bucket: .hour, span: 24, now: now
            ),
            daily: unknownOnly ? TokenSeries(bucket: .day, points: []) : TokenSeriesBuilder.build(
                buckets: cache.buckets, bucket: .day, span: 14, now: now
            ),
            generatedAt: now,
            bucketCount: cache.buckets.count,
            statusMessage: partial ?? (cache.buckets.isEmpty
                ? "No agent activity recorded in the last \(TokenLedgerScanner.retentionDays) days."
                : nil)
        )
        return snapshot
    }

    private func load() -> TokenLedgerCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? BridgeJSON.decoder.decode(TokenLedgerCache.self, from: data)
        else { return TokenLedgerCache() }
        // A cache written under an older dedup scheme holds totals that are
        // wrong, not merely stale, so it is discarded rather than migrated. The
        // next pass re-reads the transcripts from scratch.
        guard cache.version == TokenLedgerCache.currentVersion else {
            return TokenLedgerCache()
        }
        return cache
    }

    private func save(_ cache: TokenLedgerCache) {
        guard let data = try? BridgeJSON.compactEncoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// Compatibility projection only. Every count and bucket comes from the same
/// canonical receipts used by Models, /activity/accounting and CLI exports.
public enum TokenAccountingSeriesAdapter {
    public static func build(overview: ActivityOverview) -> TokenSeriesSnapshot {
        guard ActivityAccountingQuery.hasSnapshot(overview) else { return .empty }
        guard let hourlyReport = try? ActivityAccountingQuery(window: .rolling24Hours).report(overview: overview),
              let dailyReport = try? ActivityAccountingQuery(window: .calendar14Days).report(overview: overview) else { return .empty }
        let asOf = hourlyReport.scope.asOf
        let hourly = adapt(hourlyReport, bucket: .hour)
        let daily = adapt(dailyReport, bucket: .day)
        var messages: [String] = []
        if hourlyReport.totals.tokensArePartial || dailyReport.totals.tokensArePartial {
            messages.append("Known tokens are a lower bound; some saved activity is missing usage.")
        }
        if (hourly.unallocated?.usageRecords ?? 0) > 0 || (daily.unallocated?.usageRecords ?? 0) > 0 {
            messages.append("Some readings have no exact bucket; totals include them, bars do not.")
        }
        messages += (hourlyReport.warnings + dailyReport.warnings).map { TraceRedactor.redact($0, maximumCharacters: 300) }
        return TokenSeriesSnapshot(hourly: hourly, daily: daily, generatedAt: asOf,
                                   bucketCount: hourly.points.count + daily.points.count,
                                   statusMessage: messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: " "),
                                   accountingSchemaVersion: hourlyReport.schemaVersion, sourceScope: .localNativeHistory,
                                   hourlyScope: hourlyReport.scope, dailyScope: dailyReport.scope,
                                   historyIsPartial: hourlyReport.sourceCoverageIsPartial,
                                   connectionHistory: overview.connectionHistory,
                                   status: hourlyReport.sourceCoverageIsPartial || hourlyReport.totals.tokensArePartial || dailyReport.totals.tokensArePartial
                                    || hourlyReport.totals.outputIsPartial || dailyReport.totals.outputIsPartial ? "partial" : "ready")
    }

    private static func adapt(_ report: ActivityAccounting.Report, bucket: TokenBucketSize) -> TokenSeries {
        let source = report.series(granularity: bucket == .hour ? .hour : .day)
        // Old consumers sum Int components and convert a weighted Double back
        // to Int. Emit that compatibility shape only when the entire window
        // reconciles and those legacy operations cannot overflow. Canonical
        // optional totals remain available independently of this dictionary.
        let weighted = report.totals.usage.weightedEquivalent
        let legacySafe = report.totals.usage.composition?.isComplete == true
            && report.totals.usage.composition?.total != nil && !report.totals.usage.tokenOverflow
            && weighted.map { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) } == true
        let points = source.points.map { value -> TokenSeriesPoint in
            let compatible = value.byProvider.compactMapValues { usage -> TokenComponents? in
                guard legacySafe, !value.usage.tokenOverflow, value.usage.composition?.total != nil,
                      let parts = usage.composition, parts.isComplete, parts.total != nil else { return nil }
                return TokenComponents(freshInput: parts.freshInput, cacheRead: parts.rereadContext, cacheWrite: parts.cacheWrites, output: parts.output)
            }
            return TokenSeriesPoint(start: value.windowStart, byAgent: compatible,
                                    end: value.end, authoritativeByAgent: value.byProvider, authoritativeTotals: value.usage)
        }
        return TokenSeries(bucket: bucket, points: points, authoritativeTotals: report.totals.usage,
                           unallocated: source.unallocated, unallocatedByAgent: source.unallocatedByProvider,
                           windowFrom: report.scope.from, windowTo: report.scope.to)
    }
}

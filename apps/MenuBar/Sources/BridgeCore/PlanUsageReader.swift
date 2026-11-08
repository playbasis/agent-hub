import Darwin
import Foundation

/// Reads provider-owned plan limits without opening either provider's
/// credential store. Codex is queried through its documented app-server RPC;
/// Claude is queried through its own interactive `/usage` command in a PTY.
public struct LivePlanUsageReader: Sendable {
    private let configuration: AgentConfiguration
    private let currentDirectory: URL

    public init(
        configuration: AgentConfiguration,
        currentDirectory: URL? = nil
    ) {
        self.configuration = configuration
        self.currentDirectory = currentDirectory
            ?? BridgePaths.providerProbeDirectory
    }

    public func readAll(now: Date = Date()) async -> [QuotaEstimate] {
        async let codex = readCodex(now: now)
        async let claude = readClaude(now: now)
        async let grok = readGrok(now: now)
        return await [claude, codex, grok]
    }

    public func readGrok(now: Date = Date()) async -> QuotaEstimate {
        do {
            try ensureProbeDirectory()
            let executable = try ExecutableLocator.resolve(configuration.grokCommand)
            let version = try await ProcessRunner.run(
                executable: executable.path,
                arguments: ["version"],
                currentDirectory: currentDirectory,
                stdin: "",
                timeoutSeconds: 6,
                maximumOutputCharacters: 10_000
            )
            guard version.status == 0 else {
                throw PlanUsageError.provider(
                    version.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return QuotaEstimate(
                agent: .grok,
                source: .unavailable,
                fetchedAt: now,
                planName: "Grok Build",
                statusMessage: """
                Grok Build is installed. Subscription usage remains provider-owned; \
                Bridge receipts show measured turn usage.
                """
            )
        } catch {
            return QuotaEstimate(
                agent: .grok,
                available: false,
                source: .unavailable,
                statusMessage: "Grok Build is not installed or not on PATH."
            )
        }
    }

    public func readCodex(now: Date = Date()) async -> QuotaEstimate {
        var accountIdentityHash: String?
        do {
            try ensureProbeDirectory()
            let executable = try ExecutableLocator.resolve(configuration.codexCommand)
            let session = try await CodexAppServerSession(
                executable: executable,
                currentDirectory: currentDirectory
            )
            defer { session.close() }
            // A renewed ChatGPT subscription can leave a persisted CLI token
            // valid enough to launch Codex but stale for account endpoints.
            // Give app-server its documented managed-token refresh before
            // asking for the linked subscription's rate-limit windows.
            let account = try await session.request(
                "account/read",
                params: ["refreshToken": true],
                timeoutSeconds: 10
            )
            accountIdentityHash = CodexUsageParser.accountIdentityHash(result: account)
            let result = try await session.request(
                "account/rateLimits/read",
                timeoutSeconds: 10
            )
            var estimate = try CodexUsageParser.parse(result: result, now: now)
            estimate.accountIdentityHash = accountIdentityHash
            return estimate
        } catch {
            return QuotaEstimate(
                agent: .codex,
                source: .unavailable,
                statusMessage: "Codex plan usage unavailable: \(concise(error))",
                accountIdentityHash: accountIdentityHash
            )
        }
    }

    public func readClaude(now: Date = Date()) async -> QuotaEstimate {
        let executable: URL
        do {
            try ensureProbeDirectory()
            executable = try ExecutableLocator.resolve(configuration.claudeCommand)
        } catch {
            return QuotaEstimate(
                agent: .claude,
                source: .unavailable,
                statusMessage: "Claude Code is not installed or not on PATH."
            )
        }

        let auth: ClaudeAuthStatus
        do {
            let process = try await ProcessRunner.run(
                executable: executable.path,
                arguments: ["auth", "status", "--json"],
                currentDirectory: currentDirectory,
                stdin: "",
                timeoutSeconds: 6,
                maximumOutputCharacters: 50_000
            )
            // `claude auth status --json` exits non-zero while signed out but
            // still prints a usable status document, so decode stdout first and
            // fall back to the exit status only when nothing can be read.
            guard let data = process.stdout.data(using: .utf8),
                  let decoded = try? BridgeJSON.decoder.decode(
                      ClaudeAuthStatus.self,
                      from: data
                  )
            else {
                throw PlanUsageError.provider(
                    process.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            auth = decoded
        } catch {
            return QuotaEstimate(
                agent: .claude,
                source: .unavailable,
                statusMessage: "Could not verify Claude sign-in: \(concise(error))"
            )
        }

        guard auth.loggedIn else {
            return QuotaEstimate(
                agent: .claude,
                source: .unavailable,
                planName: auth.displayPlan,
                statusMessage: "Claude Code is signed out. Sign in to load plan usage."
            )
        }
        guard auth.authMethod == "claude.ai", auth.subscriptionType != nil else {
            return QuotaEstimate(
                agent: .claude,
                source: .unavailable,
                planName: auth.displayPlan,
                statusMessage: "Plan limits are only exposed for Claude.ai subscriptions."
            )
        }

        do {
            let transcript = try await PTYCommand.run(
                executable: executable,
                arguments: [
                    // `/usage` needs account data, not project instructions,
                    // hooks, MCP servers, plugins, Chrome, or folder discovery.
                    "--safe-mode",
                    "--no-chrome",
                ],
                currentDirectory: currentDirectory,
                input: "/usage\r",
                inputDelaySeconds: 2,
                timeoutSeconds: 12
            )
            var estimate = ClaudeUsageParser.parse(
                terminalTranscript: transcript,
                now: now
            )
            estimate.planName = estimate.planName ?? auth.displayPlan
            if estimate.windows.isEmpty {
                estimate.source = .unavailable
                estimate.fetchedAt = nil
                if transcript.localizedCaseInsensitiveContains("OAuth access token has expired") {
                    estimate.statusMessage = "Claude sign-in expired. Run claude auth login and retry."
                } else if transcript.localizedCaseInsensitiveContains("rate limited") {
                    estimate.statusMessage = "Claude's usage endpoint is temporarily rate limited."
                } else {
                    estimate.statusMessage = "Claude usage did not refresh. Run claude auth login, then retry."
                }
            }
            return estimate
        } catch {
            return QuotaEstimate(
                agent: .claude,
                source: .unavailable,
                planName: auth.displayPlan,
                statusMessage: "Claude usage unavailable: \(concise(error))"
            )
        }
    }

    private func ensureProbeDirectory() throws {
        try FileManager.default.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

public enum PlanUsageStore {
    public static func load() -> [String: QuotaEstimate] {
        guard let data = try? Data(contentsOf: BridgePaths.planUsageCache),
              let values = try? BridgeJSON.decoder.decode(
                  [String: QuotaEstimate].self,
                  from: data
              )
        else { return [:] }
        return values
    }

    public static func save(_ values: [String: QuotaEstimate]) throws {
        let url = BridgePaths.planUsageCache
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try BridgeJSON.encoder.encode(values).write(to: url, options: .atomic)
    }
}

enum CodexUsageParser {
    static func accountIdentityHash(result: [String: Any]) -> String? {
        guard let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt",
              let address = account["email"] as? String else { return nil }
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return TraceCrypto.digest(Data(("codex:chatgpt:" + normalized).utf8))
    }

    static func parse(line: String, now: Date) throws -> QuotaEstimate {
        guard let data = line.data(using: .utf8) else {
            throw PlanUsageError.invalidResponse("Codex returned invalid UTF-8.")
        }
        let envelope = try BridgeJSON.decoder.decode(CodexRPCEnvelope.self, from: data)
        guard let response = envelope.result else {
            throw PlanUsageError.invalidResponse(envelope.error?.message ?? "Missing result.")
        }
        return try parse(response: response, now: now)
    }

    static func parse(result: [String: Any], now: Date) throws -> QuotaEstimate {
        guard JSONSerialization.isValidJSONObject(result) else {
            throw PlanUsageError.invalidResponse("Codex returned an invalid rate-limit result.")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        let response = try BridgeJSON.decoder.decode(CodexRateLimitsResponse.self, from: data)
        return try parse(response: response, now: now)
    }

    private static func parse(
        response: CodexRateLimitsResponse,
        now: Date
    ) throws -> QuotaEstimate {
        // Never borrow a code-review or another model bucket's balance. The
        // named Codex bucket is authoritative, with only the documented
        // backward-compatible Codex snapshot as a fallback.
        let snapshot: CodexRateLimitSnapshot
        if let codex = response.codexRateLimits, codex.isCodex {
            snapshot = codex
        } else if let fallback = response.rateLimits, fallback.isCodex {
            snapshot = fallback
        } else {
            throw PlanUsageError.invalidResponse("Codex returned no Codex usage snapshot.")
        }
        let candidates: [(String, CodexRateLimitWindow?)] = [
            ("primary", snapshot.primary),
            ("secondary", snapshot.secondary),
        ]
        let windows = candidates.compactMap { key, value -> QuotaWindow? in
            // QuotaWindow's legacy initializer clamps. Validate at the
            // provider boundary so malformed usage is not recast as 0/100%.
            guard let value, (0...100).contains(value.usedPercent) else { return nil }
            return QuotaWindow(
                id: "codex-\(key)",
                label: label(
                    durationMinutes: value.windowDurationMinutes,
                    fallback: key.capitalized + " limit"
                ),
                usedRatio: Double(value.usedPercent) / 100,
                resetAt: value.resetsAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                },
                durationMinutes: value.windowDurationMinutes
            )
        }
        let credits = snapshot.credits?.normalized
        guard !windows.isEmpty || credits != nil
                || snapshot.rateLimitReachedType != nil
                || snapshot.spendControlReached != nil
                || response.availableResetCredits != nil else {
            throw PlanUsageError.invalidResponse("Codex returned no plan windows or credit data.")
        }
        let remaining = windows.map { 1 - $0.usedRatio }.min() ?? 1
        let limitedUntil = windows
            .filter { $0.usedRatio >= 1 }
            .compactMap(\.resetAt)
            .min()
        return QuotaEstimate(
            agent: .codex,
            available: !windows.isEmpty && snapshot.rateLimitReachedType == nil
                && snapshot.spendControlReached != true
                && !windows.contains(where: { $0.usedRatio >= 1 }),
            remainingRatio: remaining,
            limitedUntil: limitedUntil,
            windows: windows,
            source: .live,
            fetchedAt: now,
            planName: snapshot.planType?.displayName,
            statusMessage: "Provider-reported through Codex app-server.",
            credits: credits,
            limitID: snapshot.limitID ?? "codex",
            limitName: snapshot.limitName,
            rateLimitReachedType: snapshot.rateLimitReachedType,
            spendControlReached: snapshot.spendControlReached,
            availableResetCredits: response.availableResetCredits
        )
    }

    private static func label(durationMinutes: Int?, fallback: String) -> String {
        guard let durationMinutes else { return fallback }
        switch durationMinutes {
        case 280 ... 320:
            return "5-hour limit"
        case 9_900 ... 10_200:
            return "Weekly limit"
        default:
            let hours = durationMinutes / 60
            return hours > 0 ? "\(hours)-hour limit" : fallback
        }
    }
}

enum ClaudeUsageParser {
    private struct Descriptor {
        var id: String
        var label: String
        var expressions: [String]
        var durationMinutes: Int?
    }

    private static let descriptors = [
        Descriptor(
            id: "claude-five-hour",
            label: "5-hour limit",
            expressions: ["Current session", "5-hour limit"],
            durationMinutes: 300
        ),
        Descriptor(
            id: "claude-seven-day",
            label: "Weekly · all models",
            expressions: ["Current week (all models)", "Weekly · all models", "7-day limit"],
            durationMinutes: 10_080
        ),
        Descriptor(
            id: "claude-seven-day-model",
            label: "Weekly · model",
            expressions: [
                "Current week (Sonnet only)",
                "Current week (Opus only)",
                "Weekly · Sonnet",
                "Weekly · Opus",
                "Weekly · Fable",
            ],
            durationMinutes: 10_080
        ),
    ]

    static func parse(terminalTranscript: String, now: Date) -> QuotaEstimate {
        let clean = normalizedTerminalText(terminalTranscript)
        var windows: [QuotaWindow] = []
        for descriptor in descriptors {
            guard let match = lastMatch(
                expressions: descriptor.expressions,
                text: clean
            ) else { continue }
            let modelLabel = descriptor.id == "claude-seven-day-model"
                ? matchedModelLabel(in: match.segment) ?? descriptor.label
                : descriptor.label
            windows.append(
                QuotaWindow(
                    id: descriptor.id,
                    label: modelLabel,
                    usedRatio: match.percentage / 100,
                    resetAt: parseReset(in: match.segment, now: now, maximumMinutes: descriptor.durationMinutes),
                    durationMinutes: descriptor.durationMinutes
                )
            )
        }
        let remaining = windows.map { 1 - $0.usedRatio }.min() ?? 1
        let limitedUntil = windows
            .filter { $0.usedRatio >= 1 }
            .compactMap(\.resetAt)
            .min()
        return QuotaEstimate(
            agent: .claude,
            available: !windows.contains(where: { $0.usedRatio >= 1 }),
            remainingRatio: remaining,
            limitedUntil: limitedUntil,
            windows: windows,
            source: windows.isEmpty ? .unavailable : .live,
            fetchedAt: windows.isEmpty ? nil : now,
            planName: detectedPlanName(in: clean),
            statusMessage: windows.isEmpty
                ? "Claude returned no plan windows."
                : "Provider-reported through Claude Code `/usage`."
        )
    }

    private static func lastMatch(
        expressions: [String],
        text: String
    ) -> (percentage: Double, segment: String)? {
        let headings = descriptors.flatMap(\.expressions).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let headingsRegex = try? NSRegularExpression(pattern: headings, options: [.caseInsensitive]) else { return nil }
        let matches = headingsRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let wanted = Set(expressions.map { $0.lowercased() })
        guard let latest = matches.last(where: { match in
            Range(match.range, in: text).map { wanted.contains(text[$0].lowercased()) } ?? false
        }), let heading = Range(latest.range, in: text) else { return nil }
        let boundedEnd = text.index(heading.upperBound, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
        let nextHeading = matches.first { $0.range.location > latest.range.location }
            .flatMap { Range($0.range, in: text)?.lowerBound }
        let end = min(boundedEnd, nextHeading ?? text.endIndex)
        let segment = String(text[heading.lowerBound..<end])
        // Read the complete token before %, not a numeric suffix of -1%,
        // 1e3%, NaN%, or a malformed decimal. Never borrow a later window's
        // number or resurrect an older redraw as a newly fetched reading.
        guard let percentageRegex = try? NSRegularExpression(pattern: #"([^\s%]+)\s*%\s*(?:used)?"#, options: [.caseInsensitive]),
              let match = percentageRegex.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)),
              let range = Range(match.range(at: 1), in: segment) else { return nil }
        let raw = String(segment[range])
        guard raw.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let percentage = Double(raw), percentage.isFinite, (0...100).contains(percentage) else { return nil }
        return (percentage, segment)
    }

    private static func matchedModelLabel(in segment: String) -> String? {
        for model in ["Sonnet", "Opus", "Fable"] where
            segment.localizedCaseInsensitiveContains(model)
        {
            return "Weekly · \(model)"
        }
        return nil
    }

    private static func detectedPlanName(in text: String) -> String? {
        let pattern = #"(?i)Plan usage limits\s*[·•-]\s*(Max\s*\(\s*\d+x\s*\)|Pro|Team|Enterprise)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return "Claude " + String(text[range])
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
    }

    private static func parseReset(in segment: String, now: Date, maximumMinutes: Int?) -> Date? {
        let hourPattern = #"(?i)resets?\s+in\s+(\d+)\s*h(?:rs?|ours?)?(?:\s+(\d+)\s*m(?:in|inutes?)?)?"#
        if let regex = try? NSRegularExpression(pattern: hourPattern),
           let match = regex.firstMatch(
               in: segment,
               range: NSRange(segment.startIndex..., in: segment)
           ),
           let hourRange = Range(match.range(at: 1), in: segment),
           let hours = Int(segment[hourRange])
        {
            var minutes = 0
            if match.range(at: 2).location != NSNotFound,
               let minuteRange = Range(match.range(at: 2), in: segment)
            {
                guard let parsed = Int(segment[minuteRange]) else { return nil }
                minutes = parsed
            }
            let hoursInMinutes = hours.multipliedReportingOverflow(by: 60)
            guard !hoursInMinutes.overflow else { return nil }
            let duration = hoursInMinutes.partialValue.addingReportingOverflow(minutes)
            guard !duration.overflow else { return nil }
            return resetDate(minutes: duration.partialValue, now: now, maximumMinutes: maximumMinutes)
        }
        let minutePattern = #"(?i)resets?\s+in\s+(\d+)\s*m(?:in|inutes?)?"#
        if let regex = try? NSRegularExpression(pattern: minutePattern),
           let match = regex.firstMatch(
               in: segment,
               range: NSRange(segment.startIndex..., in: segment)
           ),
           let range = Range(match.range(at: 1), in: segment),
           let minutes = Int(segment[range])
        {
            return resetDate(minutes: minutes, now: now, maximumMinutes: maximumMinutes)
        }
        return nil
    }

    private static func resetDate(minutes: Int, now: Date, maximumMinutes: Int?) -> Date? {
        guard minutes >= 0, maximumMinutes.map({ minutes <= $0 }) ?? true,
              now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let seconds = minutes.multipliedReportingOverflow(by: 60)
        guard !seconds.overflow else { return nil }
        let reset = now.addingTimeInterval(TimeInterval(seconds.partialValue))
        return reset.timeIntervalSinceReferenceDate.isFinite ? reset : nil
    }

    private static func normalizedTerminalText(_ value: String) -> String {
        let escapePattern = #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\)|[78])"#
        let withoutEscapes = (try? NSRegularExpression(pattern: escapePattern))
            .map {
                $0.stringByReplacingMatches(
                    in: value,
                    range: NSRange(value.startIndex..., in: value),
                    withTemplate: " "
                )
            } ?? value
        let controls = withoutEscapes.unicodeScalars.map { scalar -> Character in
            if scalar.value == 10 || scalar.value == 13 || scalar.value >= 32 {
                return Character(String(scalar))
            }
            return " "
        }
        return String(controls)
            .replacingOccurrences(
                of: #"[ \t]+"#,
                with: " ",
                options: .regularExpression
            )
    }
}

private struct ClaudeAuthStatus: Decodable {
    var loggedIn: Bool
    var authMethod: String?
    var subscriptionType: String?

    var displayPlan: String? {
        subscriptionType.map { "Claude " + $0.capitalized }
    }
}

private struct CodexRPCEnvelope: Decodable {
    var id: Int?
    var result: CodexRateLimitsResponse?
    var error: CodexRPCError?
}

private struct CodexRPCError: Decodable {
    var message: String
}

private struct CodexRateLimitsResponse: Decodable {
    var rateLimits: CodexRateLimitSnapshot?
    var codexRateLimits: CodexRateLimitSnapshot?
    var availableResetCredits: Int?

    enum CodingKeys: String, CodingKey {
        case rateLimits, rateLimitResetCredits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }

    private enum LimitKeys: String, CodingKey { case codex }
    private enum ResetCreditKeys: String, CodingKey { case availableCount }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try? container.decode(CodexRateLimitSnapshot.self, forKey: .rateLimits)
        // Decode only the requested bucket; a malformed unrelated bucket
        // cannot invalidate otherwise usable Codex credits or windows.
        if let buckets = try? container.nestedContainer(keyedBy: LimitKeys.self, forKey: .rateLimitsByLimitID) {
            codexRateLimits = try? buckets.decode(CodexRateLimitSnapshot.self, forKey: .codex)
        }
        if let resetCredits = try? container.nestedContainer(keyedBy: ResetCreditKeys.self, forKey: .rateLimitResetCredits),
           let count = try? resetCredits.decode(Int.self, forKey: .availableCount), count >= 0 {
            availableResetCredits = count
        }
    }
}

private struct CodexRateLimitSnapshot: Decodable {
    var limitID: String?
    var limitName: String?
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var planType: CodexPlanType?
    var rateLimitReachedType: String?
    var spendControlReached: Bool?
    var credits: CodexCreditsSnapshot?

    var isCodex: Bool { limitID == nil || limitID == "codex" }

    enum CodingKeys: String, CodingKey {
        case primary, secondary, planType, rateLimitReachedType, spendControlReached, credits, limitName
        case limitID = "limitId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitID = try? container.decode(String.self, forKey: .limitID)
        limitName = try? container.decode(String.self, forKey: .limitName)
        // Windows, flags and credit data are independent provider facts. A
        // malformed or newly added field must not erase its valid siblings.
        primary = try? container.decode(CodexRateLimitWindow.self, forKey: .primary)
        secondary = try? container.decode(CodexRateLimitWindow.self, forKey: .secondary)
        planType = try? container.decode(CodexPlanType.self, forKey: .planType)
        rateLimitReachedType = try? container.decode(String.self, forKey: .rateLimitReachedType)
        spendControlReached = try? container.decode(Bool.self, forKey: .spendControlReached)
        credits = try? container.decode(CodexCreditsSnapshot.self, forKey: .credits)
    }
}

private struct CodexCreditsSnapshot: Decodable {
    var balance: String?
    var hasCredits: Bool?
    var unlimited: Bool?

    enum CodingKeys: String, CodingKey { case balance, hasCredits, unlimited }

    var normalized: QuotaCredits? {
        guard balance != nil || hasCredits != nil || unlimited != nil else { return nil }
        return QuotaCredits(balance: balance, hasCredits: hasCredits, unlimited: unlimited)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The app-server contract reports a decimal string, not a JSON number.
        // Validate its shape without converting through floating-point or
        // changing significant trailing zeros. Missing/malformed is unknown.
        balance = QuotaCredits.validatedBalance(try? container.decode(String.self, forKey: .balance))
        hasCredits = try? container.decode(Bool.self, forKey: .hasCredits)
        unlimited = try? container.decode(Bool.self, forKey: .unlimited)
    }
}

private struct CodexRateLimitWindow: Decodable {
    var usedPercent: Int
    var windowDurationMinutes: Int?
    var resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
    }
}

private enum CodexPlanType: String, Decodable {
    case free, go, plus, pro, prolite, team
    case selfServeBusinessUsageBased = "self_serve_business_usage_based"
    case business
    case enterpriseCBPUsageBased = "enterprise_cbp_usage_based"
    case enterprise, edu, unknown

    var displayName: String {
        switch self {
        case .selfServeBusinessUsageBased, .business:
            return "Business"
        case .enterpriseCBPUsageBased, .enterprise:
            return "Enterprise"
        case .prolite:
            return "Pro Lite"
        default:
            return rawValue.capitalized
        }
    }
}

private enum PlanUsageError: Error, LocalizedError {
    case provider(String)
    case invalidResponse(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .provider(message), let .invalidResponse(message), let .timeout(message):
            return message.isEmpty ? "Unknown provider error." : message
        }
    }
}

private enum PTYCommand {
    static func run(
        executable: URL,
        arguments: [String] = [],
        currentDirectory: URL,
        input: String,
        inputDelaySeconds: TimeInterval,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            try runSynchronously(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                input: input,
                inputDelaySeconds: inputDelaySeconds,
                timeoutSeconds: timeoutSeconds
            )
        }.value
    }

    private static func runSynchronously(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        input: String,
        inputDelaySeconds: TimeInterval,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 44, ws_col: 110, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PlanUsageError.provider("Could not create a terminal for Claude Code.")
        }
        defer {
            if master >= 0 { close(master) }
            if slave >= 0 { close(slave) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argumentStrings = [executable.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        let arguments = CStringArray(argumentStrings)
        let environmentValues = CStringArray(environmentStrings)
        defer {
            arguments.free()
            environmentValues.free()
        }

        var processID: pid_t = 0
        let spawnStatus = arguments.withUnsafeMutablePointer { argumentPointer in
            environmentValues.withUnsafeMutablePointer { environmentPointer in
                posix_spawn(
                    &processID,
                    executable.path,
                    &actions,
                    &attributes,
                    argumentPointer,
                    environmentPointer
                )
            }
        }
        guard spawnStatus == 0 else {
            throw PlanUsageError.provider(
                String(cString: strerror(spawnStatus))
            )
        }
        close(slave)
        slave = -1
        let existingFlags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, existingFlags | O_NONBLOCK)

        let start = Date()
        var sentInput = false
        var output = Data()
        var childExited = false
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if !sentInput, Date().timeIntervalSince(start) >= inputDelaySeconds {
                input.withCString { pointer in
                    _ = Darwin.write(master, pointer, strlen(pointer))
                }
                sentInput = true
            }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0, descriptor.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 32_768)
                let count = Darwin.read(master, &bytes, bytes.count)
                if count > 0, output.count < 1_500_000 {
                    output.append(bytes, count: count)
                }
            }
            var childStatus: Int32 = 0
            if waitpid(processID, &childStatus, WNOHANG) == processID {
                childExited = true
                break
            }
        }

        if !childExited {
            kill(-processID, SIGTERM)
            for _ in 0 ..< 10 {
                var childStatus: Int32 = 0
                if waitpid(processID, &childStatus, WNOHANG) == processID {
                    childExited = true
                    break
                }
                usleep(50_000)
            }
        }
        if !childExited {
            kill(-processID, SIGKILL)
            var childStatus: Int32 = 0
            waitpid(processID, &childStatus, 0)
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private final class CStringArray: @unchecked Sendable {
    private var storage: [UnsafeMutablePointer<CChar>?]

    init(_ values: [String]) {
        storage = values.map { strdup($0) }
        storage.append(nil)
    }

    func withUnsafeMutablePointer<T>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        try storage.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    func free() {
        for pointer in storage.dropLast() {
            Darwin.free(pointer)
        }
        storage = [nil]
    }
}

private func concise(_ error: Error) -> String {
    let message = error.localizedDescription.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    return message.isEmpty ? "unknown error" : String(message.prefix(180))
}

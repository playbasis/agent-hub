import Foundation

/// The two subscriptions the Bridge can link from inside the app. Each maps to
/// the provider's own CLI sign-in, so credentials are stored by Claude Code
/// and Codex themselves — the Bridge never reads or writes a token.
public enum LinkedProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    /// The subscription the user recognises, not the CLI that carries it.
    public var accountName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        }
    }

    public var toolName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        }
    }

    public var agent: AgentName {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// Claude Code opens the sign-in page itself; Codex's app-server hands
    /// the URL back and expects the client to open it.
    public var cliOpensBrowser: Bool { self == .claude }

    public var installURL: URL {
        switch self {
        case .claude: return URL(string: "https://docs.anthropic.com/en/docs/claude-code/quickstart")!
        case .codex: return URL(string: "https://developers.openai.com/codex/cli")!
        }
    }
}

public struct ProviderAccountStatus: Codable, Equatable, Sendable {
    public var provider: LinkedProvider
    public var installed: Bool
    public var linked: Bool
    /// `claude.ai`, `console`, `chatgpt`, `apikey`, or nil when signed out.
    public var method: String?
    public var email: String?
    public var planName: String?
    public var organization: String?
    public var cliVersion: String?
    public var checkedAt: Date
    public var message: String?

    public init(
        provider: LinkedProvider,
        installed: Bool,
        linked: Bool,
        method: String? = nil,
        email: String? = nil,
        planName: String? = nil,
        organization: String? = nil,
        cliVersion: String? = nil,
        checkedAt: Date = Date(),
        message: String? = nil
    ) {
        self.provider = provider
        self.installed = installed
        self.linked = linked
        self.method = method
        self.email = email
        self.planName = planName
        self.organization = organization
        self.cliVersion = cliVersion
        self.checkedAt = checkedAt
        self.message = message
    }

    /// True when the link is a consumer subscription rather than API billing —
    /// the only case in which plan windows are exposed by the provider.
    public var isSubscription: Bool {
        linked && (method == "claude.ai" || method == "chatgpt")
    }
}

public extension ProviderAccountStatus {
    /// Matches the non-secret account marker on a Codex credit reading without
    /// adding the account address to the persisted quota snapshot. An absent
    /// identity is not evidence that two readings belong to the same account.
    var creditAccountIdentityHash: String? {
        guard provider == .codex, linked, method == "chatgpt",
              let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedEmail.isEmpty
        else { return nil }
        return TraceCrypto.digest("codex:chatgpt:" + normalizedEmail)
    }
}

public enum AccountLinkPhase: Equatable, Sendable {
    case idle
    case preparing
    /// The provider has produced a sign-in URL. `code` is set for device-code
    /// flows where the user must also type a short code on the page.
    case awaitingBrowser(url: URL, code: String?)
    /// The CLI asked for a pasted authorization code (Claude Code falls back to
    /// this when its localhost callback cannot be reached).
    case awaitingCode(url: URL?)
    case verifying
    case linked(ProviderAccountStatus)
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .linked, .failed, .cancelled: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .awaitingBrowser, .awaitingCode, .verifying: return true
        default: return false
        }
    }
}

/// Pure text heuristics over CLI sign-in transcripts. Kept free of I/O so the
/// exact strings each CLI prints can be pinned by tests.
public enum AccountLinkParser {
    public static func signInURL(in transcript: String) -> URL? {
        let text = TerminalText.normalize(transcript)
        let pattern = #"https://[A-Za-z0-9.\-]+(?::\d+)?/[^\s"'<>]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let candidates = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
            .map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)")) }
        let preferred = candidates.first {
            $0.contains("oauth") || $0.contains("authorize") || $0.contains("/login") || $0.contains("device")
        }
        return (preferred ?? candidates.first).flatMap(URL.init(string:))
    }

    /// Device-code flows print a short grouped code such as `ABCD-EFGH`.
    public static func deviceCode(in transcript: String) -> String? {
        let text = TerminalText.normalize(transcript)
        let pattern = #"\b([A-Z0-9]{4,5}-[A-Z0-9]{4,5})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    public static func promptsForCode(_ transcript: String) -> Bool {
        let text = TerminalText.normalize(transcript).lowercased()
        return text.contains("paste code") || text.contains("paste the code")
            || text.contains("enter the code") || text.contains("authorization code")
    }

    public static func indicatesSuccess(_ transcript: String) -> Bool {
        let text = TerminalText.normalize(transcript).lowercased()
        return text.contains("login successful") || text.contains("logged in")
            || text.contains("successfully logged in") || text.contains("successfully authenticated")
    }

    public static func failureMessage(_ transcript: String) -> String? {
        let text = TerminalText.normalize(transcript)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let markers = ["error", "failed", "invalid", "denied", "expired", "could not", "unable"]
        return lines.last { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }
    }
}

/// Drives each provider's own sign-in from inside the app and reports the
/// resulting account. Credentials stay in the provider's store; the Bridge only
/// observes the CLI transcript or the documented app-server API.
public actor AccountLinker {
    private let configuration: AgentConfiguration
    private let currentDirectory: URL
    private var activeTerminal: PseudoTerminalProcess?
    private var activeSession: CodexAppServerSession?
    private var activeLoginID: String?
    private var activeTask: Task<Void, Never>?

    public init(configuration: AgentConfiguration, currentDirectory: URL? = nil) {
        self.configuration = configuration
        self.currentDirectory = currentDirectory ?? BridgePaths.providerProbeDirectory
    }

    // MARK: Status

    public func status(_ provider: LinkedProvider) async -> ProviderAccountStatus {
        switch provider {
        case .claude: return await claudeStatus()
        case .codex: return await codexStatus()
        }
    }

    private func claudeStatus() async -> ProviderAccountStatus {
        guard let executable = try? resolve(configuration.claudeCommand) else {
            return ProviderAccountStatus(
                provider: .claude, installed: false, linked: false,
                message: "Claude Code is not installed or not on PATH."
            )
        }
        async let version = cliVersion(executable, arguments: ["--version"])
        do {
            try ensureProbeDirectory()
            let process = try await ProcessRunner.run(
                executable: executable.path,
                arguments: ["auth", "status", "--json"],
                currentDirectory: currentDirectory,
                stdin: "",
                timeoutSeconds: 8,
                maximumOutputCharacters: 50_000
            )
            guard let data = process.stdout.data(using: .utf8),
                  let decoded = try? BridgeJSON.decoder.decode(ClaudeAuthDocument.self, from: data)
            else {
                throw BridgeError.processFailed(
                    process.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return ProviderAccountStatus(
                provider: .claude,
                installed: true,
                linked: decoded.loggedIn,
                method: decoded.loggedIn ? decoded.authMethod : nil,
                email: decoded.email,
                planName: decoded.planName,
                organization: decoded.orgName,
                cliVersion: await version,
                message: decoded.loggedIn ? nil : "Sign in with your Claude subscription to link it."
            )
        } catch {
            return ProviderAccountStatus(
                provider: .claude, installed: true, linked: false,
                cliVersion: await version,
                message: "Could not read Claude Code sign-in: \(concise(error))"
            )
        }
    }

    private func codexStatus() async -> ProviderAccountStatus {
        guard let executable = try? resolve(configuration.codexCommand) else {
            return ProviderAccountStatus(
                provider: .codex, installed: false, linked: false,
                message: "Codex CLI is not installed or not on PATH."
            )
        }
        async let version = cliVersion(executable, arguments: ["--version"])
        do {
            try ensureProbeDirectory()
            let session = try await CodexAppServerSession(executable: executable, currentDirectory: currentDirectory)
            defer { session.close() }
            let result = try await session.request("account/read", params: ["refreshToken": false], timeoutSeconds: 10)
            return CodexAccountParser.status(from: result, cliVersion: await version)
        } catch {
            // The app-server is experimental; fall back to the plain status
            // command, which at least says whether a login exists.
            if let output = try? await ProcessRunner.run(
                executable: executable.path,
                arguments: ["login", "status"],
                currentDirectory: currentDirectory,
                stdin: "",
                timeoutSeconds: 8,
                maximumOutputCharacters: 10_000
            ) {
                let text = (output.stdout + "\n" + output.stderr).lowercased()
                let linked = text.contains("logged in")
                return ProviderAccountStatus(
                    provider: .codex,
                    installed: true,
                    linked: linked,
                    method: linked ? (text.contains("api key") ? "apikey" : "chatgpt") : nil,
                    cliVersion: await version,
                    message: linked ? nil : "Sign in with your ChatGPT account to link it."
                )
            }
            return ProviderAccountStatus(
                provider: .codex, installed: true, linked: false,
                cliVersion: await version,
                message: "Could not read Codex sign-in: \(concise(error))"
            )
        }
    }

    // MARK: Linking

    /// Starts the provider's sign-in and streams progress. Only one link runs
    /// at a time; starting another cancels the previous one.
    public func link(_ provider: LinkedProvider) -> AsyncStream<AccountLinkPhase> {
        cancelActive()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { [self] in
                continuation.yield(.preparing)
                let final: AccountLinkPhase
                switch provider {
                case .claude: final = await linkClaude(report: { continuation.yield($0) })
                case .codex: final = await linkCodex(report: { continuation.yield($0) })
                }
                clearActive()
                continuation.yield(final)
                continuation.finish()
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Supplies a pasted authorization code to a waiting Claude sign-in.
    public func submitCode(_ code: String) {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        activeTerminal?.write(cleaned + "\r")
    }

    public func cancel() {
        cancelActive()
    }

    public func unlink(_ provider: LinkedProvider) async -> ProviderAccountStatus {
        cancelActive()
        let command = provider == .claude ? configuration.claudeCommand : configuration.codexCommand
        let arguments = provider == .claude ? ["auth", "logout"] : ["logout"]
        if let executable = try? resolve(command) {
            try? ensureProbeDirectory()
            _ = try? await ProcessRunner.run(
                executable: executable.path,
                arguments: arguments,
                currentDirectory: currentDirectory,
                stdin: "",
                timeoutSeconds: 15,
                maximumOutputCharacters: 20_000
            )
        }
        return await status(provider)
    }

    private func linkClaude(report: @escaping @Sendable (AccountLinkPhase) -> Void) async -> AccountLinkPhase {
        let executable: URL
        do {
            try ensureProbeDirectory()
            executable = try resolve(configuration.claudeCommand)
        } catch {
            return .failed("Claude Code is not installed or not on PATH.")
        }
        let terminal: PseudoTerminalProcess
        do {
            terminal = try PseudoTerminalProcess(
                executable: executable,
                arguments: ["auth", "login", "--claudeai"],
                currentDirectory: currentDirectory,
                columns: 1_000
            )
        } catch {
            return .failed("Could not start Claude Code sign-in: \(concise(error))")
        }
        activeTerminal = terminal

        var transcript = ""
        var reportedURL: URL?
        var reportedCodePrompt = false
        var reportedSuccess = false
        for await chunk in terminal.output {
            if Task.isCancelled {
                terminal.terminate()
                return .cancelled
            }
            transcript += chunk
            if transcript.count > 200_000 { transcript = String(transcript.suffix(100_000)) }
            if reportedURL == nil, let url = AccountLinkParser.signInURL(in: transcript) {
                reportedURL = url
                report(.awaitingBrowser(url: url, code: AccountLinkParser.deviceCode(in: transcript)))
            }
            if !reportedCodePrompt, AccountLinkParser.promptsForCode(transcript) {
                reportedCodePrompt = true
                report(.awaitingCode(url: reportedURL))
            }
            if !reportedSuccess, AccountLinkParser.indicatesSuccess(transcript) {
                reportedSuccess = true
                report(.verifying)
                // Claude Code waits on a final keypress after success.
                terminal.write("\r")
            }
        }
        let exit = await terminal.waitForExit()
        if Task.isCancelled { return .cancelled }
        report(.verifying)
        let status = await claudeStatus()
        if status.linked { return .linked(status) }
        let reason = AccountLinkParser.failureMessage(transcript)
            ?? (exit == 0 ? "Claude Code finished without signing in." : "Claude Code sign-in exited with status \(exit).")
        return .failed(reason)
    }

    private func linkCodex(report: @escaping @Sendable (AccountLinkPhase) -> Void) async -> AccountLinkPhase {
        let executable: URL
        do {
            try ensureProbeDirectory()
            executable = try resolve(configuration.codexCommand)
        } catch {
            return .failed("Codex CLI is not installed or not on PATH.")
        }
        let session: CodexAppServerSession
        do {
            session = try await CodexAppServerSession(executable: executable, currentDirectory: currentDirectory)
        } catch {
            return .failed("Could not start Codex: \(concise(error))")
        }
        activeSession = session
        defer { session.close() }

        let loginID: String
        do {
            let started = try await session.request("account/login/start", params: ["type": "chatgpt"], timeoutSeconds: 15)
            guard let raw = started["authUrl"] as? String, let url = URL(string: raw) else {
                return .failed("Codex did not return a sign-in URL.")
            }
            loginID = started["loginId"] as? String ?? ""
            activeLoginID = loginID
            report(.awaitingBrowser(url: url, code: nil))
        } catch {
            return .failed("Codex sign-in could not start: \(concise(error))")
        }

        // Codex notifies on completion, but polling the account is what makes
        // the outcome authoritative — and it survives a renamed notification.
        let deadline = Date().addingTimeInterval(15 * 60)
        var completionError: String?
        let notifications = Task<String?, Never> {
            for await notification in session.notifications {
                guard let method = notification["method"] as? String,
                      method.hasPrefix("account/login")
                else { continue }
                let params = notification["params"] as? [String: Any] ?? [:]
                if let error = params["error"] as? String, !error.isEmpty {
                    return error
                }
                if params["success"] as? Bool == false {
                    return "Sign-in was not completed."
                }
                if params["success"] as? Bool == true || method.contains("completed") {
                    return ""
                }
            }
            return nil
        }
        while Date() < deadline {
            if Task.isCancelled {
                notifications.cancel()
                _ = try? await session.request("account/login/cancel", params: ["loginId": loginID], timeoutSeconds: 5)
                return .cancelled
            }
            if let account = try? await session.request("account/read", params: ["refreshToken": false], timeoutSeconds: 10),
               let status = Optional(CodexAccountParser.status(from: account, cliVersion: nil)),
               status.linked
            {
                notifications.cancel()
                report(.verifying)
                var verified = status
                verified.cliVersion = await cliVersion(executable, arguments: ["--version"])
                return .linked(verified)
            }
            if notifications.isCancelled == false, let outcome = await withTimeout(seconds: 2, of: notifications) {
                if let outcome, !outcome.isEmpty {
                    completionError = outcome
                    break
                }
            }
        }
        if Task.isCancelled { return .cancelled }
        _ = try? await session.request("account/login/cancel", params: ["loginId": loginID], timeoutSeconds: 5)
        return .failed(completionError ?? "Sign-in timed out before ChatGPT confirmed the account.")
    }

    /// Waits up to `seconds` for a task to finish; nil means it is still running.
    private func withTimeout<T: Sendable>(seconds: Double, of task: Task<T, Never>) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func cancelActive() {
        activeTask?.cancel()
        activeTask = nil
        activeTerminal?.terminate()
        activeTerminal = nil
        activeSession?.close()
        activeSession = nil
        activeLoginID = nil
    }

    private func clearActive() {
        activeTask = nil
        activeTerminal = nil
        activeSession = nil
        activeLoginID = nil
    }

    // MARK: Helpers

    private func resolve(_ command: String) throws -> URL {
        try ExecutableLocator.resolve(command)
    }

    private func ensureProbeDirectory() throws {
        try FileManager.default.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func cliVersion(_ executable: URL, arguments: [String]) async -> String? {
        guard let output = try? await ProcessRunner.run(
            executable: executable.path,
            arguments: arguments,
            currentDirectory: currentDirectory,
            stdin: "",
            timeoutSeconds: 6,
            maximumOutputCharacters: 2_000
        ) else { return nil }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\d+\.\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return text.isEmpty ? nil : text }
        return String(text[range])
    }

    private func concise(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "unknown error" : String(message.prefix(180))
    }
}

struct ClaudeAuthDocument: Decodable, Equatable {
    var loggedIn: Bool
    var authMethod: String?
    var subscriptionType: String?
    var email: String?
    var orgName: String?

    var planName: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        return "Claude " + subscriptionType.capitalized
    }
}

enum CodexAccountParser {
    static func status(from result: [String: Any], cliVersion: String?) -> ProviderAccountStatus {
        guard let account = result["account"] as? [String: Any] else {
            return ProviderAccountStatus(
                provider: .codex, installed: true, linked: false,
                cliVersion: cliVersion,
                message: "Sign in with your ChatGPT account to link it."
            )
        }
        let type = (account["type"] as? String ?? "").lowercased()
        let plan = (account["planType"] as? String).map(planName)
        return ProviderAccountStatus(
            provider: .codex,
            installed: true,
            linked: true,
            method: type == "chatgpt" ? "chatgpt" : (type.isEmpty ? nil : type),
            email: account["email"] as? String,
            planName: plan,
            cliVersion: cliVersion
        )
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "self_serve_business_usage_based", "business": return "ChatGPT Business"
        case "enterprise_cbp_usage_based", "enterprise": return "ChatGPT Enterprise"
        case "prolite": return "ChatGPT Pro Lite"
        case "free": return "ChatGPT Free"
        default: return "ChatGPT " + raw.capitalized
        }
    }
}

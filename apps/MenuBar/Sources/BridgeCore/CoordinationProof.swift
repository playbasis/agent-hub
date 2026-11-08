import Foundation

public enum CoordinationAgentPreflight {
    public static func requireReady(
        configuration: AgentConfiguration
    ) async throws {
        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bridge-agent-preflight-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: probeDirectory) }

        var bounded = configuration
        bounded.subprocessTimeoutSeconds = min(
            configuration.subprocessTimeoutSeconds,
            60
        )
        bounded.maxOutputCharacters = min(
            configuration.maxOutputCharacters,
            20_000
        )

        do {
            let claude = try await ClaudeRunner(configuration: bounded).run(
                project: probeDirectory,
                prompt: "Reply with exactly CLAUDE_READY and nothing else. Do not use tools.",
                nativeSessionID: nil,
                bridgeSessionID: "preflight"
            )
            guard claude.success,
                  claude.output.localizedCaseInsensitiveContains("CLAUDE_READY")
            else {
                throw BridgeError.configuration(
                    "Claude live preflight failed: "
                        + concise(claude.error ?? claude.output)
                )
            }
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.configuration(
                "Claude live preflight failed: \(concise(error.localizedDescription))"
            )
        }

        bounded.codexSandbox = "read-only"
        bounded.codexSkipGitRepositoryCheck = true
        do {
            let codex = try await CodexRunner(configuration: bounded).run(
                project: probeDirectory,
                prompt: "Reply with exactly CODEX_READY and nothing else. Do not use tools.",
                nativeSessionID: nil,
                bridgeSessionID: "preflight"
            )
            guard codex.success,
                  codex.output.localizedCaseInsensitiveContains("CODEX_READY")
            else {
                throw BridgeError.configuration(
                    "Codex live preflight failed: "
                        + concise(codex.error ?? codex.output)
                )
            }
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.configuration(
                "Codex live preflight failed: \(concise(error.localizedDescription))"
            )
        }
    }

    private static func concise(_ value: String) -> String {
        let compact = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return compact.isEmpty ? "no diagnostic output" : String(compact.prefix(500))
    }
}

public struct CoordinationProofRequirement: Codable, Equatable, Sendable {
    public var id: String
    public var passed: Bool
    public var evidence: String
}

public struct CoordinationProjectVerification: Codable, Equatable, Sendable {
    public var packagePresent: Bool
    public var designPresent: Bool
    public var implementationPresent: Bool
    public var reviewPresent: Bool
    public var reviewDeclaredPass: Bool
    public var swiftTestPassed: Bool
    public var swiftTestExitCode: Int?
    public var swiftTestTimedOut: Bool
    public var swiftTestOutputTail: String?

    enum CodingKeys: String, CodingKey {
        case packagePresent = "package_present"
        case designPresent = "design_present"
        case implementationPresent = "implementation_present"
        case reviewPresent = "review_present"
        case reviewDeclaredPass = "review_declared_pass"
        case swiftTestPassed = "swift_test_passed"
        case swiftTestExitCode = "swift_test_exit_code"
        case swiftTestTimedOut = "swift_test_timed_out"
        case swiftTestOutputTail = "swift_test_output_tail"
    }
}

public struct CoordinationProofReport: Codable, Equatable, Sendable {
    public var schemaVersion = "1.1"
    public var createdAt: Date
    public var sessionID: String?
    public var finalState: SessionState
    public var totalTurns: Int
    public var claudeSuccessfulTurns: Int
    public var codexSuccessfulTurns: Int
    public var geminiDecisions: Int
    public var fallbackDecisions: Int
    public var crossAgentHandoffs: Int
    public var geminiHeardClaudeEvents: Int
    public var geminiHeardCodexEvents: Int
    public var projectVerification: CoordinationProjectVerification
    public var requirements: [CoordinationProofRequirement]
    public var passed: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case sessionID = "session_id"
        case finalState = "final_state"
        case totalTurns = "total_turns"
        case claudeSuccessfulTurns = "claude_successful_turns"
        case codexSuccessfulTurns = "codex_successful_turns"
        case geminiDecisions = "gemini_decisions"
        case fallbackDecisions = "fallback_decisions"
        case crossAgentHandoffs = "cross_agent_handoffs"
        case geminiHeardClaudeEvents = "gemini_heard_claude_events"
        case geminiHeardCodexEvents = "gemini_heard_codex_events"
        case projectVerification = "project_verification"
        case requirements, passed
    }
}

public enum CoordinationProjectVerifier {
    public static func verify(project: URL) async -> CoordinationProjectVerification {
        let package = project.appendingPathComponent("Package.swift")
        let design = project.appendingPathComponent("DESIGN.md")
        let implementation = project.appendingPathComponent("IMPLEMENTATION.md")
        let review = project.appendingPathComponent("REVIEW.md")
        let fileManager = FileManager.default
        let packagePresent = fileManager.fileExists(atPath: package.path)
        let reviewContent = try? String(contentsOf: review, encoding: .utf8)

        var exitCode: Int?
        var timedOut = false
        var outputTail: String?
        if packagePresent {
            do {
                let result = try await ProcessRunner.run(
                    executable: "swift",
                    arguments: ["test"],
                    currentDirectory: project,
                    stdin: "",
                    timeoutSeconds: 300,
                    maximumOutputCharacters: 20_000
                )
                exitCode = Int(result.status)
                timedOut = result.timedOut
                let combined = [result.stdout, result.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !combined.isEmpty {
                    outputTail = String(combined.suffix(4_000))
                }
            } catch {
                outputTail = String(error.localizedDescription.suffix(4_000))
            }
        }

        return CoordinationProjectVerification(
            packagePresent: packagePresent,
            designPresent: fileManager.fileExists(atPath: design.path),
            implementationPresent: fileManager.fileExists(atPath: implementation.path),
            reviewPresent: reviewContent != nil,
            reviewDeclaredPass: reviewContent.map(hasExplicitPass) ?? false,
            swiftTestPassed: exitCode == 0 && !timedOut,
            swiftTestExitCode: exitCode,
            swiftTestTimedOut: timedOut,
            swiftTestOutputTail: outputTail
        )
    }

    static func hasExplicitPass(_ review: String) -> Bool {
        review.split(separator: "\n").contains { rawLine in
            let line = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "#*- _`")
                )
            return ["PASS", "STATUS: PASS", "RESULT: PASS", "VERDICT: PASS"]
                .contains(line)
        }
    }
}

public enum CoordinationProofAuditor {
    public static func audit(
        status: BridgeStatus,
        store: ProjectStore,
        projectVerification: CoordinationProjectVerification
    ) -> CoordinationProofReport {
        let events = store.recentEvents(limit: 10_000)
        let decisions = store.recentDecisionValues(limit: 10_000)

        let claudeSuccessful = events.filter {
            $0.source == .claude && $0.type == .turnComplete
        }.count
        let codexSuccessful = events.filter {
            $0.source == .codex && $0.type == .turnComplete
        }.count

        var geminiDecisions = 0
        var fallbackDecisions = 0
        var crossAgentHandoffs = 0
        var heardClaude = 0
        var heardCodex = 0

        for value in decisions {
            guard let record = value.objectValue,
                  let coordinator = record["coordinator"]?.objectValue,
                  coordinator["provider"]?.stringValue == "gemini"
            else { continue }
            let fallback = coordinator["fallback_active"]?.boolValue ?? true
            let ready = coordinator["state"]?.stringValue == ProviderState.ready.rawValue
            if fallback || !ready {
                fallbackDecisions += 1
            } else {
                geminiDecisions += 1
            }

            let from = record["from_agent"]?.stringValue
            let to = record["to_agent"]?.stringValue
            let action = record["decision"]?.objectValue?["action"]?.stringValue
            if from == AgentName.claude.rawValue { heardClaude += 1 }
            if from == AgentName.codex.rawValue { heardCodex += 1 }
            if action == DecisionAction.handoff.rawValue,
               Set([from, to]) == Set([
                   AgentName.claude.rawValue,
                   AgentName.codex.rawValue,
               ])
            {
                crossAgentHandoffs += 1
            }
        }

        let requirements = [
            requirement(
                id: "terminal-completion",
                passed: status.state == .complete,
                evidence: "Final bridge state: \(status.state.rawValue)"
            ),
            requirement(
                id: "claude-contributed",
                passed: claudeSuccessful > 0,
                evidence: "\(claudeSuccessful) successful Claude turn(s)"
            ),
            requirement(
                id: "codex-contributed",
                passed: codexSuccessful > 0,
                evidence: "\(codexSuccessful) successful Codex turn(s)"
            ),
            requirement(
                id: "gemini-no-fallback",
                passed: geminiDecisions > 0 && fallbackDecisions == 0,
                evidence: "\(geminiDecisions) validated Gemini decision(s), "
                    + "\(fallbackDecisions) fallback decision(s)"
            ),
            requirement(
                id: "gemini-heard-both-agents",
                passed: heardClaude > 0 && heardCodex > 0,
                evidence: "Gemini routed \(heardClaude) Claude event(s) and "
                    + "\(heardCodex) Codex event(s)"
            ),
            requirement(
                id: "cross-agent-handoff",
                passed: crossAgentHandoffs > 0,
                evidence: "\(crossAgentHandoffs) Claude↔Codex handoff(s)"
            ),
            requirement(
                id: "multi-turn-session",
                passed: (status.session?.turnCount ?? 0) >= 3,
                evidence: "\(status.session?.turnCount ?? 0) managed agent turn(s)"
            ),
            requirement(
                id: "canonical-artifacts",
                passed: projectVerification.packagePresent
                    && projectVerification.designPresent
                    && projectVerification.implementationPresent
                    && projectVerification.reviewPresent,
                evidence: "Package.swift=\(projectVerification.packagePresent), "
                    + "DESIGN.md=\(projectVerification.designPresent), "
                    + "IMPLEMENTATION.md=\(projectVerification.implementationPresent), "
                    + "REVIEW.md=\(projectVerification.reviewPresent)"
            ),
            requirement(
                id: "independent-review-pass",
                passed: projectVerification.reviewDeclaredPass,
                evidence: "REVIEW.md declared an explicit PASS: "
                    + "\(projectVerification.reviewDeclaredPass)"
            ),
            requirement(
                id: "independent-swift-test",
                passed: projectVerification.swiftTestPassed,
                evidence: "Verifier swift test exit code: "
                    + (projectVerification.swiftTestExitCode.map(String.init) ?? "not run")
                    + ", timed out: \(projectVerification.swiftTestTimedOut)"
            ),
        ]

        return CoordinationProofReport(
            createdAt: Date(),
            sessionID: status.session?.id,
            finalState: status.state,
            totalTurns: status.session?.turnCount ?? 0,
            claudeSuccessfulTurns: claudeSuccessful,
            codexSuccessfulTurns: codexSuccessful,
            geminiDecisions: geminiDecisions,
            fallbackDecisions: fallbackDecisions,
            crossAgentHandoffs: crossAgentHandoffs,
            geminiHeardClaudeEvents: heardClaude,
            geminiHeardCodexEvents: heardCodex,
            projectVerification: projectVerification,
            requirements: requirements,
            passed: requirements.allSatisfy(\.passed)
        )
    }

    public static func save(
        _ report: CoordinationProofReport,
        to url: URL
    ) throws {
        try BridgeJSON.encoder.encode(report).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func requirement(
        id: String,
        passed: Bool,
        evidence: String
    ) -> CoordinationProofRequirement {
        CoordinationProofRequirement(id: id, passed: passed, evidence: evidence)
    }
}

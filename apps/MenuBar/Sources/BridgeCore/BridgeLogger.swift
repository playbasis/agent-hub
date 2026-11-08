import Foundation

public actor BridgeLogger {
    public static let shared = BridgeLogger(file: defaultSharedFile(
        executablePath: sharedExecutablePath(),
        temporaryDirectory: FileManager.default.temporaryDirectory,
        processID: ProcessInfo.processInfo.processIdentifier
    ))
    public let file: URL

    /// Only the process-wide test logger is redirected. Normal application
    /// paths, bundle identity and explicitly supplied log files are unchanged.
    static func defaultSharedFile(executablePath: String, temporaryDirectory: URL, processID: Int32) -> URL {
        guard isTestExecutable(executablePath) else { return BridgePaths.logs.appendingPathComponent("bridge.jsonl") }
        return temporaryDirectory
            .appendingPathComponent("ClaudeCodexBridgeTests-\(processID)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bridge.jsonl")
    }

    private static func isTestExecutable(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathComponents.contains { $0.lowercased().hasSuffix(".xctest") }
    }

    private static func sharedExecutablePath() -> String {
        let executable = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? ""
        if isTestExecutable(executable) { return executable }
        // Apple's xctest host can own the main executable while the package's
        // actual executable lives in a loaded .xctest bundle. Never rely on an
        // environment flag that could redirect a normal app's audit history.
        return Bundle.allBundles.compactMap { $0.executableURL?.path }.first(where: isTestExecutable) ?? executable
    }

    public init(file: URL = BridgePaths.logs.appendingPathComponent("bridge.jsonl")) {
        self.file = file
    }

    public func log(
        _ level: String = "INFO",
        _ message: String,
        fields: [String: JSONValue] = [:]
    ) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let record: JSONValue = .object([
                "timestamp": .string(ISO8601.withFractional.string(from: Date())),
                "level": .string(level),
                "message": .string(message),
                "fields": .object(redacted(fields)),
            ])
            var data = try BridgeJSON.compactEncoder.encode(record)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never take down the orchestrator.
        }
    }

    public func recent(limit: Int) -> [JSONValue] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").suffix(limit).compactMap {
            try? BridgeJSON.decoder.decode(JSONValue.self, from: Data($0.utf8))
        }
    }

    private func redacted(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        let sensitive = ["authorization", "bearer_token", "api_key", "token", "password", "secret"]
        return fields.mapValues { $0 }.reduce(into: [:]) { result, pair in
            result[pair.key] = sensitive.contains(pair.key.lowercased())
                ? .string("***redacted***")
                : pair.value
        }
    }
}


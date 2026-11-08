import Foundation

/// Keeps only the minimum state required to advertise a resumable session.
///
/// The snapshot lives in the app's own Application Support directory. Startup
/// can therefore restore a paused session without probing Documents, Desktop,
/// Downloads, or every path in the recent-project list. The project is opened
/// lazily only after the user explicitly resumes it.
public enum SessionRecoveryStore {
    public static func load() throws -> RuntimeSession? {
        let url = BridgePaths.recoverySnapshot
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try BridgeJSON.decoder.decode(
            RuntimeSession.self,
            from: Data(contentsOf: url)
        )
    }

    public static func save(_ session: RuntimeSession?) throws {
        let url = BridgePaths.recoverySnapshot
        guard let session, !isTerminal(session.state) else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try BridgeJSON.encoder.encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func isTerminal(_ state: SessionState) -> Bool {
        [.complete, .stopped, .error].contains(state)
    }
}

import Foundation

/// Stores remote coordinator credentials outside config.json.
///
/// Environment variables take precedence for CI. Durable local credentials
/// live in a dedicated `0600` file under this app's private Application Support
/// directory. This is intentional for ad-hoc development builds: macOS assigns
/// them an unstable Keychain identity and otherwise presents a password dialog
/// after rebuilds. A Developer ID release can swap this adapter back to
/// Keychain without changing callers or the on-disk public configuration.
public enum CoordinatorSecretStore {
    public static func resolve(environmentVariable: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[environmentVariable],
           !value.isEmpty
        {
            return value
        }
        return try? load(account: environmentVariable)
    }

    public static func load(
        account: String,
        from url: URL = BridgePaths.coordinatorCredentials
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let document = try decode(Data(contentsOf: url))
        return document.credentials[account]
    }

    public static func save(
        _ secret: String,
        account: String,
        to url: URL = BridgePaths.coordinatorCredentials
    ) throws {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw BridgeError.configuration("Coordinator API key cannot be empty")
        }

        var document: CredentialDocument
        if FileManager.default.fileExists(atPath: url.path) {
            document = try decode(Data(contentsOf: url))
        } else {
            document = CredentialDocument()
        }
        document.credentials[account] = value
        try persist(document, to: url)
    }

    public static func remove(
        account: String,
        from url: URL = BridgePaths.coordinatorCredentials
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var document = try decode(Data(contentsOf: url))
        document.credentials.removeValue(forKey: account)
        if document.credentials.isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            try persist(document, to: url)
        }
    }

    private static func decode(_ data: Data) throws -> CredentialDocument {
        do {
            let document = try BridgeJSON.decoder.decode(
                CredentialDocument.self,
                from: data
            )
            guard document.schemaVersion == "1.0" else {
                throw BridgeError.configuration(
                    "Unsupported coordinator credential schema"
                )
            }
            return document
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.configuration(
                "Could not read the private coordinator credential file: "
                    + error.localizedDescription
            )
        }
    }

    private static func persist(
        _ document: CredentialDocument,
        to url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try BridgeJSON.encoder.encode(document).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private struct CredentialDocument: Codable {
    var schemaVersion = "1.0"
    var credentials: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case credentials
    }
}

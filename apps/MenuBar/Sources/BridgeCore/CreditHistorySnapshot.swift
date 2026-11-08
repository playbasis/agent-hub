import Foundation
import Darwin

public enum CreditHistoryExport {
    /// Exclusive owner-only creation; never briefly publish financial data at
    /// default umask permissions or overwrite a selected existing file.
    public static func write(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw BridgeError.invalidRequest("Choose a local export file.") }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw CreditHistoryError.io("create a new private export (existing files are not overwritten)") }
        defer { _ = Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CreditHistoryError.io("finish the private export; a partial file may remain") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw CreditHistoryError.io("flush the private export") }
    }
}

/// Account observations remain separate from optional local token-price
/// equivalents. No caller may reconcile them into an invented billing ledger.
public struct CreditHistorySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = "credit-report/1"
    public var history: CreditHistoryReport
    public var currentScope: CreditHistoryScope
    public var recordingWarning: String?
    public var providerRefreshFailedAt: Date? = nil
    public var isCurrentScope: Bool { history.selectedScope == currentScope }
}

public struct CreditHistoryQuery: Equatable, Sendable {
    public enum Window: String, CaseIterable, Sendable { case day = "24h", week = "7d", all }
    public var window: Window
    public var scopeID: String?
    public init(window: Window = .day, scopeID: String? = nil) { self.window = window; self.scopeID = scopeID }
    public init(query: [String: String]) throws {
        guard let window = Window(rawValue: query["window"] ?? "24h") else {
            throw BridgeError.invalidRequest("Credit history window must be 24h, 7d or all.")
        }
        if let scope = query["scope"], scope.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) == nil {
            throw BridgeError.invalidRequest("Credit history scope is invalid.")
        }
        self.init(window: window, scopeID: query["scope"])
    }
    public func from(at now: Date) -> Date {
        switch window {
        case .day: return now.addingTimeInterval(-86_400)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .all: return Date(timeIntervalSince1970: 0)
        }
    }
    public func path(export: Bool = false) -> String {
        var components = URLComponents()
        components.path = export ? "/credits/export" : "/credits/history"
        components.queryItems = [URLQueryItem(name: "window", value: window.rawValue)]
        if let scopeID { components.queryItems?.append(.init(name: "scope", value: scopeID)) }
        return components.string ?? "/credits/history?window=24h"
    }
}

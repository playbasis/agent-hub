import CryptoKit
import Foundation

/// Display and copy rules for runtime logs. The append-only source remains
/// untouched; every presentation surface receives the same sanitized record.
public enum BridgeLogPresentation {
    public enum Level: String, CaseIterable, Identifiable, Sendable {
        case all, errors, warnings, info, debug, raw
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: return "All levels"
            case .errors: return "Errors"
            case .warnings: return "Warnings"
            case .info: return "Info"
            case .debug: return "Debug"
            case .raw: return "Unstructured"
            }
        }

        public func includes(_ value: String) -> Bool {
            switch self {
            case .all: return true
            case .errors: return ["ERROR", "FAULT", "FATAL", "CRITICAL"].contains(value.uppercased())
            case .warnings: return ["WARN", "WARNING"].contains(value.uppercased())
            case .info: return ["INFO", "NOTICE"].contains(value.uppercased())
            case .debug: return ["DEBUG", "TRACE"].contains(value.uppercased())
            case .raw: return value.uppercased() == "RAW"
            }
        }
    }

    public static func sanitized(_ entry: BridgeLogEntry) -> BridgeLogEntry {
        let sanitizedLine: String
        if let value = json(entry.rawLine, maximumCharacters: 16_384) {
            sanitizedLine = value
        } else {
            sanitizedLine = text(entry.rawLine, maximumCharacters: 16_384)
        }
        let summary: String?
        if let fields = entry.fieldsSummary,
           let value = json(fields, maximumCharacters: 4_096) {
            summary = value
        } else {
            summary = entry.fieldsSummary.map { text($0, maximumCharacters: 4_096) }
        }
        return BridgeLogEntry(
            id: SHA256.hash(data: Data(entry.id.utf8)).map { String(format: "%02x", $0) }.joined(),
            timestamp: entry.timestamp.map { text($0, maximumCharacters: 80) },
            level: text(entry.level, maximumCharacters: 30),
            message: text(entry.message, maximumCharacters: 4_096),
            fieldsSummary: summary,
            rawLine: sanitizedLine,
            isStructured: entry.isStructured
        )
    }

    public static func entries(_ entries: [BridgeLogEntry], query: String = "", level: Level = .all) -> [BridgeLogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard level.includes(entry.level) else { return false }
            return needle.isEmpty || [entry.message, entry.level, entry.timestamp ?? "", entry.fieldsSummary ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    /// Sanitize again at the clipboard boundary, even when called outside the
    /// logs view with entries read directly from disk.
    public static func copyText(_ entries: [BridgeLogEntry]) -> String {
        entries.map { sanitized($0).rawLine }.joined(separator: "\n")
    }

    /// One readable key/value pair per top-level field, for chips in the
    /// log list. Nested values stay compact JSON; nothing is escaped twice.
    public static func fieldPairs(_ summary: String?) -> [(key: String, value: String)] {
        guard let summary, let data = summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().map { key in
            let value = object[key]
            let rendered: String
            switch value {
            case let string as String: rendered = string
            case let number as NSNumber:
                rendered = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            case is NSNull, .none: rendered = "—"
            case let .some(other):
                if JSONSerialization.isValidJSONObject(other),
                   let nested = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys, .withoutEscapingSlashes]) {
                    rendered = String(decoding: nested, as: UTF8.self)
                } else { rendered = String(describing: other) }
            }
            return (key.replacingOccurrences(of: "_", with: " "), rendered)
        }
    }

    /// Display wording for runtime messages. The audit source keeps the
    /// original text; only the product name people see changes.
    public static func displayMessage(_ message: String) -> String {
        switch message {
        case "Recorded hook event during managed turn": return "Claude reported progress during a step"
        case "Restored paused session snapshot": return "Restored a paused session"
        default: break
        }
        return message
            .replacingOccurrences(of: "Bridge runtime", with: "\(BridgeBrand.shortName)")
            .replacingOccurrences(of: "bridge runtime", with: "\(BridgeBrand.shortName)")
            .replacingOccurrences(of: "bridge session", with: "relay session")
            .replacingOccurrences(of: "Bridge session", with: "Relay session")
    }

    /// ISO-8601 log timestamps, parsed for local display.
    public static func date(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: timestamp) { return date }
        return ISO8601DateFormatter().date(from: timestamp)
    }

    public static func text(_ value: String, maximumCharacters: Int = 4_096) -> String {
        let quoted = value.replacingOccurrences(
            of: #"(?i)([\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|authorization|cookie|credentials?|private[_-]?key)[\"']?\s*[:=]\s*)(?:\"(?:[^\"\\]|\\.)*\"|'[^']*'|[^\s,;}]+)"#,
            with: "$1[REDACTED]",
            options: .regularExpression
        )
        return TraceRedactor.redact(quoted, maximumCharacters: max(0, maximumCharacters))
    }

    /// Keep JSON valid even when the source exceeds the presentation limit.
    /// Cutting a serialized string used to make every field chip disappear.
    private static func json(_ source: String, maximumCharacters: Int) -> String? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var remaining = maximumCharacters / 2
        let sanitized = redact(object, remaining: &remaining)
        guard let encoded = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        let result = String(decoding: encoded, as: UTF8.self)
        guard result.count <= maximumCharacters else {
            return #"{"display note":"[TRUNCATED: event details exceed the display limit]"}"#
        }
        return result
    }

    private static func redact(_ object: Any, depth: Int = 0, remaining: inout Int) -> Any {
        guard depth < 16, remaining > 0 else { return "[TRUNCATED]" }
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted().prefix(64) {
                guard remaining > 0 else { result["display note"] = "[TRUNCATED]"; break }
                guard let value = dictionary[key] else { continue }
                let displayedKey = text(key, maximumCharacters: min(120, remaining))
                remaining -= displayedKey.count + 8
                let normalized = key.lowercased().filter(\.isLetter)
                let sensitive = ["apikey", "accesstoken", "refreshtoken", "authtoken", "secret", "password", "authorization", "authorizationheader", "cookie", "credentials", "credential", "privatekey", "secretaccesskey"].contains { normalized.hasSuffix($0) }
                    || normalized == "token" || normalized.contains("secret")
                    || (normalized.hasSuffix("token") && value is String)
                result[displayedKey] = sensitive ? "[REDACTED]" : redact(value, depth: depth + 1, remaining: &remaining)
            }
            if dictionary.count > 64 { result["display note"] = "[TRUNCATED: additional fields omitted]" }
            return result
        }
        if let array = object as? [Any] {
            var result: [Any] = []
            for value in array.prefix(200) {
                guard remaining > 0 else { result.append("[TRUNCATED]"); break }
                remaining -= 2
                result.append(redact(value, depth: depth + 1, remaining: &remaining))
            }
            if array.count > 200 { result.append("[TRUNCATED]") }
            return result
        }
        if let value = object as? String {
            let result = text(value, maximumCharacters: min(4_096, max(0, remaining)))
            remaining -= result.count + 2
            return result
        }
        remaining -= 24
        return object
    }
}

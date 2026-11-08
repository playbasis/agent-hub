import Foundation

public struct BridgeLogEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var timestamp: String?
    public var level: String
    public var message: String
    public var fieldsSummary: String?
    public var rawLine: String
    public var isStructured: Bool

    public init(
        id: String,
        timestamp: String?,
        level: String,
        message: String,
        fieldsSummary: String?,
        rawLine: String,
        isStructured: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.fieldsSummary = fieldsSummary
        self.rawLine = rawLine
        self.isStructured = isStructured
    }
}

public struct BridgeLogSnapshot: Equatable, Sendable {
    public var entries: [BridgeLogEntry]
    public var fileSize: UInt64
    public var modifiedAt: Date?
    public var wasTruncated: Bool

    public init(
        entries: [BridgeLogEntry] = [],
        fileSize: UInt64 = 0,
        modifiedAt: Date? = nil,
        wasTruncated: Bool = false
    ) {
        self.entries = entries
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.wasTruncated = wasTruncated
    }
}

/// Reads only the tail of the append-only JSONL log so opening the viewer stays
/// fast even after a long-running bridge session.
public enum BridgeLogReader {
    public static func read(
        file: URL = BridgePaths.logs.appendingPathComponent("bridge.jsonl"),
        maxBytes: Int = 2 * 1_024 * 1_024,
        maxEntries: Int = 2_000
    ) throws -> BridgeLogSnapshot {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let byteLimit = UInt64(max(1, maxBytes))
        let offset = fileSize > byteLimit ? fileSize - byteLimit : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()

        // A tail read can start halfway through a UTF-8 string or JSON object.
        // Discard that first partial line before decoding.
        if offset > 0 {
            if let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex ... newline)
            } else {
                data.removeAll(keepingCapacity: false)
            }
        }

        let allLines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        let entryLimit = max(1, maxEntries)
        let lines = allLines.suffix(entryLimit)
        let entries = lines.enumerated().map { position, line in
            parse(line: String(line), position: position)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return BridgeLogSnapshot(
            entries: entries,
            fileSize: fileSize,
            modifiedAt: attributes?[.modificationDate] as? Date,
            wasTruncated: offset > 0 || allLines.count > entryLimit
        )
    }

    private static func parse(line: String, position: Int) -> BridgeLogEntry {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return BridgeLogEntry(
                id: "raw-\(position)-\(line)",
                timestamp: nil,
                level: "RAW",
                message: line,
                fieldsSummary: nil,
                rawLine: line,
                isStructured: false
            )
        }

        let timestamp = dictionary["timestamp"] as? String
        let level = (dictionary["level"] as? String) ?? "INFO"
        let message = (dictionary["message"] as? String) ?? line
        let fieldsSummary: String?
        if let fields = dictionary["fields"] as? [String: Any],
           !fields.isEmpty,
           JSONSerialization.isValidJSONObject(fields),
           let fieldsData = try? JSONSerialization.data(
               withJSONObject: fields,
               options: [.sortedKeys]
           )
        {
            fieldsSummary = String(decoding: fieldsData, as: UTF8.self)
        } else {
            fieldsSummary = nil
        }
        return BridgeLogEntry(
            id: "\(position)-\(timestamp ?? "")-\(line)",
            timestamp: timestamp,
            level: level,
            message: message,
            fieldsSummary: fieldsSummary,
            rawLine: line,
            isStructured: true
        )
    }
}

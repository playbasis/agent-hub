import Foundation

/// Validates documents against the repository's JSON Schemas (draft 2020-12),
/// for the keywords those schemas use: type, enum, const, properties,
/// required, additionalProperties, patternProperties, items, min/max items,
/// uniqueItems, min/max length, pattern, minimum/maximum (compared exactly),
/// allOf/anyOf/oneOf, if/then/else and $ref (local and sibling files).
/// Formats are annotations, except date-time, which is checked.
public struct JSONSchemaCheck {
    public struct Failure: Equatable, CustomStringConvertible, Sendable {
        public var path: String
        public var message: String
        public var description: String { "\(path): \(message)" }
    }

    private let directory: URL
    private var documents: [String: ContractJSONValue] = [:]

    /// `directory` holds the schema files; `$ref`s to sibling files resolve there.
    public init(directory: URL) { self.directory = directory }

    public mutating func validate(_ instance: ContractJSONValue, against file: String, definition: String? = nil) throws -> [Failure] {
        let root = try document(file)
        var schema = root
        if let definition {
            guard let resolved = root["$defs"]?[definition] else { throw ContractError(file, "has no $defs/\(definition)") }
            schema = resolved
        }
        var failures: [Failure] = []
        try check(instance, schema, file: file, path: "$", failures: &failures)
        return failures
    }

    public mutating func validate(_ data: Data, against file: String, definition: String? = nil) throws -> [Failure] {
        try validate(ContractJSONValue.parse(data), against: file, definition: definition)
    }

    private mutating func document(_ file: String) throws -> ContractJSONValue {
        if let cached = documents[file] { return cached }
        let value = try ContractJSONValue.parse(Data(contentsOf: directory.appendingPathComponent(file)))
        documents[file] = value
        return value
    }

    private mutating func resolve(_ reference: String, from file: String) throws -> (ContractJSONValue, String) {
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].isEmpty ? file : String(parts[0])
        var value = try document(target)
        if parts.count > 1, !parts[1].isEmpty {
            for token in parts[1].split(separator: "/") {
                let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let next = value[key] else { throw ContractError(reference, "doesn't resolve") }
                value = next
            }
        }
        return (value, target)
    }

    private mutating func check(_ instance: ContractJSONValue, _ schema: ContractJSONValue, file: String, path: String, failures: inout [Failure]) throws {
        if case .bool(let allowed) = schema {
            if !allowed { failures.append(Failure(path: path, message: "is not allowed")) }
            return
        }
        guard case .object(let keywords) = schema else { throw ContractError(path, "schema must be an object") }
        func fail(_ message: String) { failures.append(Failure(path: path, message: message)) }

        if let reference = keywords["$ref"]?.stringValue {
            let (target, targetFile) = try resolve(reference, from: file)
            try check(instance, target, file: targetFile, path: path, failures: &failures)
        }
        if let types = keywords["type"] {
            let names = types.arrayValue?.compactMap(\.stringValue) ?? types.stringValue.map { [$0] } ?? []
            if !names.contains(where: { Self.matches(instance, type: $0) }) { fail("must be \(names.joined(separator: " or "))") }
        }
        if let options = keywords["enum"]?.arrayValue, !options.contains(where: { Self.equal($0, instance) }) { fail("is not one of the allowed values") }
        if let constant = keywords["const"], !Self.equal(constant, instance) { fail("must equal the constant") }

        switch instance {
        case .string(let text):
            let length = text.unicodeScalars.count
            if let minimum = keywords["minLength"].flatMap(Self.integer), length < minimum { fail("is shorter than \(minimum)") }
            if let maximum = keywords["maxLength"].flatMap(Self.integer), length > maximum { fail("is longer than \(maximum)") }
            if let pattern = keywords["pattern"]?.stringValue, text.range(of: pattern, options: .regularExpression) == nil { fail("doesn't match \(pattern)") }
            if keywords["format"]?.stringValue == "date-time", ContractTime.date(text) == nil { fail("is not an RFC 3339 date-time") }
        case .number(let text):
            if let minimum = keywords["minimum"], case .number(let bound) = minimum, Self.compare(text, bound) == .orderedAscending { fail("is below \(bound)") }
            if let maximum = keywords["maximum"], case .number(let bound) = maximum, Self.compare(text, bound) == .orderedDescending { fail("is above \(bound)") }
        case .array(let items):
            if let minimum = keywords["minItems"].flatMap(Self.integer), items.count < minimum { fail("has fewer than \(minimum) items") }
            if let maximum = keywords["maxItems"].flatMap(Self.integer), items.count > maximum { fail("has more than \(maximum) items") }
            if keywords["uniqueItems"] == .bool(true) {
                for (index, item) in items.enumerated() where items[..<index].contains(where: { Self.equal($0, item) }) { fail("item \(index) repeats an earlier item") }
            }
            if let itemSchema = keywords["items"] {
                for (index, item) in items.enumerated() { try check(item, itemSchema, file: file, path: "\(path)[\(index)]", failures: &failures) }
            }
        case .object(let fields):
            for name in keywords["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil { fail("is missing \"\(name)\"") }
            let properties = keywords["properties"]?.objectValue ?? [:]
            let patterns = keywords["patternProperties"]?.objectValue ?? [:]
            for key in fields.keys.sorted() {
                let value = fields[key]!
                var matched = false
                if let propertySchema = properties[key] { matched = true; try check(value, propertySchema, file: file, path: "\(path).\(key)", failures: &failures) }
                for (pattern, patternSchema) in patterns where key.range(of: pattern, options: .regularExpression) != nil {
                    matched = true
                    try check(value, patternSchema, file: file, path: "\(path).\(key)", failures: &failures)
                }
                if !matched, let additional = keywords["additionalProperties"] {
                    if additional == .bool(false) { fail("has unexpected property \"\(key)\"") }
                    else { try check(value, additional, file: file, path: "\(path).\(key)", failures: &failures) }
                }
            }
        default: break
        }

        for sub in keywords["allOf"]?.arrayValue ?? [] { try check(instance, sub, file: file, path: path, failures: &failures) }
        if let options = keywords["anyOf"]?.arrayValue {
            var passed = false
            for option in options {
                if try probe(instance, option, file: file) { passed = true; break }
            }
            if !passed { fail("matches none of anyOf") }
        }
        if let options = keywords["oneOf"]?.arrayValue {
            var count = 0
            for option in options {
                if try probe(instance, option, file: file) { count += 1 }
            }
            if count != 1 { fail("matches \(count) of oneOf, not exactly one") }
        }
        if let condition = keywords["if"] {
            if try probe(instance, condition, file: file) {
                if let then = keywords["then"] { try check(instance, then, file: file, path: path, failures: &failures) }
            } else if let otherwise = keywords["else"] { try check(instance, otherwise, file: file, path: path, failures: &failures) }
        }
    }

    private mutating func probe(_ instance: ContractJSONValue, _ schema: ContractJSONValue, file: String) throws -> Bool {
        var failures: [Failure] = []
        try check(instance, schema, file: file, path: "$", failures: &failures)
        return failures.isEmpty
    }

    private static func matches(_ value: ContractJSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.null, "null"), (.bool, "boolean"), (.string, "string"), (.array, "array"), (.object, "object"), (.number, "number"): return true
        case (.number(let text), "integer"): return !text.contains(".") && !text.lowercased().contains("e")
        default: return false
        }
    }

    private static func integer(_ value: ContractJSONValue) -> Int? {
        if case .number(let text) = value { return Int(text) }
        return nil
    }

    private static func equal(_ lhs: ContractJSONValue, _ rhs: ContractJSONValue) -> Bool {
        if case .number(let a) = lhs, case .number(let b) = rhs { return compare(a, b) == .orderedSame }
        return lhs == rhs
    }

    /// Compares integer literals exactly, whatever their size; other numbers
    /// through Decimal.
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func integerParts(_ text: String) -> (negative: Bool, digits: String)? {
            guard !text.contains("."), !text.lowercased().contains("e") else { return nil }
            let negative = text.hasPrefix("-")
            let digits = String(text.drop { $0 == "-" }.drop { $0 == "0" })
            return (negative && !digits.isEmpty, digits.isEmpty ? "0" : digits)
        }
        if let a = integerParts(lhs), let b = integerParts(rhs) {
            if a.negative != b.negative { return a.negative ? .orderedAscending : .orderedDescending }
            let magnitude: ComparisonResult = a.digits.count != b.digits.count
                ? (a.digits.count < b.digits.count ? .orderedAscending : .orderedDescending)
                : (a.digits == b.digits ? .orderedSame : (a.digits < b.digits ? .orderedAscending : .orderedDescending))
            guard a.negative, magnitude != .orderedSame else { return magnitude }
            return magnitude == .orderedAscending ? .orderedDescending : .orderedAscending
        }
        let posix = Locale(identifier: "en_US_POSIX")
        guard let a = Decimal(string: lhs, locale: posix), let b = Decimal(string: rhs, locale: posix) else { return .orderedSame }
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
}

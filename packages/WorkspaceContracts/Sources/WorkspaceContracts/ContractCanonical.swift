#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// A parsed JSON document that keeps every number's exact text, so large
/// integers survive validation and digests unchanged.
public indirect enum ContractJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([ContractJSONValue])
    case object([String: ContractJSONValue])

    public static func parse(_ data: Data, maximumDepth: Int = 64) throws -> ContractJSONValue {
        var parser = Parser(bytes: Array(data), maximumDepth: maximumDepth)
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ContractError("$", "unexpected text after the JSON value") }
        return value
    }

    public subscript(key: String) -> ContractJSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var objectValue: [String: ContractJSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var arrayValue: [ContractJSONValue]? { if case .array(let value) = self { return value }; return nil }

    /// Removes the named top-level fields and every `x-` extension, at any depth.
    public func removing(_ keys: Set<String>) -> ContractJSONValue {
        guard case .object(var fields) = self else { return self }
        for key in keys { fields.removeValue(forKey: key) }
        return ContractJSONValue.object(fields).withoutExtensions()
    }

    public func withoutExtensions() -> ContractJSONValue {
        switch self {
        case .object(let fields):
            var kept: [String: ContractJSONValue] = [:]
            for (key, value) in fields where !key.hasPrefix("x-") { kept[key] = value.withoutExtensions() }
            return .object(kept)
        case .array(let items): return .array(items.map { $0.withoutExtensions() })
        default: return self
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        let maximumDepth: Int
        var index = 0

        init(bytes: [UInt8], maximumDepth: Int) { self.bytes = bytes; self.maximumDepth = maximumDepth }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> ContractJSONValue {
            guard depth <= maximumDepth else { throw ContractError("$", "JSON is nested too deeply") }
            skipWhitespace()
            guard index < bytes.count else { throw ContractError("$", "unexpected end of JSON") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var fields: [String: ContractJSONValue] = [:]
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(fields) }
                while true {
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ContractError("$", "object keys must be strings") }
                    let key = try string()
                    guard fields[key] == nil else { throw ContractError("$", "duplicate key \"\(key)\"") }
                    skipWhitespace()
                    try expect(UInt8(ascii: ":"))
                    fields[key] = try value(depth: depth + 1)
                    skipWhitespace()
                    guard index < bytes.count else { throw ContractError("$", "unterminated object") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return .object(fields)
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [ContractJSONValue] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    items.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard index < bytes.count else { throw ContractError("$", "unterminated array") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return .array(items)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else { throw ContractError("$", "expected \"\(Character(Unicode.Scalar(byte)))\"") }
            index += 1
        }

        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index ..< index + expected.count]) == expected else {
                throw ContractError("$", "invalid literal")
            }
            index += expected.count
        }

        mutating func number() throws -> String {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, (48 ... 57).contains(bytes[index]) else { throw ContractError("$", "invalid number") }
            if bytes[index] == 48 { index += 1 } else { while index < bytes.count, (48 ... 57).contains(bytes[index]) { index += 1 } }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, (48 ... 57).contains(bytes[index]) else { throw ContractError("$", "invalid number") }
                while index < bytes.count, (48 ... 57).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, (48 ... 57).contains(bytes[index]) else { throw ContractError("$", "invalid number") }
                while index < bytes.count, (48 ... 57).contains(bytes[index]) { index += 1 }
            }
            return String(decoding: bytes[start ..< index], as: UTF8.self)
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run = index
            func flush(_ end: Int) { scalars.append(contentsOf: String(decoding: bytes[run ..< end], as: UTF8.self).unicodeScalars) }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { flush(index); index += 1; return String(scalars) }
                guard byte >= 0x20 else { throw ContractError("$", "unescaped control character in string") }
                if byte != UInt8(ascii: "\\") { index += 1; continue }
                flush(index)
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800 ... 0xDBFF).contains(code) {
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw ContractError("$", "unpaired surrogate")
                        }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00 ... 0xDFFF).contains(low) else { throw ContractError("$", "unpaired surrogate") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw ContractError("$", "invalid escape") }
                    scalars.append(scalar)
                default: throw ContractError("$", "invalid escape")
                }
                run = index
            }
            throw ContractError("$", "unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index ..< index + 4], as: UTF8.self), radix: 16) else {
                throw ContractError("$", "invalid unicode escape")
            }
            index += 4
            return value
        }
    }
}

/// RFC 8785 canonical JSON for the contracts' value space. Contract documents
/// that are digested carry integers only (money, hours and tokens are
/// strings), so a fractional or exponent number is rejected, not reformatted.
public enum CanonicalJSON {
    public static func data(_ value: ContractJSONValue) throws -> Data {
        var output = ""
        try write(value, to: &output)
        return Data(output.utf8)
    }

    /// Encodes with the contract encoder, then canonicalizes the wire form.
    public static func data<T: Encodable>(of value: T, removing keys: Set<String> = []) throws -> Data {
        let parsed = try ContractJSONValue.parse(ContractJSON.encoder.encode(value))
        return try data(parsed.removing(keys))
    }

    private static func write(_ value: ContractJSONValue, to output: inout String) throws {
        switch value {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let text):
            guard !text.contains("."), !text.lowercased().contains("e"), let integer = Int64(text) else {
                throw ContractError("$", "digested documents carry integers only; \(text) is not one")
            }
            output += String(integer)
        case .string(let text): writeString(text, to: &output)
        case .array(let items):
            output += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { output += "," }
                try write(item, to: &output)
            }
            output += "]"
        case .object(let fields):
            output += "{"
            // RFC 8785 orders keys by UTF-16 code units.
            let keys = fields.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (offset, key) in keys.enumerated() {
                if offset > 0 { output += "," }
                writeString(key, to: &output)
                output += ":"
                try write(fields[key]!, to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 { output += String(format: "\\u%04x", scalar.value) } else { output.unicodeScalars.append(scalar) }
            }
        }
        output += "\""
    }
}

/// SHA-256: CryptoKit where it exists, plain Swift elsewhere, so the
/// contracts build wherever Foundation does.
public enum ContractDigest {
    /// `sha256:<64 lowercase hex>` of the bytes.
    public static func sha256(_ data: Data) -> String { "sha256:" + hex(data) }

    public static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return render(Array(SHA256.hash(data: data)))
        #else
        return render(portableHash(Array(data)))
        #endif
    }

    /// The portable implementation, kept testable on every platform.
    static func portableHex(_ data: Data) -> String { render(portableHash(Array(data))) }

    private static func render(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined()
    }

    /// Digest of a value's canonical JSON with `keys` (and `x-` fields) left out.
    public static func of<T: Encodable>(_ value: T, removing keys: Set<String> = []) throws -> String {
        sha256(try CanonicalJSON.data(of: value, removing: keys))
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func portableHash(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }
        var words = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for index in 0 ..< 16 {
                let offset = chunk + index * 4
                words[index] = UInt32(padded[offset]) << 24 | UInt32(padded[offset + 1]) << 16 | UInt32(padded[offset + 2]) << 8 | UInt32(padded[offset + 3])
            }
            for index in 16 ..< 64 {
                let s0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let s1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0 ..< 64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choice &+ k[index] &+ words[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
        return state.flatMap { word in (0 ..< 4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }
}

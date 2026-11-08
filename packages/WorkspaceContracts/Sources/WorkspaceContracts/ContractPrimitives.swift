import Foundation

/// Wire rules shared by every workspace contract: UTC timestamps at millisecond
/// precision, sorted keys and unescaped slashes. Readers ignore fields they
/// don't know; producers may add `x-` fields that schemas allow.
public enum ContractJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ContractTime.string(date))
        }
        return encoder
    }

    public static var prettyEncoder: JSONEncoder {
        let encoder = encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ContractTime.date(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Timestamps are ISO 8601 with a time zone")
            }
            return date
        }
        return decoder
    }
}

public enum ContractTime {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// `2026-11-06T10:00:00.000Z`.
    public static func string(_ date: Date) -> String { fractional.string(from: date) }

    public static func date(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        return fractional.date(from: value) ?? whole.date(from: value)
    }

    /// The instant the wire carries: compare dates only after this, so a value
    /// and its decoded copy fall on the same side of every boundary.
    public static func normalized(_ date: Date) -> Date? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        return Self.date(string(date))
    }
}

public struct ContractError: Error, Equatable, CustomStringConvertible, Sendable {
    public var field: String
    public var reason: String
    public init(_ field: String, _ reason: String) { self.field = field; self.reason = reason }
    public var description: String { "\(field): \(reason)" }
}

/// A token count on the wire: a canonical base-10 string from 0 to 2^63−1,
/// so no reader rounds it. Missing (null) is unknown, never zero.
public struct TokenQuantity: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: Int64

    public init?(_ value: Int) {
        guard value >= 0 else { return nil }
        self.value = Int64(value)
    }

    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 19, bytes.allSatisfy({ (48 ... 57).contains($0) }),
              bytes.count == 1 || bytes[0] != 48, let value = Int64(text) else { return nil }
        self.value = value
    }

    private init(unchecked value: Int64) { self.value = value }

    public static let zero = TokenQuantity(unchecked: 0)
    public var description: String { String(value) }
    public var intValue: Int { Int(value) }

    /// nil when the sum would leave the supported range.
    public func adding(_ other: TokenQuantity) -> TokenQuantity? {
        let sum = value.addingReportingOverflow(other.value)
        return sum.overflow ? nil : TokenQuantity(unchecked: sum.partialValue)
    }

    public func subtracting(_ other: TokenQuantity) -> TokenQuantity? {
        other.value <= value ? TokenQuantity(unchecked: value - other.value) : nil
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = TokenQuantity(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Token quantities are canonical base-10 strings from 0 to 9223372036854775807")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Money, hours and ratios on the wire: a decimal string with at most 18
/// integer and 6 fraction digits and no exponent. Producers write the
/// canonical form (no trailing fraction zeros, no "-0"); arithmetic stays in
/// Foundation Decimal, so every reader gets the same value.
public struct ExactDecimal: Codable, Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    public static let maximumIntegerDigits = 18
    public static let maximumFractionDigits = 6
    public let decimal: Decimal

    public init?(_ text: String) {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integer = Substring(parts[0])
        if integer.hasPrefix("-") { integer = integer.dropFirst() }
        let fraction = parts.count > 1 ? parts[1] : nil
        guard !integer.isEmpty, integer.count <= Self.maximumIntegerDigits, integer.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              integer.count == 1 || integer.first != "0",
              fraction.map({ !$0.isEmpty && $0.count <= Self.maximumFractionDigits && $0.utf8.allSatisfy({ (48 ... 57).contains($0) }) }) ?? true,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        decimal = value
    }

    /// Rounds to six fraction digits; nil outside the wire range.
    public init?(_ decimal: Decimal) {
        guard !decimal.isNaN, let value = Self.bounded(Self.round(decimal, scale: Self.maximumFractionDigits, mode: .bankers)) else { return nil }
        self.decimal = value
    }

    public init(integerLiteral value: Int) { decimal = Decimal(value) }

    public static let zero: ExactDecimal = 0

    public var description: String {
        var text = NSDecimalNumber(decimal: decimal).stringValue
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    public var isNegative: Bool { decimal < 0 }

    public func adding(_ other: ExactDecimal) -> ExactDecimal? { ExactDecimal(decimal + other.decimal) }
    public func subtracting(_ other: ExactDecimal) -> ExactDecimal? { ExactDecimal(decimal - other.decimal) }
    public func multiplied(by other: ExactDecimal) -> ExactDecimal? { ExactDecimal(decimal * other.decimal) }
    public func divided(by other: ExactDecimal) -> ExactDecimal? {
        guard other.decimal != 0 else { return nil }
        return ExactDecimal(decimal / other.decimal)
    }

    /// Money is shown in cents (or the currency's minor unit), halves to even.
    public func rounded(scale: Int) -> ExactDecimal {
        ExactDecimal(Self.round(decimal, scale: scale, mode: .bankers)) ?? self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.decimal < rhs.decimal }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.decimal == rhs.decimal }
    public func hash(into hasher: inout Hasher) { hasher.combine(description) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = ExactDecimal(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Decimals are strings with up to 18 integer and 6 fraction digits")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func round(_ value: Decimal, scale: Int, mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, scale, mode)
        return output
    }

    private static func bounded(_ value: Decimal) -> Decimal? {
        let limit = Decimal(string: "1000000000000000000")!
        return value < limit && value > -limit ? value : nil
    }
}

public struct MoneyAmount: Codable, Hashable, Sendable {
    public var amount: ExactDecimal
    /// ISO 4217 code, such as USD or THB.
    public var currency: String

    public init(amount: ExactDecimal, currency: String) {
        self.amount = amount; self.currency = currency
    }

    public static func isCurrency(_ code: String) -> Bool {
        code.utf8.count == 3 && code.utf8.allSatisfy { (65 ... 90).contains($0) }
    }

    public func validate(_ field: String, allowNegative: Bool = false) throws {
        guard Self.isCurrency(currency) else { throw ContractError(field + ".currency", "must be an ISO 4217 code") }
        guard allowNegative || !amount.isNegative else { throw ContractError(field + ".amount", "must not be negative") }
    }
}

/// A low / base / high estimate in one unit (hours, money, person-days).
public struct EstimateRange: Codable, Hashable, Sendable {
    public var low: ExactDecimal
    public var base: ExactDecimal
    public var high: ExactDecimal

    public init(low: ExactDecimal, base: ExactDecimal, high: ExactDecimal) {
        self.low = low; self.base = base; self.high = high
    }

    public func validate(_ field: String, allowNegative: Bool = false) throws {
        guard low <= base, base <= high else { throw ContractError(field, "needs low ≤ base ≤ high") }
        guard allowNegative || !low.isNegative else { throw ContractError(field + ".low", "must not be negative") }
    }

    public func adding(_ other: EstimateRange) -> EstimateRange? {
        guard let low = low.adding(other.low), let base = base.adding(other.base), let high = high.adding(other.high) else { return nil }
        return EstimateRange(low: low, base: base, high: high)
    }

    public func multiplied(by factor: ExactDecimal) -> EstimateRange? {
        guard let low = low.multiplied(by: factor), let base = base.multiplied(by: factor), let high = high.multiplied(by: factor) else { return nil }
        return factor.isNegative ? EstimateRange(low: high, base: base, high: low) : EstimateRange(low: low, base: base, high: high)
    }

    public func divided(by divisor: ExactDecimal) -> EstimateRange? {
        guard let low = low.divided(by: divisor), let base = base.divided(by: divisor), let high = high.divided(by: divisor) else { return nil }
        return divisor.isNegative ? EstimateRange(low: high, base: base, high: low) : EstimateRange(low: low, base: base, high: high)
    }

    public func rounded(scale: Int) -> EstimateRange {
        EstimateRange(low: low.rounded(scale: scale), base: base.rounded(scale: scale), high: high.rounded(scale: scale))
    }
}

/// Bounded identifiers and labels: nonempty, no control characters.
public enum ContractText {
    public static func isIdentifier(_ value: String, maximum: Int = 512) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func isLabel(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maximum
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
    }

    public static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value).map { $0.uuidString.lowercased() == value } ?? false
    }

    public static func isDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.utf8.count == 71
            && value.utf8.dropFirst(7).allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }
}

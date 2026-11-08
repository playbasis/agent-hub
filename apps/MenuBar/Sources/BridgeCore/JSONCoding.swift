import Foundation

public enum BridgeJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.withFractional.string(from: date))
        }
        return encoder
    }

    public static var compactEncoder: JSONEncoder {
        let encoder = encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601.date(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 timestamp"
            )
        }
        return decoder
    }
}

enum ISO8601 {
    /// Parses an internet date-time. The app's own `…T07:12:34.567Z` and
    /// `…T07:12:34Z` forms take a direct path (hundreds of times faster than
    /// the formatter, with identical results); anything else, such as zone
    /// offsets or other fraction lengths, goes through the formatters.
    static func date(_ value: String) -> Date? {
        fastDate(value) ?? withFractional.date(from: value) ?? withoutFractional.date(from: value)
    }

    static func fastDate(_ string: String) -> Date? {
        var string = string
        return string.withUTF8 { bytes -> Date? in
            let count = bytes.count
            guard count == 20 || count == 24, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
                  bytes[13] == 58, bytes[16] == 58, bytes[count - 1] == 90 else { return nil }
            func number(_ start: Int, _ length: Int) -> Int? {
                var value = 0
                for index in start ..< start + length {
                    let digit = Int(bytes[index]) - 48
                    guard (0 ... 9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
            var milliseconds = 0
            if count == 24 {
                guard bytes[19] == 46, let fraction = number(20, 3) else { return nil }
                milliseconds = fraction
            }
            // Out-of-range fields are left to the formatter's own rules.
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1 ... 12).contains(month), day >= 1, day <= monthDays[month - 1], hour <= 23, minute <= 59, second <= 59 else { return nil }
            // Days since 1970-01-01 in the proleptic Gregorian calendar.
            let shifted = month <= 2 ? year - 1 : year
            let era = (shifted >= 0 ? shifted : shifted - 399) / 400
            let yearOfEra = shifted - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
            let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
            return Date(timeIntervalSince1970: Double(seconds * 1_000 + milliseconds) / 1_000)
        }
    }

    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}


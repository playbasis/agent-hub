@testable import BridgeCore
import Foundation
import XCTest

/// Developer benchmark, skipped unless `BRIDGE_PERF_DB` names a copy of an
/// activity.sqlite. Prints how long the runtime's reads and transfers take.
final class ActivityReadBenchmarkTests: XCTestCase {
    func testReadAndTransferCosts() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGE_PERF_DB"], path.hasPrefix("/") else {
            throw XCTSkip("Set BRIDGE_PERF_DB to a copy of activity.sqlite to run the read benchmark.")
        }
        func time<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try block()
            print("[bench] \(label): \(Int(Date().timeIntervalSince(start) * 1_000)) ms")
            return value
        }
        let database = try ActivityDatabase(url: URL(fileURLWithPath: path))
        let cold = try time("overview, first read") { try database.overview() }
        _ = try time("overview, unchanged") { try database.overview() }
        let turns = cold.sessions.reduce(0) { $0 + $1.turns.count }
        let steps = cold.sessions.reduce(0) { $0 + $1.turns.reduce(0) { $0 + ($1.modelSteps?.count ?? 0) } }
        print("[bench] \(cold.sessions.count) sessions, \(turns) turns, \(steps) model steps")
        let data = try time("encode JSON") { try BridgeJSON.compactEncoder.encode(cold) }
        print("[bench] \(data.count / 1_048_576) MB")
        _ = try time("decode JSON") { try BridgeJSON.decoder.decode(ActivityOverview.self, from: data) }
        // The formatter-only strategy the decoder used before its fast path.
        let formatterDecoder = JSONDecoder()
        formatterDecoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.withFractional.date(from: value) ?? ISO8601.withoutFractional.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
            }
            return date
        }
        let slow = try time("decode JSON, formatter dates") { try formatterDecoder.decode(ActivityOverview.self, from: data) }
        XCTAssertEqual(try BridgeJSON.decoder.decode(ActivityOverview.self, from: data), slow, "Both strategies decode identical values")
        _ = time("equality") { cold == cold }
    }
}

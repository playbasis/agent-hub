import XCTest
import Darwin
@testable import BridgeCore

final class JEVAssessmentTests: XCTestCase {
    func testRejectsFIFOWithoutBlocking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("input.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let store = JEVAssessmentStore(directory: root.appendingPathComponent("store"))
        do { _ = try await store.importJSONL(at: fifo); XCTFail("FIFO accepted") }
        catch JEVAssessmentError.unsafePath {} catch { XCTFail("Unexpected error: \(error)") }
        let directory = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("bad.json").path, 0o600), 0)
        do { _ = try await store.list(); XCTFail("Stored FIFO accepted") }
        catch JEVAssessmentError.unsafePath {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRejectsEscapedDuplicateKeysOnImportAndStoredRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = String(repeating: "a", count: 64)
        let receipt = JEVAssessmentReceipt(id: "r", evidenceID: "e", snapshotDigest: d, sessionID: "s", provider: "codex", inputDigest: d, model: "m", rubricVersion: "v", rubricHash: d, assessedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .unavailable)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = String(decoding: try encoder.encode(receipt), as: UTF8.self)
        let duplicate = "{\"\\u0069d\":\"other\"," + String(original.dropFirst())
        let input = root.appendingPathComponent("input.jsonl")
        try Data(duplicate.utf8).write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let directory = root.appendingPathComponent("store")
        let store = JEVAssessmentStore(directory: directory)
        do { _ = try await store.importJSONL(at: input); XCTFail("Duplicate key accepted") }
        catch JEVAssessmentError.invalidJSON {} catch { XCTFail("Unexpected error: \(error)") }
        let saved = directory.appendingPathComponent("bad.json")
        try Data(duplicate.utf8).write(to: saved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saved.path)
        do { _ = try await store.list(); XCTFail("Duplicate stored key accepted") }
        catch JEVAssessmentError.invalidJSON {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRejectsNestedDuplicateKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = String(repeating: "a", count: 64)
        let result = JEVAssessmentReceipt.Result(workKind: "unknown", evidenceLevel: "no_evidence", outcomeSupport: "insufficient", retry: .unknown, correction: .unknown, clarification: .unknown, claimNeedsReview: .unknown)
        let receipt = JEVAssessmentReceipt(id: "r", evidenceID: "e", snapshotDigest: d, sessionID: "s", provider: "codex", inputDigest: d, model: "m", rubricVersion: "v", rubricHash: d, assessedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .assessed, result: result)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = String(decoding: try encoder.encode(receipt), as: UTF8.self)
        let duplicate = original.replacingOccurrences(of: "\"retry\":\"unknown\"", with: "\"retry\":\"unknown\",\"\\u0072etry\":\"yes\"")
        XCTAssertNotEqual(original, duplicate)
        let input = root.appendingPathComponent("input.jsonl"); try Data(duplicate.utf8).write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let store = JEVAssessmentStore(directory: root.appendingPathComponent("store"))
        do { _ = try await store.importJSONL(at: input); XCTFail("Nested duplicate accepted") }
        catch JEVAssessmentError.invalidJSON {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testPrivateImportDeduplicationAndStaleness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = String(repeating: "a", count: 64)
        let result = JEVAssessmentReceipt.Result(workKind: "implementation", evidenceLevel: "no_evidence", outcomeSupport: "insufficient", retry: .unknown, correction: .no, clarification: .no, claimNeedsReview: .unknown)
        let receipt = JEVAssessmentReceipt(id: "r1", evidenceID: "e1", snapshotDigest: d, sessionID: "s1", provider: "codex", inputDigest: d, model: "jev-1.14.0", rubricVersion: "focused-v2", rubricHash: d, assessedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .assessed, result: result)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let input = root.appendingPathComponent("input.jsonl")
        try encoder.encode(receipt).write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let store = JEVAssessmentStore(directory: root.appendingPathComponent("store"))
        let first = try await store.importJSONL(at: input); XCTAssertEqual(first, 1)
        let second = try await store.importJSONL(at: input); XCTAssertEqual(second, 0)
        let stale = try await store.summaries(currentSnapshotDigests: ["e1": String(repeating: "b", count: 64)])
        XCTAssertEqual(stale.first?.isStale, true)
        let unknown = try await store.summaries(); XCTAssertNil(unknown.first?.isStale)
        let rollup = try await store.rollup(); XCTAssertTrue(rollup.byWorkKind.isEmpty)
    }
    func testFailureIsNotScoredAndInvalidConfidenceRejected() throws {
        let d = String(repeating: "a", count: 64)
        let failed = JEVAssessmentReceipt(id: "r", evidenceID: "e", snapshotDigest: d, sessionID: "s", provider: "codex", inputDigest: d, model: "m", rubricVersion: "v", rubricHash: d, assessedAt: Date(), status: .failed)
        XCTAssertNoThrow(try failed.validate()); XCTAssertNil(failed.result)
        let result = JEVAssessmentReceipt.Result(workKind: "unknown", evidenceLevel: "unknown", outcomeSupport: "insufficient", retry: .unknown, correction: .unknown, clarification: .unknown, claimNeedsReview: .unknown, modelReportedConfidence: 2)
        let invalid = JEVAssessmentReceipt(id: "r", evidenceID: "e", snapshotDigest: d, sessionID: "s", provider: "codex", inputDigest: d, model: "m", rubricVersion: "v", rubricHash: d, assessedAt: Date(), status: .assessed, result: result)
        XCTAssertThrowsError(try invalid.validate())
    }
    func testFractionalTimestampImportRemainsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = String(repeating: "a", count: 64)
        let receipt = JEVAssessmentReceipt(id: "fractional", evidenceID: "e", snapshotDigest: d, sessionID: "s", provider: "codex", inputDigest: d, model: "m", rubricVersion: "v", rubricHash: d, assessedAt: Date(timeIntervalSince1970: 1_700_000_000.123), status: .unavailable)
        let input = root.appendingPathComponent("input.jsonl")
        try BridgeJSON.compactEncoder.encode(receipt).write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let store = JEVAssessmentStore(directory: root.appendingPathComponent("store"))
        let first = try await store.importJSONL(at: input); XCTAssertEqual(first, 1)
        let second = try await store.importJSONL(at: input); XCTAssertEqual(second, 0)
    }
    func testDistinctAttemptIDsPreserveRepeatedEvaluations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = String(repeating: "a", count: 64)
        let first = JEVAssessmentReceipt(id: "first", evidenceID: "e", snapshotDigest: d, sessionID: "s", provider: "codex", inputDigest: d, model: "m", rubricVersion: "v", rubricHash: d, assessedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .unavailable)
        let second = JEVAssessmentReceipt(id: "second", evidenceID: "e", snapshotDigest: d, sessionID: "s", provider: "codex", inputDigest: d, model: "m", rubricVersion: "v", rubricHash: d, assessedAt: Date(timeIntervalSince1970: 1_700_000_001), status: .unavailable)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(first); data.append(10); data.append(try encoder.encode(second)); data.append(10)
        let input = root.appendingPathComponent("input.jsonl"); try data.write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let store = JEVAssessmentStore(directory: root.appendingPathComponent("store"))
        let imported = try await store.importJSONL(at: input); XCTAssertEqual(imported, 2)
        let replay = try await store.importJSONL(at: input); XCTAssertEqual(replay, 0)
        let saved = try await store.list(); XCTAssertEqual(saved.count, 2)
    }

    func testOptionalPrivateLabExportRoundTrip() async throws {
        guard let path = ProcessInfo.processInfo.environment["JEV_IMPORT_FIXTURE"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jev-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JEVAssessmentStore(directory: root.appendingPathComponent("store"))
        let first = try await store.importJSONL(at: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(first, 0)
        let replay = try await store.importJSONL(at: URL(fileURLWithPath: path))
        XCTAssertEqual(replay, 0)
        let saved = try await store.list()
        XCTAssertEqual(saved.count, first)
    }
}

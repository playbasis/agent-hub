import XCTest
import Darwin
@testable import BridgeCore

final class JEVToolPageAssessmentTests: XCTestCase {
    private func receipt(id: String = "receipt-1", evidenceID: String? = nil) -> JEVToolPageAssessment {
        let hash = String(repeating: "a", count: 64), sid = "codex:session:1", tid = "codex:turn:1"
        return JEVToolPageAssessment(id: id, sessionID: sid, turnID: tid, evidenceID: evidenceID ?? JEVAssessmentEvidence.evidenceID(sessionID: sid, turnID: tid), captureID: hash, model: "jev-1.14.0", rubricHash: hash, stateHash: hash, requestHash: hash, assessedAt: Date(timeIntervalSince1970: 1_700_000_000.123), pagePartial: true, toolFactsTruncated: false, artifactCountIsPartial: true, factCount: 1, answers: .init(listedNonzeroExit: .no, listedCompletedTool: .yes, artifactRecorded: .unknown, goalStatusRecordedCompleted: .no, listedMissingDuration: .yes, recordedModelsPresent: .yes, turnElapsedMissing: .no), noul: .init(listedNonzeroExit: 0, listedCompletedTool: 1, artifactRecorded: 0.5, goalStatusRecordedCompleted: 0, listedMissingDuration: 1, recordedModelsPresent: 1, turnElapsedMissing: 0))
    }
    func testIdentityAndHistoricalSourceValidation() throws {
        XCTAssertNoThrow(try receipt().validate())
        XCTAssertThrowsError(try receipt(evidenceID: "evidence:wrong").validate())
        XCTAssertEqual(receipt().source, "historical_structured_page")
    }
    func testCancelledReadStopsBeforeDecodingStoredReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.jsonl")
        try BridgeJSON.compactEncoder.encode(receipt()).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = JEVToolPageAssessmentStore(directory: root.appendingPathComponent("store"))
        _ = try await store.importJSONL(at: file)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.list()
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled read should stop") }
        catch is CancellationError { }
    }
    func testImportReplayAndUnknownFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.jsonl")
        let encoded = try BridgeJSON.compactEncoder.encode(receipt())
        try encoded.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = JEVToolPageAssessmentStore(directory: root.appendingPathComponent("store"))
        let first = try await store.importJSONL(at: file), replay = try await store.importJSONL(at: file)
        XCTAssertEqual(first, 1); XCTAssertEqual(replay, 0)
        let items = try await store.list(); XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].evidenceID, receipt().evidenceID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); object["rawCommand"] = "not permitted"
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        do { _ = try await store.importJSONL(at: file); XCTFail("Unknown field accepted") } catch { }
    }
    func testDuplicateJSONKeyRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.jsonl")
        let encoded = String(decoding: try BridgeJSON.compactEncoder.encode(receipt()), as: UTF8.self)
        let duplicate = encoded.replacingOccurrences(of: "\"id\":\"receipt-1\"", with: "\"id\":\"receipt-1\",\"id\":\"receipt-1\"")
        XCTAssertNotEqual(encoded, duplicate)
        try Data(duplicate.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = JEVToolPageAssessmentStore(directory: root.appendingPathComponent("store"))
        do { _ = try await store.importJSONL(at: file); XCTFail("Duplicate field accepted") } catch { }
    }
    func testOptInHistoricalExportImportsAndReplays() async throws {
        guard let path = ProcessInfo.processInfo.environment["JEV_TOOL_IMPORT_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set JEV_TOOL_IMPORT_FIXTURE to the private historical JSONL export")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JEVToolPageAssessmentStore(directory: root.appendingPathComponent("store"))
        let input = URL(fileURLWithPath: path)
        let imported = try await store.importJSONL(at: input)
        XCTAssertEqual(imported, 100)
        let items = try await store.list()
        XCTAssertEqual(items.count, 100)
        XCTAssertEqual(Set(items.map(\.id)).count, 100)
        let pages = Set(items.map { "\($0.evidenceID):\($0.stateHash)" })
        let partialPages = Set(items.filter(\.pagePartial).map { "\($0.evidenceID):\($0.stateHash)" })
        XCTAssertEqual(pages.count, 50)
        XCTAssertEqual(partialPages.count, 43)
        let replay = try await store.importJSONL(at: input)
        XCTAssertEqual(replay, 0)
    }
    func testFIFORejectedWithoutWaitingForWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let store = JEVToolPageAssessmentStore(directory: root.appendingPathComponent("store"))
        do { _ = try await store.importJSONL(at: fifo); XCTFail("FIFO accepted") } catch { }
    }
}

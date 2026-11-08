import XCTest
import Foundation
import Darwin
import CoreFoundation
@testable import BridgeCore

/// Explicit one-off research probe. Normal test runs never read native histories.
final class JEVToolEvidenceProbeTests: XCTestCase {
    func testExplicitLocalProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JEV_TOOL_PROBE"] == "1" else { throw XCTSkip("Explicit research probe not requested") }
        guard let mappingPath = env["JEV_TOOL_PROBE_MAPPING"], let outputPath = env["JEV_TOOL_PROBE_OUTPUT"], let fixturePath = env["JEV_TOOL_DB_FIXTURE"],
              mappingPath.hasPrefix("/"), outputPath.hasPrefix("/"), fixturePath.hasPrefix("/") else { XCTFail("Explicit absolute paths required"); return }
        var st = stat()
        guard lstat(mappingPath, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_nlink == 1, st.st_size <= 4_194_304 else { XCTFail("Unsafe mapping"); return }
        let fd = open(mappingPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { XCTFail("Mapping unavailable"); return }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else { XCTFail("Mapping changed"); return }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4_194_305) ?? Data()
        guard data.count <= 4_194_304 else { XCTFail("Mapping too large"); return }
        guard let mapping = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { XCTFail("Invalid mapping"); return }
        var fixtureStat = stat()
        guard lstat(fixturePath, &fixtureStat) == 0, fixtureStat.st_mode & S_IFMT == S_IFREG, fixtureStat.st_uid == getuid(), fixtureStat.st_mode & 0o077 == 0, fixtureStat.st_nlink == 1,
              URL(fileURLWithPath: fixturePath).resolvingSymlinksInPath() != BridgePaths.applicationSupport.appendingPathComponent("activity.sqlite").resolvingSymlinksInPath() else { XCTFail("Private database fixture required"); return }
        let overview = try await ActivityReportingService(databaseURL: URL(fileURLWithPath: fixturePath)).overview()
        func normalizedStatus(_ value: String) -> String {
            switch value.lowercased() {
            case "complete", "completed", "finished", "done", "success", "succeeded": return "completed"
            case "failed", "error": return "failed"
            case "running", "in_progress", "in-progress", "active": return "running"
            case "interrupted", "cancelled", "canceled", "aborted", "stopped": return "interrupted"
            case "pending", "waiting", "paused", "queued": return "pending"
            default: return "unknown"
            }
        }
        var rows: [[String: Any]] = [], local: [[String: Any]] = [], skipped: [String: Int] = [:], selectedCounts: [String: Int] = [:], attemptedCounts: [String: Int] = [:]
        var seen = Set<String>()
        for provider in [AgentName.claude, AgentName.codex] {
          var count = 0, attempted = 0, skippedCount = 0
          var buckets: [Int: [String: [(String, ActivitySession, ActivityTurn)]]] = [:]
          for key in mapping.keys.sorted() {
            guard let row = mapping[key], let sid = row["sessionID"] as? String, let tid = row["turnID"] as? String,
                  let session = overview.sessions.first(where: { $0.id == sid && $0.provider == provider }),
                  let turn = session.turns.first(where: { $0.id == tid }), seen.insert("\(sid.utf8.count):\(sid)\(tid.utf8.count):\(tid)").inserted else { continue }
            // Positive recorded count first, then unknown, then recorded zero.
            let bucket = turn.toolCount.map { $0 > 0 ? 0 : 2 } ?? 1
            buckets[bucket, default: [:]][sid, default: []].append((key, session, turn))
          }
          var ordered: [(String, ActivitySession, ActivityTurn)] = []
          for bucket in 0...2 {
            var groups = buckets[bucket] ?? [:]
            for sid in groups.keys {
              groups[sid]?.sort { left, right in
                let lhs = left.2.completedAt ?? left.2.startedAt ?? .distantPast
                let rhs = right.2.completedAt ?? right.2.startedAt ?? .distantPast
                return lhs == rhs ? left.0 < right.0 : lhs > rhs
              }
            }
            // Newest first within each round; round-robin prevents one session
            // dominating merely because it has many adjacent mapped turns.
            while !groups.isEmpty {
              let round = groups.keys.sorted { left, right in
                let a = groups[left]![0], b = groups[right]![0]
                let lhs = a.2.completedAt ?? a.2.startedAt ?? .distantPast
                let rhs = b.2.completedAt ?? b.2.startedAt ?? .distantPast
                return lhs == rhs ? a.0 < b.0 : lhs > rhs
              }
              for sid in round {
                guard var group = groups[sid], !group.isEmpty else { continue }
                ordered.append(group.removeFirst())
                if group.isEmpty { groups.removeValue(forKey: sid) } else { groups[sid] = group }
              }
            }
          }
          for (key, session, turn) in ordered where count < 30 && attempted < 100 {
            attempted += 1
            let batch: WorkEvidenceBatch
            do { batch = try await WorkEvidenceReader.read(session: session, turn: turn, configuration: AgentConfiguration(), includeText: false) }
            catch { skippedCount += 1; continue }
            let items = batch.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
            guard !items.isEmpty else { skippedCount += 1; continue }
            let facts: [[String: Any]] = items.prefix(20).map { item in
                let exit = item.exitCode.flatMap { (-255...255).contains($0) ? $0 : nil }
                let duration = item.durationSeconds.flatMap { $0.isFinite && $0 >= 0 && $0 <= 31_536_000 ? $0 : nil }
                return ["kind": item.kind == .toolCall ? "tool_call" : "tool_result", "status": normalizedStatus(item.status), "exitCode": exit as Any? ?? NSNull(), "durationSeconds": duration as Any? ?? NSNull()]
            }
            var artifacts = ["file": 0, "other": 0]
            for artifact in turn.artifacts.prefix(4_096) { artifacts[artifact.kind.lowercased() == "file" ? "file" : "other", default: 0] += 1 }
            let goal = session.goal.map { normalizedStatus($0.status) } ?? "unknown"
            let opaque = String(format: "tool-%03d", rows.count)
            let pagePartial = batch.isPartial || batch.nextCursor != nil
            let truncated = items.count > 20
            let approvedState = mapping[key]?["state"] as? [String: Any] ?? [:]
            let pattern = #"^(claude-|gpt-|gemini-|grok-|o[134](-|$))[A-Za-z0-9_.-]{0,70}$"#
            let models = Array(Set((approvedState["models"] as? [String] ?? []).filter { $0.range(of: pattern, options: .regularExpression) != nil })).sorted().prefix(16)
            let rawDuration = approvedState["durationSeconds"] as? NSNumber
            let duration: Double? = rawDuration.flatMap { number in
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0...31_536_000).contains(number.doubleValue) else { return nil }
                return number.doubleValue
            }
            // Turn elapsed duration is not provider compute or GPU time.
            rows.append(["id": opaque, "state": ["provider": session.provider.rawValue, "turnStatus": normalizedStatus(turn.status), "goalStatus": goal, "models": Array(models), "turnDurationSeconds": duration as Any? ?? NSNull(), "artifactKindCounts": artifacts, "artifactCountIsPartial": true, "toolFacts": facts, "pagePartial": pagePartial, "toolFactsTruncated": truncated]])
            local.append(["id": opaque, "sessionID": session.id, "turnID": turn.id])
            count += 1
          }
          skipped[provider.rawValue] = skippedCount
          selectedCounts[provider.rawValue] = count; attemptedCounts[provider.rawValue] = attempted
          guard count > 0 else { XCTFail("No usable mapped turns for provider; skipped count \(skippedCount)"); return }
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        guard mkdir(output.path, 0o700) == 0 else { XCTFail("Output must be a new private directory"); return }
        func writePrivate(_ name: String, _ object: Any) throws {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let handle = open(output.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard handle >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(handle) }
            let ok = bytes.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }; var offset = 0
                while offset < raw.count { let n = write(handle, base.advanced(by: offset), raw.count - offset); if n <= 0 { return false }; offset += n }
                return fsync(handle) == 0
            }
            guard ok else { throw CocoaError(.fileWriteUnknown) }
        }
        try writePrivate("states.json", rows); try writePrivate("local-mapping.json", local)
        try writePrivate("selection-summary.json", ["selection": "recorded-positive-count-newest-session-round-robin-then-unknown-then-zero", "attempted": attemptedCounts, "skipped": skipped, "selected": selectedCounts, "maximumAttemptsPerProvider": 100, "maximumSelectedPerProvider": 30])
        XCTAssertGreaterThanOrEqual(rows.count, 2)
    }
}

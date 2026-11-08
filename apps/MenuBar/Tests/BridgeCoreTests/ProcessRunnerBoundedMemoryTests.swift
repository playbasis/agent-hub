import Foundation
import XCTest
@testable import BridgeCore

final class ProcessRunnerBoundedMemoryTests: XCTestCase {
    func testCaptureNeverRetainsMoreThanItsByteBudgetAcrossManyMegabytes() {
        var capture = BoundedProcessOutputCapture(characterLimit: 1024)
        let chunk = Data(repeating: 65, count: 16 * 1024)
        for _ in 0 ..< 512 {
            capture.append(chunk) // 8 MiB streamed, no output file.
            XCTAssertLessThanOrEqual(capture.retainedByteCount, capture.byteLimit)
        }
        XCTAssertEqual(capture.result(), String(repeating: "A", count: 512)
            + BoundedProcessOutputCapture.truncationMarker + String(repeating: "A", count: 512))
        XCTAssertEqual(BoundedProcessOutputCapture(characterLimit: .max).byteLimit, BoundedProcessOutputCapture.maximumCaptureBytes)
        var negative = BoundedProcessOutputCapture(characterLimit: -1)
        negative.append(Data("discarded".utf8))
        XCTAssertEqual(negative.retainedByteCount, 0)
        XCTAssertEqual(negative.result(), BoundedProcessOutputCapture.truncationMarker)
    }

    func testUTF8HeadAndTailRemainValidWhenCaptureAndReadBoundariesSplitScalars() {
        let text = String(repeating: "🙂", count: 300)
        let data = Data(text.utf8)
        var capture = BoundedProcessOutputCapture(characterLimit: 51)
        for start in stride(from: 0, to: data.count, by: 3) {
            capture.append(data.subdata(in: start ..< min(start + 3, data.count)))
        }
        let result = capture.result()
        XCTAssertEqual(result, String(repeating: "🙂", count: 25)
            + BoundedProcessOutputCapture.truncationMarker + String(repeating: "🙂", count: 25))
        XCTAssertFalse(result.contains("\u{FFFD}"))

        let small = "A🙂e\u{301}끝\nZ"
        var untruncated = BoundedProcessOutputCapture(characterLimit: 100)
        var lines = BoundedProcessLineFramer()
        var completed: [String] = []
        for byte in small.utf8 {
            let chunk = Data([byte])
            untruncated.append(chunk)
            completed += lines.append(chunk)
        }
        XCTAssertEqual(untruncated.result(), small)
        XCTAssertEqual(completed, ["A🙂e\u{301}끝"])
        XCTAssertEqual(lines.finish(), "Z")
    }

    func testCombiningMarkGraphemeCannotEvadeTheByteCeiling() {
        var capture = BoundedProcessOutputCapture(characterLimit: 10)
        capture.append(Data("a".utf8))
        let marks = Data(String(repeating: "\u{301}", count: 4000).utf8)
        for _ in 0 ..< 30 { capture.append(marks) }
        XCTAssertLessThanOrEqual(capture.retainedByteCount, 40)
        XCTAssertTrue(capture.result().contains(BoundedProcessOutputCapture.truncationMarker))
    }

    func testOversizedUnterminatedLineIsDiscardedWholeAndFollowingLinesSurvive() {
        var lines = BoundedProcessLineFramer()
        XCTAssertEqual(lines.append(Data("before\n".utf8)), ["before"])
        let chunk = Data(repeating: 120, count: 16 * 1024)
        for _ in 0 ..< 256 {
            XCTAssertTrue(lines.append(chunk).isEmpty)
            XCTAssertLessThanOrEqual(lines.retainedByteCount, BoundedProcessLineFramer.maximumLineBytes)
        }
        XCTAssertEqual(lines.append(Data("\nafter\nlast".utf8)), ["after"])
        XCTAssertEqual(lines.finish(), "last")
        XCTAssertEqual(lines.retainedByteCount, 0)
        XCTAssertNil(lines.finish())
    }

    func testConcurrentMultiMegabyteStdoutAndStderrDrainWithoutUnboundedCapture() async throws {
        let script = """
        binmode STDOUT; binmode STDERR;
        print STDOUT "OUT-BEGIN\\n"; print STDERR "ERR-BEGIN\\n";
        my $out = "x" x 8192; my $err = "y" x 8192;
        for (1..512) { print STDOUT $out; print STDERR $err; }
        print STDOUT "\\nOUT-END"; print STDERR "\\nERR-END";
        """
        let output = try await Self.fixture(script, limit: 512)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(output.timedOut)
        XCTAssertTrue(output.stdout.hasPrefix("OUT-BEGIN\n"))
        XCTAssertTrue(output.stdout.hasSuffix("\nOUT-END"))
        XCTAssertTrue(output.stderr.hasPrefix("ERR-BEGIN\n"))
        XCTAssertTrue(output.stderr.hasSuffix("\nERR-END"))
        XCTAssertEqual(output.stdout.count, 512 + BoundedProcessOutputCapture.truncationMarker.count)
        XCTAssertEqual(output.stderr.count, 512 + BoundedProcessOutputCapture.truncationMarker.count)
    }

    func testStreamingCallbackSkipsHugeLineWithoutLeakingSuffixOrBlockingStderr() async throws {
        let probe = LineProbe()
        let script = """
        binmode STDOUT; binmode STDERR;
        print STDOUT "before\\n";
        my $chunk = "z" x 8192;
        for (1..512) { print STDOUT $chunk; print STDERR $chunk; }
        print STDOUT "\\nafter\\nlast"; print STDERR "ERR-END";
        """
        let output = try await Self.fixture(script, limit: 1024, onLine: { await probe.record($0) })
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(output.timedOut)
        let observed = await probe.snapshot()
        XCTAssertEqual(observed, ["before", "after", "last"])
        XCTAssertTrue(output.stdout.hasPrefix("before\n"))
        XCTAssertTrue(output.stdout.hasSuffix("after\nlast"))
        XCTAssertTrue(output.stderr.hasSuffix("ERR-END"))
        XCTAssertLessThanOrEqual(output.stdout.count, 1024 + BoundedProcessOutputCapture.truncationMarker.count)
        XCTAssertLessThanOrEqual(output.stderr.count, 1024 + BoundedProcessOutputCapture.truncationMarker.count)
    }

    func testSeveralConcurrentRunsWithAsyncCallbacksDoNotStarvePipeReaders() async throws {
        let script = """
        binmode STDOUT; binmode STDERR;
        my $chunk = "c" x 8192;
        for (1..8) { print STDOUT $chunk; print STDERR $chunk; }
        print STDOUT "\\nDONE\\n"; print STDERR "\\nERR-DONE\\n";
        """
        try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try await Self.fixture(script, limit: 128, onLine: { _ in await Task.yield() })
                }
            }
            var completed = 0
            for try await output in group {
                XCTAssertEqual(output.status, 0, output.stderr)
                XCTAssertFalse(output.timedOut)
                XCTAssertTrue(output.stdout.hasSuffix("\nDONE\n"))
                XCTAssertTrue(output.stderr.hasSuffix("\nERR-DONE\n"))
                completed += 1
            }
            XCTAssertEqual(completed, 8)
        }
    }

    private static func fixture(_ script: String, limit: Int, onLine: (@Sendable (String) async -> Void)? = nil) async throws -> ProcessOutput {
        try await ProcessRunner.run(
            executable: "/usr/bin/perl", arguments: ["-e", script],
            currentDirectory: FileManager.default.temporaryDirectory,
            stdin: "", timeoutSeconds: 20, maximumOutputCharacters: limit,
            onOutputLine: onLine
        )
    }
}

private actor LineProbe {
    private var values: [String] = []
    func record(_ line: String) { values.append(String(line.prefix(128))) }
    func snapshot() -> [String] { values }
}

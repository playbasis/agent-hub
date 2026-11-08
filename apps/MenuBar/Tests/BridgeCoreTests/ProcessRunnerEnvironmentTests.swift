import Foundation
import XCTest
@testable import BridgeCore

final class ProcessRunnerEnvironmentTests: XCTestCase {
    func testFinderPathPairsRuntimeAndPreservesOverrides() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inherited = ["PATH": "/usr/bin:/bin", "HOME": "/unchanged/home", "BRIDGE_TEST_VALUE": "inherited", "OTHER": "kept"]
        let result = SubprocessEnvironment.make(
            executable: fixture.cli, currentDirectory: fixture.project, inherited: inherited,
            overrides: ["BRIDGE_TEST_VALUE": "explicit", "PATH": "/custom/bin:/usr/bin:/bin"]
        )
        XCTAssertEqual(result["PATH"], "\(fixture.bin.path):/custom/bin:/usr/bin:/bin")
        XCTAssertEqual(result["HOME"], "/unchanged/home")
        XCTAssertEqual(result["OTHER"], "kept")
        XCTAssertEqual(result["BRIDGE_TEST_VALUE"], "explicit")
        XCTAssertEqual(inherited["PATH"], "/usr/bin:/bin")
    }

    func testPairedRuntimeDirectoryIsDeduplicatedWithoutReorderingOtherPaths() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = SubprocessEnvironment.make(
            executable: fixture.cli, currentDirectory: fixture.project,
            inherited: ["PATH": "/usr/bin:\(fixture.bin.path)/:/bin:\(fixture.bin.path)"]
        )
        XCTAssertEqual(result["PATH"], "\(fixture.bin.path):/usr/bin:/bin")
        let appliedAgain = SubprocessEnvironment.make(executable: fixture.cli, currentDirectory: fixture.project, inherited: result)
        XCTAssertEqual(appliedAgain, result)
    }

    func testNoPairedExecutableLeavesEffectiveEnvironmentUntouched() throws {
        let fixture = try fixture(pairedNode: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = ["PATH": "/usr/bin:/bin", "VALUE": "explicit"]
        XCTAssertEqual(SubprocessEnvironment.make(
            executable: fixture.cli, currentDirectory: fixture.project,
            inherited: ["PATH": "/usr/bin:/bin", "VALUE": "old"], overrides: ["VALUE": "explicit"]
        ), expected)
        // A searchable directory called node is not a runnable runtime.
        try FileManager.default.createDirectory(at: fixture.bin.appendingPathComponent("node"), withIntermediateDirectories: true)
        XCTAssertEqual(SubprocessEnvironment.make(executable: fixture.cli, currentDirectory: fixture.project, inherited: expected), expected)
    }

    func testNeverAddsProjectWorkingDirectoryOrImplicitEmptyPath() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inherited = ["PATH": "/usr/bin:/bin"]
        XCTAssertEqual(SubprocessEnvironment.make(executable: fixture.cli, currentDirectory: fixture.bin, inherited: inherited), inherited)
        let noPath = SubprocessEnvironment.make(executable: fixture.cli, currentDirectory: fixture.project, inherited: ["OTHER": "kept"])
        XCTAssertEqual(noPath["PATH"], fixture.bin.path)
        XCTAssertFalse(noPath["PATH"]?.contains(fixture.project.path) ?? true)
    }

    func testEnvNodeWrapperRunsWithSparseGUIPath() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = try await ProcessRunner.run(
            executable: fixture.cli.path, arguments: ["--harmless-fixture"], currentDirectory: fixture.project,
            stdin: "", timeoutSeconds: 5, maximumOutputCharacters: 4_096,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "BRIDGE_TEST_VALUE": "from-caller"]
        )
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.stdout.split(separator: "\n").map(String.init), [
            "paired-node", "from-caller", "\(fixture.bin.path):/usr/bin:/bin:/usr/sbin:/sbin", fixture.cli.path,
        ])
    }

    func testAppServerSessionUsesPairedRuntimeWithSparseGUIPath() async throws {
        let fixture = try fixture(nodeScript: """
        #!/bin/sh
        while IFS= read -r message; do
          case "$message" in
            *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
            *account*read*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.invalid"}}}' ;;
          esac
        done

        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try await CodexAppServerSession(
            executable: fixture.cli, currentDirectory: fixture.project,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        defer { session.close() }
        let result = try await session.request("account/read", timeoutSeconds: 3)
        let account = try XCTUnwrap(result["account"] as? [String: Any])
        XCTAssertEqual(account["type"] as? String, "chatgpt")
        XCTAssertEqual(account["email"] as? String, "fixture@example.invalid")
    }

    func testLocatorPrefersNewestNVMNodeAndKnownManagerShims() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeLocatorHome.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func tool(_ directory: String, _ name: String) throws -> URL {
            let bin = home.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        _ = try tool(".nvm/versions/node/v9.11.2/bin", "fixture-agent")
        let newest = try tool(".nvm/versions/node/v20.18.2/bin", "fixture-agent")
        XCTAssertEqual(try ExecutableLocator.resolve("fixture-agent", home: home, environmentPath: "").resolvingSymlinksInPath(), newest.resolvingSymlinksInPath())
        let shim = try tool(".local/share/mise/shims", "fixture-mise-agent")
        XCTAssertEqual(try ExecutableLocator.resolve("fixture-mise-agent", home: home, environmentPath: "").resolvingSymlinksInPath(), shim.resolvingSymlinksInPath())
        XCTAssertThrowsError(try ExecutableLocator.resolve("fixture-missing-agent", home: home, environmentPath: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("config.json"))
        }
    }

    private func fixture(pairedNode: Bool = true, nodeScript: String? = nil) throws -> (root: URL, bin: URL, cli: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeProcessEnvironment.\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("runtime/bin", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("fixture-cli")
        try Data("#!/usr/bin/env node\n// Fixture proves only runtime resolution; it never invokes a provider.\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        if pairedNode {
            let node = bin.appendingPathComponent("node")
            let script = nodeScript ?? "#!/bin/sh\nprintf '%s\\n' 'paired-node' \"$BRIDGE_TEST_VALUE\" \"$PATH\" \"$1\"\n"
            try Data(script.utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        }
        return (root, bin, cli, project)
    }
}

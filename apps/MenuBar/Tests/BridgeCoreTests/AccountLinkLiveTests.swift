@testable import BridgeCore
import Foundation
import XCTest

/// Opt-in live checks against the installed CLIs. They never complete a
/// sign-in — that needs a person in a browser — but they prove the Bridge can
/// read both accounts and can start and cleanly cancel the ChatGPT link.
/// Run with `BRIDGE_ACCOUNT_LINK_PROOF=1 swift test --filter AccountLinkLiveTests`.
final class AccountLinkLiveTests: XCTestCase {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["BRIDGE_ACCOUNT_LINK_PROOF"] == "1"
    }

    func testReadsInstalledAccountStatuses() async throws {
        try XCTSkipUnless(enabled, "Set BRIDGE_ACCOUNT_LINK_PROOF=1 to run against the installed CLIs.")
        let linker = AccountLinker(configuration: AgentConfiguration())
        for provider in LinkedProvider.allCases {
            let status = await linker.status(provider)
            XCTAssertEqual(status.provider, provider)
            XCTAssertTrue(status.installed, "\(provider.toolName) should be installed for this proof")
            XCTAssertNotNil(status.cliVersion, "\(provider.toolName) version should be readable")
            if status.linked {
                XCTAssertNotNil(status.method)
            } else {
                XCTAssertNotNil(status.message)
            }
        }
    }

    func testCodexLinkProducesSignInURLAndCancelsCleanly() async throws {
        try XCTSkipUnless(enabled, "Set BRIDGE_ACCOUNT_LINK_PROOF=1 to run against the installed CLIs.")
        let linker = AccountLinker(configuration: AgentConfiguration())
        var seen: [AccountLinkPhase] = []
        let stream = await linker.link(.codex)
        for await phase in stream {
            seen.append(phase)
            if case let .awaitingBrowser(url, _) = phase {
                XCTAssertEqual(url.host, "auth.openai.com")
                XCTAssertTrue(url.query?.contains("redirect_uri=http%3A%2F%2Flocalhost") == true)
                await linker.cancel()
            }
            if phase.isTerminal { break }
        }
        XCTAssertEqual(seen.first, .preparing)
        XCTAssertTrue(seen.contains { if case .awaitingBrowser = $0 { return true } else { return false } }, "\(seen)")
        XCTAssertEqual(seen.last, .cancelled, "\(seen)")
    }
}

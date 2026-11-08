@testable import BridgeCore
import Foundation
import XCTest

final class AccountLinkingTests: XCTestCase {
    private let claudeTranscript = """
    \u{1B}[?25l\u{1B}[1mClaude Code\u{1B}[0m\r
    Opening browser to sign in…\r
    Browser didn't open? Use the url below to sign in:\r
    \r
    https://claude.ai/oauth/authorize?code=true&client_id=abc123&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&scope=user%3Aprofile&state=xyz\r
    \r
    Paste code here if prompted > \u{1B}[?25h
    """

    func testTerminalTextStripsEscapesAndResolvesCarriageReturns() {
        let raw = "\u{1B}[32m⠋ Working\r⠙ Working\r✓ Done\u{1B}[0m\nnext line"
        XCTAssertEqual(TerminalText.normalize(raw), "✓ Done\nnext line")
    }

    func testClaudeSignInURLIsExtractedFromNoisyTranscript() throws {
        let url = try XCTUnwrap(AccountLinkParser.signInURL(in: claudeTranscript))
        XCTAssertEqual(url.host, "claude.ai")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertTrue(url.query?.contains("redirect_uri=http%3A%2F%2Flocalhost") == true)
    }

    func testClaudeTranscriptPromptsForPastedCode() {
        XCTAssertTrue(AccountLinkParser.promptsForCode(claudeTranscript))
        XCTAssertFalse(AccountLinkParser.promptsForCode("Opening browser to sign in…"))
        XCTAssertNil(AccountLinkParser.deviceCode(in: claudeTranscript))
    }

    func testDeviceCodeFlowExposesCodeAndVerificationURL() throws {
        let transcript = """
        Follow these steps to log in:
        1. Open https://auth.openai.com/codex/device in your browser
        2. Enter this one-time code: WXYZ-7Q2M
        Waiting for authentication…
        """
        XCTAssertEqual(AccountLinkParser.deviceCode(in: transcript), "WXYZ-7Q2M")
        let url = try XCTUnwrap(AccountLinkParser.signInURL(in: transcript))
        XCTAssertEqual(url.absoluteString, "https://auth.openai.com/codex/device")
    }

    func testSuccessAndFailureDetection() {
        XCTAssertTrue(AccountLinkParser.indicatesSuccess("✓ Login successful. Press Enter to continue…"))
        XCTAssertTrue(AccountLinkParser.indicatesSuccess("Successfully logged in"))
        XCTAssertFalse(AccountLinkParser.indicatesSuccess("Opening browser…"))
        XCTAssertEqual(
            AccountLinkParser.failureMessage("Opening browser…\nError: OAuth state mismatch\n"),
            "Error: OAuth state mismatch"
        )
        XCTAssertNil(AccountLinkParser.failureMessage("All good\nDone"))
    }

    func testClaudeAuthDocumentMapsToSubscriptionStatus() throws {
        let json = """
        {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
         "email":"person@example.com","orgName":"Example Org","subscriptionType":"max"}
        """
        let decoded = try BridgeJSON.decoder.decode(ClaudeAuthDocument.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.loggedIn)
        XCTAssertEqual(decoded.planName, "Claude Max")
        XCTAssertEqual(decoded.email, "person@example.com")
        let status = ProviderAccountStatus(
            provider: .claude, installed: true, linked: decoded.loggedIn,
            method: decoded.authMethod, email: decoded.email, planName: decoded.planName
        )
        XCTAssertTrue(status.isSubscription)
        let console = ProviderAccountStatus(provider: .claude, installed: true, linked: true, method: "console")
        XCTAssertFalse(console.isSubscription)
    }

    func testCodexAccountReadMapsToLinkedStatus() {
        let result: [String: Any] = [
            "account": ["type": "chatgpt", "email": "person@example.com", "planType": "pro"],
            "requiresOpenaiAuth": true,
        ]
        let status = CodexAccountParser.status(from: result, cliVersion: "0.145.0")
        XCTAssertTrue(status.linked)
        XCTAssertTrue(status.isSubscription)
        XCTAssertEqual(status.method, "chatgpt")
        XCTAssertEqual(status.email, "person@example.com")
        XCTAssertEqual(status.planName, "ChatGPT Pro")
        XCTAssertEqual(status.cliVersion, "0.145.0")

        let signedOut = CodexAccountParser.status(from: ["account": NSNull()], cliVersion: nil)
        XCTAssertFalse(signedOut.linked)
        XCTAssertTrue(signedOut.installed)
        XCTAssertEqual(CodexAccountParser.planName("self_serve_business_usage_based"), "ChatGPT Business")
    }

    func testLinkPhaseTerminalityIsExplicit() {
        XCTAssertTrue(AccountLinkPhase.cancelled.isTerminal)
        XCTAssertTrue(AccountLinkPhase.failed("x").isTerminal)
        XCTAssertFalse(AccountLinkPhase.verifying.isTerminal)
        XCTAssertTrue(AccountLinkPhase.awaitingCode(url: nil).isActive)
        XCTAssertFalse(AccountLinkPhase.idle.isActive)
    }

    func testPseudoTerminalStreamsOutputAndAcceptsInput() async throws {
        let directory = FileManager.default.temporaryDirectory
        let terminal = try PseudoTerminalProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'name? '; read name; echo \"hello $name\""],
            currentDirectory: directory
        )
        var transcript = ""
        var wroteAnswer = false
        for await chunk in terminal.output {
            transcript += chunk
            if !wroteAnswer, transcript.contains("name?") {
                wroteAnswer = true
                terminal.write("bridge\r")
            }
        }
        let status = await terminal.waitForExit()
        XCTAssertEqual(status, 0)
        XCTAssertTrue(TerminalText.normalize(transcript).contains("hello bridge"), transcript)
    }
}

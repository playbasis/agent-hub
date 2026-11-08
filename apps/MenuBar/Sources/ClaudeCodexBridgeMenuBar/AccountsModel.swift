import AppKit
import BridgeCore
import Foundation
import SwiftUI

/// Observable state for the two linkable subscriptions plus the Gemini
/// coordinator key. Runs the provider CLIs' own sign-in flows through
/// `AccountLinker`; nothing here ever sees a token.
@MainActor
final class AccountsModel: ObservableObject {
    @Published private(set) var statuses: [LinkedProvider: ProviderAccountStatus] = [:]
    @Published private(set) var phases: [LinkedProvider: AccountLinkPhase] = [:]
    @Published private(set) var refreshing: Set<LinkedProvider> = []
    @Published private(set) var hasLoaded = false
    @Published var pastedCode = ""
    @Published private(set) var geminiKeyStored = false
    @Published private(set) var geminiMessage: String?
    @Published private(set) var lastLinked: LinkedProvider?

    private var linker: AccountLinker?
    private var linkTasks: [LinkedProvider: Task<Void, Never>] = [:]
    private var configuration: BridgeConfiguration?
    /// Fires after a successful link so the plan-usage cards refresh at once.
    var onLinked: ((LinkedProvider) -> Void)?

    func configure(_ configuration: BridgeConfiguration) {
        self.configuration = configuration
        linker = AccountLinker(configuration: configuration.agents)
        geminiKeyStored = CoordinatorSecretStore.resolve(
            environmentVariable: configuration.meta.apiKeyEnvironmentVariable
        ) != nil
    }

    func status(_ provider: LinkedProvider) -> ProviderAccountStatus? { statuses[provider] }

    func phase(_ provider: LinkedProvider) -> AccountLinkPhase { phases[provider] ?? .idle }

    var linkedCount: Int { LinkedProvider.allCases.filter { statuses[$0]?.linked == true }.count }

    var anyLinkInProgress: Bool { phases.values.contains { $0.isActive } }

    func isLinked(_ provider: LinkedProvider) -> Bool { statuses[provider]?.linked == true }

    /// Reads both CLIs' sign-in state. Cheap for Codex (one RPC) and Claude
    /// (`auth status`), so it is safe to run on every panel open.
    func refreshAll() async {
        guard !AcceptanceProbe.isActive else { return }
        guard let linker else { return }
        await withTaskGroup(of: Void.self) { group in
            for provider in LinkedProvider.allCases where phase(provider).isActive == false {
                group.addTask { [weak self] in
                    let status = await linker.status(provider)
                    await self?.apply(status)
                }
            }
        }
        hasLoaded = true
    }

    func refresh(_ provider: LinkedProvider) async {
        guard !AcceptanceProbe.isActive else { return }
        guard let linker, !refreshing.contains(provider) else { return }
        refreshing.insert(provider)
        defer { refreshing.remove(provider) }
        let status = await linker.status(provider)
        apply(status)
        hasLoaded = true
    }

    func beginLink(_ provider: LinkedProvider) {
        guard !AcceptanceProbe.isActive else { return }
        guard let linker, phase(provider).isActive == false else { return }
        pastedCode = ""
        phases[provider] = .preparing
        linkTasks[provider]?.cancel()
        linkTasks[provider] = Task { [weak self] in
            var openedBrowser = false
            for await phase in await linker.link(provider) {
                guard let self else { return }
                self.phases[provider] = phase
                if case let .awaitingBrowser(url, _) = phase, !openedBrowser, !provider.cliOpensBrowser {
                    openedBrowser = true
                    NSWorkspace.shared.open(url)
                }
                if case let .linked(status) = phase {
                    self.apply(status)
                    self.lastLinked = provider
                    self.onLinked?(provider)
                }
            }
            self?.linkTasks[provider] = nil
        }
    }

    func openSignInPage(_ provider: LinkedProvider) {
        switch phase(provider) {
        case let .awaitingBrowser(url, _):
            NSWorkspace.shared.open(url)
        case let .awaitingCode(url?):
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    func submitPastedCode(_ provider: LinkedProvider) {
        guard let linker else { return }
        let code = pastedCode
        pastedCode = ""
        Task { await linker.submitCode(code) }
    }

    func cancelLink(_ provider: LinkedProvider) {
        guard let linker else { return }
        linkTasks[provider]?.cancel()
        linkTasks[provider] = nil
        phases[provider] = .cancelled
        Task { await linker.cancel() }
    }

    func dismissOutcome(_ provider: LinkedProvider) {
        if phase(provider).isTerminal { phases[provider] = .idle }
    }

    func unlink(_ provider: LinkedProvider) {
        guard !AcceptanceProbe.isActive else { return }
        guard let linker else { return }
        refreshing.insert(provider)
        Task { [weak self] in
            let status = await linker.unlink(provider)
            guard let self else { return }
            self.apply(status)
            self.phases[provider] = .idle
            self.refreshing.remove(provider)
        }
    }

    func copyValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: Gemini coordinator key

    func saveGeminiKey(_ key: String) {
        guard !AcceptanceProbe.isActive else { return }
        guard let configuration else { return }
        do {
            try CoordinatorSecretStore.save(key, account: configuration.meta.apiKeyEnvironmentVariable)
            geminiKeyStored = true
            geminiMessage = "Saved privately on this Mac."
        } catch {
            geminiMessage = error.localizedDescription
        }
    }

    func forgetGeminiKey() {
        guard !AcceptanceProbe.isActive else { return }
        guard let configuration else { return }
        do {
            try CoordinatorSecretStore.remove(account: configuration.meta.apiKeyEnvironmentVariable)
            geminiKeyStored = false
            geminiMessage = "Removed."
        } catch {
            geminiMessage = error.localizedDescription
        }
    }

    private func apply(_ status: ProviderAccountStatus) {
        statuses[status.provider] = status
    }

    // MARK: Preview support (BRIDGE_UI_PREVIEW only)

    /// Forces a card into a given state so the sign-in UI can be rendered
    /// and reviewed without a real browser round-trip.
    func applyPreview(_ scenario: String) {
        let url = URL(string: "https://auth.openai.com/oauth/authorize?state=preview")!
        switch scenario {
        case "unlinked":
            statuses[.claude] = ProviderAccountStatus(provider: .claude, installed: true, linked: false, cliVersion: "2.1.258", message: "Sign in with your Claude subscription to link it.")
            statuses[.codex] = ProviderAccountStatus(provider: .codex, installed: true, linked: false, cliVersion: "0.145.0", message: "Sign in with your ChatGPT account to link it.")
            hasLoaded = true
        case "missing":
            statuses[.claude] = ProviderAccountStatus(provider: .claude, installed: false, linked: false, message: "Claude Code is not installed or not on PATH.")
            hasLoaded = true
        case "browser":
            statuses[.codex] = ProviderAccountStatus(provider: .codex, installed: true, linked: false, cliVersion: "0.145.0")
            phases[.codex] = .awaitingBrowser(url: url, code: nil)
            hasLoaded = true
        case "code":
            statuses[.claude] = ProviderAccountStatus(provider: .claude, installed: true, linked: false, cliVersion: "2.1.258")
            phases[.claude] = .awaitingCode(url: url)
            hasLoaded = true
        case "failed":
            statuses[.codex] = ProviderAccountStatus(provider: .codex, installed: true, linked: false, cliVersion: "0.145.0")
            phases[.codex] = .failed("Sign-in timed out before ChatGPT confirmed the account.")
            hasLoaded = true
        default:
            break
        }
    }
}

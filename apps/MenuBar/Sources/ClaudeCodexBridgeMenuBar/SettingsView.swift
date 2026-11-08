import BridgeCore
import SwiftUI

/// Settings is Reports content, sharing its navigation and native window.
/// Draft bindings live in BridgeViewModel and survive sidebar navigation.
@MainActor
struct SettingsView: View {
    @ObservedObject var model: BridgeViewModel
    var openAccounts: (() -> Void)? = nil
    @AppStorage("bridge.showPersonas", store: AcceptanceProbe.defaults) private var showPersonas = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                card("Linked plans", symbol: "person.crop.circle.badge.checkmark") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { accountSummary; Spacer(minLength: 12); accountsButton }
                        VStack(alignment: .leading, spacing: 14) { accountSummary; accountsButton }
                    }
                }
                card("Appearance", symbol: "paintpalette") {
                    Toggle("Show agent personas", isOn: $showPersonas)
                        .accessibilityIdentifier("bridge.settings.personas")
                    note("Give each agent a face from the Playbasis roster, chosen by its role. It stays the same for that agent. Names, models and providers are always shown too.")
                }
                card("Project", symbol: "folder") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default project folder").font(.callout.weight(.medium))
                        HStack(spacing: 10) {
                            TextField("Project path", text: $model.projectPath).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Project folder path")
                            Button("Choose…") { model.chooseProject() }
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Connect Claude to this project") { model.installHooks() }.disabled(model.projectPath.isEmpty)
                        if model.hooksInstalled {
                            Label("Installed locally", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(BridgeTheme.success).font(.caption)
                        }
                    }
                    note("Lets Agent Hub hear when Claude finishes a step in this project. It adds an entry to the project's .claude/settings.local.json and keeps a backup of the file.")
                }
                card("Session defaults", symbol: "clock") {
                    settingRow("Session time limit") {
                        Stepper(value: $model.durationMinutes, in: 30 ... 1_440, step: 30) {
                            Text(durationLabel).monospacedDigit().frame(minWidth: 90, alignment: .trailing)
                        }
                        .accessibilityLabel("Default session time limit")
                        .fixedSize()
                    }
                    settingRow("Start with") {
                        Picker("Starting agent", selection: $model.startingAgent) {
                            Text("Claude").tag(AgentName.claude)
                            Text("Codex").tag(AgentName.codex)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 280)
                        .accessibilityLabel("Default starting agent")
                    }
                    note("Agent Hub can hand work to the other agent when it's a better fit or has more plan capacity left.")
                }
                card("Default models", symbol: "cpu") {
                    providerFields(name: "Claude", model: $model.claudeModel, placeholder: "sonnet", effort: $model.claudeEffort)
                    Divider()
                    providerFields(name: "Codex", model: $model.codexModel, placeholder: "gpt-5.6-sol", effort: $model.codexReasoningEffort)
                    Divider()
                    providerFields(name: "Grok", model: $model.grokModel, placeholder: MetaConfiguration.grokModel, effort: $model.grokReasoningEffort)
                    note("Verification records both the model you asked for and the model the provider says answered.")
                }
                card("Verification & token limits", symbol: "gauge.with.dots.needle.50percent") {
                    settingRow("Before finishing") {
                        Picker("Provider participation required before finishing", selection: Binding(
                            get: { model.requireThreeProvider ? "three" : (model.requireDualProvider ? "two" : "one") },
                            set: { model.requireThreeProvider = $0 == "three"; model.requireDualProvider = $0 != "one" }
                        )) {
                            Text("Claude, Codex and Grok").tag("three")
                            Text("Claude and Codex").tag("two")
                            Text("Allow one provider").tag("one")
                        }
                        .labelsHidden().frame(maxWidth: 300)
                        .accessibilityLabel("Providers required before finishing")
                        .accessibilityIdentifier("bridge.settings.requiredProviders")
                    }
                    note("Checks that the selected providers took part and reported enough detail. This is not an independent guarantee of work quality.")
                    settingRow("Token limit per session") {
                        TextField("No limit", text: $model.tokenCeilingText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .accessibilityLabel("Token limit per session")
                    }
                    settingRow("Tokens to keep in reserve per request") {
                        TextField("Needed when a limit is set", text: $model.turnReservationText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .accessibilityLabel("Tokens to keep in reserve per request")
                    }
                    note("Limits are checked between requests. A request that's already running is allowed to finish and may exceed the limit; the next request then pauses.")
                    Button("Save model settings") { model.persistProviderSettings() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("bridge.settings.saveProviders")
                    if model.settingsRestartRequired {
                        Label("Saved. Restart Agent Hub before starting the next session.", systemImage: "arrow.clockwise.circle")
                            .font(.caption).foregroundStyle(BridgeTheme.warning)
                    }
                }
                card("Privacy & safety", symbol: "lock.shield") {
                    settingRow("Prompt check") { Text(model.classifierLabel).foregroundStyle(.secondary) }
                    settingRow("Provider status") {
                        Label(model.providerStatusLabel, systemImage: model.status.provider.state == .ready ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(model.status.provider.state == .ready ? BridgeTheme.success : BridgeTheme.warning)
                    }
                    settingRow("Codex sandbox") { Text(model.codexSandboxLabel).foregroundStyle(.secondary) }
                    settingRow("Claude permissions") { Text(model.claudePermissionLabel).foregroundStyle(.secondary) }
                    note("Agent Hub never turns on options that skip Claude's or Codex's own permission checks. Prompts are checked on this Mac with built-in rules.")
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.page.settings")
        .onDisappear(perform: model.persistPreferences)
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "settings", state: {
                ["showPersonas": String(showPersonas)]
            }, exercise: {
                guard AcceptanceProbe.isActive, AcceptanceProbe.defaults !== UserDefaults.standard else { return false }
                showPersonas = false
                return true
            })
        }
    }

    private var accountSummary: some View {
        HStack(spacing: 14) {
            HStack(spacing: -8) {
                AgentAvatar(name: "Claude", size: 28, active: model.accounts.isLinked(.claude))
                AgentAvatar(name: "Codex", size: 28, active: model.accounts.isLinked(.codex))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(accountsSummary).font(.callout.weight(.semibold))
                note("Sign in, switch accounts and see plan limits in Accounts.")
            }
        }
    }
    private var accountsButton: some View {
        Button("Open Accounts") {
            if let openAccounts { openAccounts() } else { model.openPage(.accounts) }
        }
        .accessibilityIdentifier("bridge.settings.openAccounts")
    }
    private func providerFields(name: String, model: Binding<String>, placeholder: String, effort: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.callout.weight(.semibold))
            settingRow("Model") {
                TextField(placeholder, text: model).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    .accessibilityLabel("\(name) model")
            }
            settingRow("Thinking effort") {
                Picker("\(name) reasoning effort", selection: effort) {
                    ForEach(["low", "medium", "high", "max"], id: \.self) { value in
                        Text(value == "max" ? "Maximum" : value.capitalized).tag(value)
                    }
                    if !["low", "medium", "high", "max"].contains(effort.wrappedValue) {
                        Text(effort.wrappedValue.capitalized).tag(effort.wrappedValue)
                    }
                }
                .labelsHidden().frame(maxWidth: 200)
                .accessibilityLabel("\(name) reasoning effort")
            }
        }
    }
    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(title).font(.callout).frame(width: 150, alignment: .leading)
                Spacer(minLength: 0)
                content()
            }
            VStack(alignment: .leading, spacing: 8) { Text(title).font(.callout); content() }
        }
    }
    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var accountsSummary: String {
        switch model.accounts.linkedCount {
        case 0: return model.accounts.hasLoaded ? "No subscriptions linked" : "Checking accounts…"
        case 1: return model.accounts.isLinked(.claude) ? "Claude linked · ChatGPT not linked" : "ChatGPT linked · Claude not linked"
        default: return "Claude and ChatGPT linked"
        }
    }
    private var durationLabel: String {
        let hours = model.durationMinutes / 60, minutes = model.durationMinutes % 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
}

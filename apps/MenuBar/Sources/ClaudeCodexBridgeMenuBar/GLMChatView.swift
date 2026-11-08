import AppKit
import BridgeCore
import SwiftUI

private enum GLMInference {
    static let credentialName = "DIGITALOCEAN_INFERENCE_API_KEY"
    static let model = "glm-5.3-flash"
    static let endpoint = URL(string: "https://inference.do-ai.run/v1/chat/completions")!
}

struct GLMChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    var tokenSummary: String?
}

private struct GLMRequest: Encodable {
    let model: String
    let messages: [Turn]
    let maxTokens: Int

    struct Turn: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }
}

private struct GLMResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

@MainActor
final class GLMChatModel: ObservableObject {
    @Published var messages: [GLMChatMessage] = []
    @Published var draft = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var keyDraft = ""
    @Published private(set) var hasKey: Bool

    init() {
        hasKey = CoordinatorSecretStore.resolve(
            environmentVariable: GLMInference.credentialName
        ) != nil
    }

    func saveKey() {
        do {
            try CoordinatorSecretStore.save(keyDraft, account: GLMInference.credentialName)
            keyDraft = ""
            hasKey = true
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the model key. Check local app permissions and try again."
        }
    }

    func removeKey() {
        do {
            try CoordinatorSecretStore.remove(account: GLMInference.credentialName)
            hasKey = CoordinatorSecretStore.resolve(
                environmentVariable: GLMInference.credentialName
            ) != nil
            errorMessage = nil
        } catch {
            errorMessage = "Could not remove the saved model key."
        }
    }

    func clearConversation() {
        guard !isSending else { return }
        messages.removeAll()
        errorMessage = nil
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        guard prompt.count <= 6_000 else {
            errorMessage = "Keep each message under 6,000 characters."
            return
        }
        guard let key = CoordinatorSecretStore.resolve(
            environmentVariable: GLMInference.credentialName
        ) else {
            hasKey = false
            errorMessage = "Add a DigitalOcean model access key to start chatting."
            return
        }

        draft = ""
        errorMessage = nil
        messages.append(GLMChatMessage(role: "user", content: prompt))
        let conversation = messages.suffix(40).map { GLMRequest.Turn(role: $0.role, content: $0.content) }
        isSending = true

        Task {
            defer { isSending = false }
            do {
                var request = URLRequest(url: GLMInference.endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 90
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(
                    GLMRequest(model: GLMInference.model, messages: conversation, maxTokens: 1200)
                )

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    errorMessage = "DigitalOcean Inference returned an invalid response."
                    return
                }
                guard (200 ..< 300).contains(http.statusCode) else {
                    errorMessage = Self.message(for: http.statusCode)
                    if http.statusCode == 401 { hasKey = false }
                    return
                }
                let result = try JSONDecoder().decode(GLMResponse.self, from: data)
                guard let answer = result.choices.first?.message.content?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !answer.isEmpty else {
                    errorMessage = "The model returned an empty chat response."
                    return
                }
                let summary: String?
                if let input = result.usage?.promptTokens,
                   let output = result.usage?.completionTokens, input >= 0, output >= 0
                {
                    summary = "\(input.formatted()) input · \(output.formatted()) output tokens"
                } else {
                    summary = nil
                }
                messages.append(GLMChatMessage(role: "assistant", content: answer, tokenSummary: summary))
            } catch is CancellationError {
                errorMessage = "The request was cancelled."
            } catch let error as URLError where error.code == .timedOut {
                errorMessage = "The request timed out. Check your connection and try again."
            } catch {
                errorMessage = "Could not reach DigitalOcean Inference. Check your connection and try again."
            }
        }
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 401: return "DigitalOcean rejected this key. Save a valid model access key to continue."
        case 402: return "The DigitalOcean Inference prepayment balance is unavailable or empty."
        case 403: return "This key does not have access to GLM-5.3 Flash."
        case 429: return "The model request limit was reached. Wait a moment, then retry."
        case 400: return "The model rejected this request. Clear the chat or shorten the prompt."
        default: return "DigitalOcean Inference returned HTTP \(status). Try again shortly."
        }
    }
}

@MainActor
final class GLMChatController {
    static let shared = GLMChatController()
    lazy var model = GLMChatModel()
    var openInReports: (@MainActor () -> Void)?

    func show() {
        openInReports?()
    }
}

struct GLMChatView: View {
    @ObservedObject var model: GLMChatModel
    var embedded = false
    @FocusState private var composing: Bool
    @State private var keyDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if model.hasKey {
                transcript
                Hairline()
                composer
            } else {
                keySetup
            }
            if let error = model.errorMessage {
                errorBanner(error)
            }
        }
        .background(BridgeTheme.ink)
        .environment(\.colorScheme, .dark)
        .tint(BridgeTheme.glm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.page.glm-chat")
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "glm-chat", state: {
                ["draftLength": String(model.draft.count), "draftDigest": AcceptanceProbe.stateDigest(model.draft)]
            }, exercise: {
                guard model.hasKey, !model.isSending, model.draft.isEmpty else { return false }
                model.draft = "Acceptance draft (not sent)"
                return true
            })
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZaiMark(size: 42)
            VStack(alignment: .leading, spacing: 3) {
                    if !embedded { Text("GLM Chat").font(BridgeFont.title).foregroundStyle(BridgeTheme.textPrimary) }
                HStack(spacing: 6) {
                    Text("Z.ai")
                        .font(BridgeFont.captionMedium)
                        .foregroundStyle(BridgeTheme.glm)
                    Circle().fill(BridgeTheme.textTertiary).frame(width: 3, height: 3)
                    Text(GLMInference.model)
                        .font(BridgeFont.caption)
                        .foregroundStyle(BridgeTheme.textSecondary)
                }
            }
            Spacer()
            if model.hasKey {
                Button {
                    model.clearConversation()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                .disabled(model.messages.isEmpty || model.isSending)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, embedded ? 14 : 28)
        .padding(.bottom, 18)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        ForEach(model.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if model.isSending {
                            HStack(spacing: 10) {
                                ZaiMark(size: 24)
                                ProgressView().controlSize(.small).tint(BridgeTheme.glm)
                                Text("GLM is thinking")
                                    .font(BridgeFont.secondary)
                                    .foregroundStyle(BridgeTheme.textSecondary)
                            }
                            .padding(.leading, 2)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
            .onChange(of: model.messages.count) { _ in
                guard let last = model.messages.last else { return }
                withAnimation(.easeOut(duration: BridgeTheme.reduceMotion ? 0 : 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: model.isSending) { sending in
                guard sending else { return }
                if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            ZaiMark(size: 58)
            Text("What would you like to work through?")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BridgeTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Chat directly with GLM-5.3 Flash. Your conversation stays in memory for this window and is sent to DigitalOcean Inference when you send a message.")
                .font(BridgeFont.secondary)
                .foregroundStyle(BridgeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                Text("Your key stays on this Mac in Agent Hub’s private store.")
            }
            .font(BridgeFont.caption)
            .foregroundStyle(BridgeTheme.textTertiary)
            .padding(.top, 3)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func messageRow(_ message: GLMChatMessage) -> some View {
        let isUser = message.role == "user"
        return HStack(alignment: .top, spacing: 11) {
            if !isUser { ZaiMark(size: 27).padding(.top, 2) }
            VStack(alignment: .leading, spacing: 6) {
                Text(isUser ? "You" : "GLM-5.3 Flash")
                    .font(BridgeFont.captionMedium)
                    .foregroundStyle(isUser ? BridgeTheme.textSecondary : BridgeTheme.glm)
                Text(message.content)
                    .font(BridgeFont.body)
                    .foregroundStyle(BridgeTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let tokenSummary = message.tokenSummary {
                    Text(tokenSummary)
                        .font(BridgeFont.micro)
                        .foregroundStyle(BridgeTheme.textTertiary)
                        .padding(.top, 2)
                    Text("Direct provider response · excluded from native activity totals")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 590, alignment: .leading)
            .background(isUser ? BridgeTheme.glm.opacity(0.14) : BridgeTheme.inkRaised,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isUser ? BridgeTheme.glm.opacity(0.18) : BridgeTheme.surfaceBorder, lineWidth: 1))
            if isUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 9) {
                TextField("Message GLM-5.3 Flash…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(BridgeFont.body)
                    .lineLimit(1 ... 6)
                    .focused($composing)
                    .onSubmit { model.send() }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Message GLM-5.3 Flash")
                Button { model.send() } label: {
                    Image(systemName: model.isSending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(BridgeTheme.ink)
                        .frame(width: 34, height: 34)
                        .background(BridgeTheme.glm, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isSending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send message")
                .keyboardShortcut(.return, modifiers: [.command])
                .padding(6)
            }
            .background(BridgeTheme.inkRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(composing ? BridgeTheme.glm.opacity(0.65) : BridgeTheme.surfaceBorder, lineWidth: 1))
            HStack(spacing: 5) {
                Image(systemName: "dollarsign.circle")
                Text("Usage is billed to your DigitalOcean Inference balance.")
                Spacer()
                Button("Remove key") { model.removeKey() }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textTertiary))
                    .help("Remove the locally saved inference key")
            }
            .font(BridgeFont.micro)
            .foregroundStyle(BridgeTheme.textTertiary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZaiMark(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect DigitalOcean Inference")
                        .font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                    Text("One-time setup for GLM-5.3 Flash")
                        .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                }
            }
            Text("Paste the model access key created for your DigitalOcean team. Agent Hub keeps it in a private file on this Mac that only your account can read, and never shows it again.")
                .font(BridgeFont.secondary)
                .foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("DigitalOcean model access key", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit(saveDraftKey)
                .accessibilityLabel("DigitalOcean model access key")
            HStack {
                Button("Save key and start chatting", action: saveDraftKey)
                    .buttonStyle(BridgePrimaryButtonStyle())
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Text("API calls go directly to DigitalOcean Inference.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            }
        }
        .padding(22)
        .frame(maxWidth: 600, maxHeight: .infinity, alignment: .topLeading)
    }

    private func saveDraftKey() {
        model.keyDraft = keyDraft
        model.saveKey()
        if model.hasKey { keyDraft = "" }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(BridgeTheme.warning)
            Text(text)
                .font(BridgeFont.secondary)
                .foregroundStyle(BridgeTheme.textSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button("Dismiss") { model.errorMessage = nil }
                .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(BridgeTheme.inkRaised)
    }
}

/// A compact, original vector mark for the Z.ai / GLM model identity.
struct ZaiMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(BridgeTheme.glm.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(BridgeTheme.glm.opacity(0.26), lineWidth: 0.8))
            ZMarkShape()
                .fill(BridgeTheme.glm)
                .padding(size * 0.25)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Z.ai GLM logo")
        .accessibilityAddTraits(.isImage)
    }
}

private struct ZMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.27))
        path.addLine(to: CGPoint(x: rect.width * 0.31, y: rect.height * 0.73))
        path.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.73))
        path.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.92))
        path.addLine(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.92))
        path.addLine(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.73))
        path.addLine(to: CGPoint(x: rect.width * 0.69, y: rect.height * 0.27))
        path.addLine(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.27))
        path.closeSubpath()
        return path
    }
}

import AppKit
import BridgeCore
import SwiftUI

@MainActor
final class TeamRoomModel: ObservableObject {
    @Published var rooms: [TeamRoom] = []
    @Published var selected: UUID?
    @Published var drafts: [UUID: String] = [:]
    @Published var error: String?
    @Published var connected = false
    @Published var sending = false
    @Published var discussionOnly = false
    @Published var roles: [RoomRoleCard] = []
    private var pendingMessages: [UUID: RoomCommand] = [:]
    private var pendingCreation: RoomCommand?
    private var client: BridgeAPIClient?
    private var refreshing = false
    var acceptanceRefreshInFlight: Bool { refreshing }
    private var connectionFailed = false
    private var revision: UInt64 = 0
    var room: TeamRoom? { rooms.first { $0.id == selected } }

    func refresh() async {
        guard !refreshing, !Task.isCancelled else { return }
        refreshing = true
        defer { refreshing = false }
        let startedRevision = revision
        do {
            if client == nil { client = BridgeAPIClient(configuration: try ConfigurationStore.load(create: false)) }
            guard let client else { return }
            let latest = try await client.rooms()
            guard !Task.isCancelled, startedRevision == revision else { return }
            rooms = latest
            if selected == nil || !latest.contains(where: { $0.id == selected }) { selected = latest.first?.id }
            connected = true
            if connectionFailed { error = nil; connectionFailed = false }
            // Role documentation should not turn a healthy room connection
            // into a disconnected state when only that optional read fails.
            if roles.isEmpty, let latestRoles = try? await client.roomRoles(), !Task.isCancelled { roles = latestRoles }
        } catch {
            guard !Task.isCancelled, startedRevision == revision else { return }
            connected = false
            connectionFailed = true
            self.error = "Conversation connection unavailable: \(BridgeLogPresentation.text(error.localizedDescription))"
        }
    }

    func perform(_ action: String) async {
        guard !AcceptanceProbe.isActive else { return }
        guard !sending, let client else { return }
        let target = selected
        if action == "messages" {
            guard let target, room?.active == true,
                  !(drafts[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        } else if !action.isEmpty, target == nil { return }
        sending = true
        defer { sending = false }
        do {
            let command: RoomCommand
            if action == "messages", let id = target {
                let text = drafts[id] ?? ""
                if let existing = pendingMessages[id], existing.text == text, existing.discussionOnly == discussionOnly {
                    command = existing
                } else { command = RoomCommand(roomID: id, text: text, discussionOnly: discussionOnly) }
                pendingMessages[id] = command // Retry the same ID after an uncertain network response.
            } else if action.isEmpty {
                command = pendingCreation ?? RoomCommand()
                pendingCreation = command
            } else { command = RoomCommand(roomID: target) }
            let updated = try await client.roomCommand(action, command: command)
            accept(updated)
            if action.isEmpty { selected = updated.id; pendingCreation = nil }
            if action == "messages" {
                // Typing and room selection remain usable while a request is
                // in flight. Clear only the exact draft that was accepted.
                if drafts[updated.id] == command.text { drafts[updated.id] = "" }
                pendingMessages[updated.id] = nil
            }
            error = nil
            await refresh()
        } catch { self.error = BridgeLogPresentation.text(error.localizedDescription) }
    }

    func configure(settings: RoomSettings? = nil, project: String? = nil, roomID: UUID? = nil) async {
        guard !AcceptanceProbe.isActive else { return }
        guard !sending, let client, let id = roomID ?? selected else { return }
        sending = true; defer { sending = false }
        do {
            let updated = try await client.roomCommand("configure", command: RoomCommand(roomID: id, projectPath: project, settings: settings))
            accept(updated)
            error = nil; await refresh()
        } catch { self.error = BridgeLogPresentation.text(error.localizedDescription) }
    }

    private func accept(_ updated: TeamRoom) {
        // An older poll must not erase a room just created or undo the state
        // acknowledged by a completed command.
        revision &+= 1
        connected = true
        connectionFailed = false
        rooms.removeAll { $0.id == updated.id }
        rooms.append(updated)
        rooms.sort { $0.createdAt > $1.createdAt }
    }

    func chooseProject() {
        guard !AcceptanceProbe.isActive else { return }
        guard let roomID = selected else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.message = "Choose the app project this team may work in."
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            Task { await self?.configure(project: url.path, roomID: roomID) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: apply) }
        else { panel.begin(completionHandler: apply) }
    }
}

@MainActor
final class TeamRoomController: NSObject {
    static let shared = TeamRoomController()
    let model = TeamRoomModel()
    var openInReports: (@MainActor () -> Void)?
    private var previewWindow: NSWindow?

    func show() {
        openInReports?()
    }

    /// Render the real native view for layout QA without screen-recording access.
    func renderPreview() async {
        guard let path = ProcessInfo.processInfo.environment["BRIDGE_ROOM_SNAPSHOT"] else { return }
        await model.refresh()
        let setupOnly = ProcessInfo.processInfo.environment["BRIDGE_ROOM_SETUP_PREVIEW"] == "1"
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: setupOnly ? 560 : 960, height: setupOnly ? 640 : 700), styleMask: [.titled], backing: .buffered, defer: false)
        preview.appearance = NSAppearance(named: .darkAqua)
        if setupOnly { preview.contentView = NSHostingView(rootView: TeamRoomView(model: model).setup) }
        else { preview.contentView = NSHostingView(rootView: TeamRoomView(model: model)) }
        preview.orderFrontRegardless()
        previewWindow = preview
        if let width = ProcessInfo.processInfo.environment["BRIDGE_ROOM_PREVIEW_WIDTH"].flatMap(Double.init) {
            previewWindow?.setContentSize(NSSize(width: width, height: 700))
        }
        try? await Task.sleep(for: .seconds(2))
        guard let view = (previewWindow?.sheets.first ?? previewWindow)?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        NSApp.terminate(nil)
    }
}

private struct TeamTranscriptContent: Equatable {
    let roomID: UUID
    let messages: [RoomMessage]
}

private struct TeamTranscriptScrollRequest: Equatable {
    let content: TeamTranscriptContent
    let followsLatest: Bool
    let jumpID: UUID
}

private struct TeamTranscriptBottomKey: PreferenceKey {
    static var defaultValue: CGFloat { .greatestFiniteMagnitude }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The plan is the denominator. Missing work receipts must not make a partial
/// plan look finished, and repeated receipts must never inflate progress.
enum TeamPlanPresentation {
    static func tasks(_ plan: RoomPlan) -> [RoomWork] {
        var seen: Set<String> = []
        return plan.tasks.filter { seen.insert($0.id).inserted }
    }

    static func records(room: TeamRoom, plan: RoomPlan) -> [RoomWorkRecord] {
        let tasks = tasks(plan)
        let work = room.work ?? []
        func matches(_ record: RoomWorkRecord) -> Bool {
            tasks.contains { $0.id == record.task.id && $0.owner == record.task.owner && $0.title == record.task.title && $0.kind == record.task.kind }
        }
        // Work is an append-ordered journal. A live round is authoritative;
        // completed rooms retain the latest matching plan's round.
        guard let round = room.round ?? work.last(where: matches)?.round else { return [] }
        var latest: [String: RoomWorkRecord] = [:]
        for record in work where record.round == round && matches(record) { latest[record.task.id] = record }
        return tasks.compactMap { latest[$0.id] }
    }

    static func reportedModel(_ record: RoomWorkRecord, settings: RoomSettings?) -> String {
        if let value = record.model?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return "Provider reported: \(value)" }
        let configured: String?
        switch record.task.owner {
        case "Claude": configured = settings?.claudeModel
        case "Codex": configured = settings?.codexModel
        case "Gemini": configured = settings?.geminiModel
        default: configured = nil
        }
        return configured.map { "Requested: \($0) · provider model not reported" } ?? "Model not reported"
    }
}

struct TeamRoomView: View {
    @ObservedObject var model: TeamRoomModel
    @FocusState private var composing: Bool
    @State private var showSetup = false
    @State private var editingSettings = RoomSettings()
    @State private var showWork = true
    @State private var followsLatest = true
    @State private var transcriptAtBottom = true
    @State private var displayedTranscript: TeamTranscriptContent?
    @State private var jumpToLatest = UUID()
    @State private var scrollingGeneration: UUID?

    @MainActor
    init(model: TeamRoomModel) {
        self.model = model
        _editingSettings = State(initialValue: model.room?.settings ?? RoomSettings())
    }

    private var participants: [String] {
        let lead = model.room?.settings?.leadName ?? "Gemini"
        return [lead] + ["Claude", "Codex", "Gemini"].filter { $0 != lead }
    }

    var body: some View {
        VStack(spacing: 0) {
            conversationControls
            Hairline()
            if let room = model.room {
                header
                Hairline()
                runningStrip(room)
                transcript(room)
                Hairline()
                composer(room)
            } else {
                emptyRoomState
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(BridgeTheme.warning)
                    Text(error).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).textSelection(.enabled)
                    Spacer()
                    Button(model.connected ? "Refresh" : "Reconnect") { Task { await model.refresh() } }
                        .buttonStyle(BridgeLinkButtonStyle())
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(BridgeIconButtonStyle())
                        .accessibilityLabel("Dismiss conversation error")
                }
                .padding(12)
                .background(BridgeTheme.inkRaised)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BridgeTheme.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("teamChat.page")
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "team-chat", state: {
                var state = AcceptanceProbe.serviceFields(loading: model.acceptanceRefreshInFlight, ready: model.connected, hasData: model.room != nil,
                    error: !model.connected && model.error != nil, unsupported: RefreshAcceptance.isReplayMode && model.room == nil, itemCount: model.rooms.count)
                state["workVisible"] = String(showWork); state["followLatest"] = String(followsLatest)
                return state
            }, exercise: {
                guard model.connected, !model.acceptanceRefreshInFlight, model.room != nil else { return false }
                showWork = false
                followsLatest = false
                return true
            })
        }
        .sheet(isPresented: $showSetup) { setup }
        .onChange(of: model.selected) { _ in composing = false }
        .task {
            // Replay stays offline. Live acceptance reads the existing local
            // room history only; all room mutation entry points are disabled.
            guard !RefreshAcceptance.isReplayMode else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(model.room?.busy == true ? 1 : 5)) } catch { break }
            }
        }
    }

    // MARK: Conversation controls

    /// Reports owns application navigation. Conversations stay in a compact
    /// page control rather than introducing a competing second sidebar.
    private var conversationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                conversationPicker
                Spacer(minLength: 12)
                connectionStatus
                newConversationButton
            }
            VStack(alignment: .leading, spacing: 10) {
                conversationPicker
                HStack {
                    connectionStatus
                    Spacer()
                    newConversationButton
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(BridgeTheme.inkRaised)
    }

    private var conversationPicker: some View {
        Menu {
            if model.rooms.isEmpty { Text("No conversations yet") }
            else {
                ForEach(model.rooms) { room in
                    Button {
                        model.selected = room.id
                        composing = false
                    } label: {
                        if model.selected == room.id {
                            Label(conversationTitle(room), systemImage: "checkmark")
                        } else {
                            Text(conversationTitle(room))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text(model.room.map(conversationTitle) ?? "Conversations")
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(BridgeFont.secondaryMedium)
            .frame(maxWidth: 320, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Choose conversation")
        .accessibilityValue(model.room.map(conversationTitle) ?? "No conversation selected")
        .accessibilityIdentifier("teamChat.conversationPicker")
    }

    private var connectionStatus: some View {
        StatusDot(text: model.connected ? "Connected locally" : (model.error == nil ? "Connecting locally…" : "Connection unavailable"), color: model.connected ? BridgeTheme.success : BridgeTheme.warning)
            .fixedSize()
            .help("Conversation history stays on this Mac. Starting a team or sending a message lets it contact providers; an active round can continue while you read another page.")
    }

    private var newConversationButton: some View {
        Button { Task { await model.perform("") } } label: {
            Label("New conversation", systemImage: "square.and.pencil")
        }
        .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
        .disabled(!model.connected || model.sending)
        .accessibilityIdentifier("teamChat.newConversation")
    }

    private func conversationTitle(_ room: TeamRoom) -> String {
        let source = room.messages.first(where: { $0.author == "You" })?.text ?? room.title
        let firstLine = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? room.title
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? room.title : trimmed
        return title.count > 100 ? String(title.prefix(100)) + "…" : title
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    roomStatus
                    Spacer(minLength: 8)
                    projectControls
                }
                VStack(alignment: .leading, spacing: 10) {
                    roomStatus
                    projectControls
                }
            }
            // The team strip scrolls sideways rather than wrapping, so a
            // narrow window never breaks a name or model ID mid-word.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(participants, id: \.self) { name in
                        participantPill(name, lead: name == (model.room?.settings?.leadName ?? "Gemini"))
                            .fixedSize()
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var roomStatus: some View {
        HStack(spacing: 8) {
            Text(model.room?.title ?? "Team conversation")
                .font(BridgeFont.heading)
                .foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            if let mode = model.room?.plan?.mode { Tag(text: mode.rawValue.capitalized).fixedSize() }
            if model.room?.active == true {
                StatusDot(text: model.room?.busy == true ? "Working" : "Active", color: BridgeTheme.success).fixedSize()
            }
        }
    }

    private var projectControls: some View {
        HStack(spacing: 8) {
            if let path = model.room?.projectPath {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                .frame(maxWidth: 200)
                .help(path)
                .accessibilityLabel("Open project \(URL(fileURLWithPath: path).lastPathComponent)")
            } else {
                Button("Attach project") { model.chooseProject() }
                    .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                    .fixedSize()
                    .disabled(model.room == nil || model.room?.busy == true || model.sending)
            }
            Button { editingSettings = model.room?.settings ?? RoomSettings(); showSetup = true } label: {
                Label("Team setup", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
            .help("Models, roles and skill playbooks")
            .accessibilityIdentifier("teamChat.setup")
        }
    }

    private func participantPill(_ name: String, lead: Bool) -> some View {
        let thinking = model.room?.messages.contains(where: { $0.author == name && $0.state == "thinking" }) == true
            || (model.room?.work ?? []).contains(where: { $0.round == model.room?.round && $0.state == "running" && $0.task.owner == name })
        let modelName: String? = {
            guard let settings = model.room?.settings else { return nil }
            if lead { return settings.selectedLeadModel }
            switch name {
            case "Claude": return settings.claudeModel
            case "Codex": return settings.codexModel
            case "Gemini": return settings.geminiModel
            default: return nil
            }
        }()
        return HStack(spacing: 7) {
            AgentAvatar(name: name, size: 18, thinking: thinking)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(name).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                    if lead {
                        Text("Lead").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                    }
                }
                Text(thinking ? "Working…" : (modelName.map(ModelNaming.display) ?? (lead ? "Lead" : "Teammate")))
                    .font(BridgeFont.micro)
                    .foregroundStyle(thinking ? BridgeTheme.textSecondary : BridgeTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, 4)
        .help("\(name) · \(lead ? "team lead" : "teammate") · \(modelName ?? "default model")")
    }

    @ViewBuilder
    private func runningStrip(_ room: TeamRoom) -> some View {
        if room.busy, let records = room.work {
            let running = records.filter { $0.round == room.round && $0.state == "running" }
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(running) { record in
                        HStack(spacing: 8) {
                            AgentAvatar(name: record.task.owner, size: 14, thinking: true)
                            Text(record.task.title).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                            Spacer()
                            Text(record.activities.last?.label ?? "Starting session")
                                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(BridgeTheme.inkRaised)
                Hairline()
            }
        }
    }

    private var emptyRoomState: some View {
        VStack(spacing: 14) {
            Spacer()
            HStack(spacing: -6) {
                AgentAvatar(name: "Claude", size: 30)
                AgentAvatar(name: "Gemini", size: 30)
                AgentAvatar(name: "Codex", size: 30)
            }
            Text("A room for your team")
                .font(BridgeFont.title)
                .foregroundStyle(BridgeTheme.textPrimary)
            Text("Claude, Codex and Gemini work as one unit: a lead plans, teammates build, everyone can ask each other for help.")
                .font(BridgeFont.secondary)
                .foregroundStyle(BridgeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Create room") { Task { await model.perform("") } }
            .buttonStyle(BridgePrimaryButtonStyle())
            .disabled(!model.connected || model.sending)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Transcript

    private func transcript(_ room: TeamRoom) -> some View {
        let content = TeamTranscriptContent(roomID: room.id, messages: room.messages)
        let request = TeamTranscriptScrollRequest(content: content, followsLatest: followsLatest, jumpID: jumpToLatest)
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if let plan = room.plan, !plan.tasks.isEmpty {
                                    planCard(room, plan: plan)
                                }
                                if room.messages.isEmpty {
                                    TeamChatWelcome()
                                        .padding(.vertical, 24)
                                }
                                ForEach(room.messages) { message in
                                    MessageRow(message: message)
                                }
                            }
                            .padding(20)
                            // Keep this marker outside the lazy stack so its
                            // position remains measurable while reading history.
                            Color.clear.frame(height: 1).id("bottom")
                                .background {
                                    GeometryReader { bottom in
                                        Color.clear.preference(key: TeamTranscriptBottomKey.self,
                                            value: bottom.frame(in: .named("teamTranscript")).maxY)
                                    }
                                }
                        }
                    }
                    .coordinateSpace(name: "teamTranscript")
                    .onPreferenceChange(TeamTranscriptBottomKey.self) { bottom in
                        let atBottom = bottom >= 0 && bottom <= viewport.size.height + 24
                        transcriptAtBottom = atBottom
                        // A new response changes layout before scrolling can
                        // run. Only a stable, non-programmatic position change
                        // represents the reader moving through the transcript.
                        guard displayedTranscript == content, scrollingGeneration == nil else { return }
                        followsLatest = atBottom
                    }
                }
                transcriptControls
            }
            .task(id: request) {
                let generation = UUID()
                scrollingGeneration = generation
                defer { if scrollingGeneration == generation { scrollingGeneration = nil } }
                let changedRoom = displayedTranscript?.roomID != room.id
                displayedTranscript = content
                if changedRoom { followsLatest = true }
                guard followsLatest else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
                // Keep geometry from treating the new content's intermediate
                // layout as a user scroll. This task is cancelled on navigation.
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var transcriptControls: some View {
        HStack(spacing: 12) {
            Toggle("Follow latest", isOn: $followsLatest)
                .toggleStyle(.checkbox)
                .font(BridgeFont.caption)
                .accessibilityIdentifier("teamChat.followLatest")
                .accessibilityHint("Keeps new team messages in view. Scrolling back pauses following.")
            if !followsLatest {
                Text("Reading history").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            }
            Spacer(minLength: 8)
            if !transcriptAtBottom || !followsLatest {
                Button {
                    followsLatest = true
                    jumpToLatest = UUID()
                } label: {
                    Label("Jump to latest", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(BridgeLinkButtonStyle())
                .accessibilityIdentifier("teamChat.jumpToLatest")
                .accessibilityHint("Shows the newest message and resumes following incoming messages.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(BridgeTheme.inkRaised)
    }

    private func planCard(_ room: TeamRoom, plan: RoomPlan) -> some View {
        let tasks = TeamPlanPresentation.tasks(plan)
        let records = TeamPlanPresentation.records(room: room, plan: plan)
        let complete = records.filter { $0.state == "complete" }.count
        return VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(BridgeTheme.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { showWork.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showWork ? 90 : 0))
                        .foregroundStyle(BridgeTheme.textTertiary)
                    SectionTitle(text: "\(plan.mode == .implement ? "Build" : "Review") plan")
                    Spacer()
                    if !tasks.isEmpty {
                        Text("\(complete) of \(tasks.count) finished")
                            .font(BridgeFont.caption.monospacedDigit())
                            .foregroundStyle(BridgeTheme.textSecondary)
                        ProgressView(value: Double(complete), total: Double(max(tasks.count, 1)))
                            .progressViewStyle(.linear)
                            .tint(BridgeTheme.success)
                            .frame(width: 70)
                            .accessibilityLabel("Team steps finished")
                            .accessibilityValue("\(complete) of \(tasks.count)")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showWork ? "Collapse team plan" : "Expand team plan")
            .help("Finished means the provider process returned successfully, not that the work has been independently accepted.")
            if showWork {
                Text(plan.contract).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    ForEach(records) { record in
                        WorkRecordRow(record: record, settings: room.settings)
                    }
                    ForEach(tasks.filter { task in !records.contains(where: { $0.task.id == task.id }) }) { task in
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle").foregroundStyle(BridgeTheme.warning)
                            Text(task.title).font(BridgeFont.secondary)
                            Spacer()
                            Text("Progress not reported").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                        }
                        .padding(9).bridgeWell()
                    }
                }
            }
        }
        .bridgeCard()
    }

    // MARK: Composer

    private func composer(_ room: TeamRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !room.active {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Team is paused").font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                        Text("Start the team so the lead can read this chat and hand out work.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    }
                    Spacer()
                    Button("Start team") { Task { await model.perform("activate"); composing = true } }
                    .buttonStyle(BridgePrimaryButtonStyle())
                    .disabled(!model.connected || model.sending)
                    .accessibilityIdentifier("teamChat.activate")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Message your team…", text: Binding(get: { model.drafts[room.id] ?? "" }, set: { model.drafts[room.id] = $0 }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(BridgeFont.body)
                        .foregroundStyle(BridgeTheme.textPrimary)
                        .lineLimit(2...6)
                        .focused($composing)
                        .accessibilityLabel("Message your team")
                        .accessibilityIdentifier("teamChat.composer")
                    HStack(spacing: 10) {
                        Picker("Message mode", selection: $model.discussionOnly) {
                            Text("Auto").tag(false)
                            Text("Discuss").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 130)
                        .help("Auto lets the lead route the request; Discuss keeps it conversational.")
                        Text(room.busy ? "Team activity is live · Stop cancels this round" : "⌘ Return to send")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if room.busy {
                            Button("Stop round") { Task { await model.perform("stop") } }
                            .buttonStyle(BridgeSecondaryButtonStyle(destructive: true, compact: true))
                            .disabled(model.sending)
                            .accessibilityIdentifier("teamChat.stopRound")
                        } else {
                            Button("Send") { Task { await model.perform("messages"); composing = true } }
                            .buttonStyle(BridgePrimaryButtonStyle(compact: true))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.sending || !model.connected || (model.drafts[room.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("teamChat.send")
                        }
                    }
                }
                .padding(12)
                .bridgeWell(cornerRadius: 10)
            }
        }
        .padding(16)
    }

    // MARK: Setup sheet

    fileprivate var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Team setup").font(BridgeFont.title).foregroundStyle(BridgeTheme.textPrimary)
                    Text("Roles stay stable. Models are yours to choose; changes apply to the next round.")
                        .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                }
                Spacer()
                Button("Done") { showSetup = false }.buttonStyle(BridgeSecondaryButtonStyle(compact: true)).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    setupSection("Lead", icon: "crown.fill", tint: BridgeTheme.warning) {
                        Picker("Team lead", selection: Binding(get: { editingSettings.leadName }, set: { provider in
                            editingSettings.leadProvider = provider
                            editingSettings.leadModel = provider == "Codex" ? "gpt-6-astra" : provider == "Claude" ? "claude-fable-5-1" : editingSettings.geminiModel
                        })) {
                            Text("Gemini").tag("Gemini")
                            Text("Codex").tag("Codex")
                            Text("Claude").tag("Claude")
                        }
                        .pickerStyle(.segmented)
                        modelField("Lead model", value: Binding(get: { editingSettings.selectedLeadModel }, set: { editingSettings.leadModel = $0 }), presets: editingSettings.leadName == "Codex" ? ["gpt-6-astra", "gpt-5.6-sol"] : editingSettings.leadName == "Claude" ? ["claude-fable-5-1", "claude-opus-5"] : ["gemini-3.7-flash", "gemini-3.5-flash"])
                        Text("Premium lead; economical workers. Start small, reuse evidence and reserve capacity for integration and verification.")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    setupSection("Claude · frontend", icon: nil, tint: BridgeTheme.claude, avatar: "Claude") {
                        modelField("Model", value: $editingSettings.claudeModel, presets: ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "sonnet"])
                        effortField("Effort", value: $editingSettings.claudeEffort)
                    }
                    setupSection("Codex · backend", icon: nil, tint: BridgeTheme.codex, avatar: "Codex") {
                        modelField("Model", value: $editingSettings.codexModel, presets: ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra"])
                        effortField("Effort", value: $editingSettings.codexEffort)
                    }
                    setupSection("Gemini · teammate", icon: nil, tint: BridgeTheme.gemini, avatar: "Gemini") {
                        modelField("Model", value: $editingSettings.geminiModel, presets: ["gemini-3.7-flash", "gemini-3.5-flash"])
                    }
                    setupSection("Limits", icon: "gauge.with.dots.needle.33percent", tint: .secondary) {
                        Stepper("Parallel scouts: \(editingSettings.maxParallelScouts)", value: $editingSettings.maxParallelScouts, in: 1...3)
                        Stepper("Consultations per round: \(editingSettings.helpLimit ?? 6)", value: Binding(get: { editingSettings.helpLimit ?? 6 }, set: { editingSettings.helpLimit = $0 }), in: 1...12)
                        Stepper("Worker timeout: \(editingSettings.workerTimeoutSeconds / 60) minutes", value: $editingSettings.workerTimeoutSeconds, in: 60...900, step: 60)
                        Text("Preset names do not guarantee account access. Custom model IDs are passed to the provider unchanged; no fallback model is substituted.")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    DisclosureGroup("Runtime overrides") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Automatic prefers the desktop Codex runtime. Set an executable path to choose another installed CLI.")
                                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                            TextField("Codex executable · automatic", text: Binding(get: { editingSettings.codexCommand ?? "" }, set: { editingSettings.codexCommand = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                            TextField("Claude executable · configured default", text: Binding(get: { editingSettings.claudeCommand ?? "" }, set: { editingSettings.claudeCommand = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                        }
                        .padding(.top, 8)
                    }
                    .font(BridgeFont.secondaryMedium)
                    DisclosureGroup("System prompts & skill playbooks") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.roles) { role in
                                DisclosureGroup(role.role) {
                                    Text(role.instructions).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).textSelection(.enabled).padding(.top, 6)
                                }
                                .font(BridgeFont.secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(BridgeFont.secondaryMedium)
                }
                .padding(.trailing, 6)
            }
            HStack {
                if model.room?.projectPath != nil {
                    Button("Detach project") { Task { await model.configure(project: "") } }
                        .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.danger))
                        .disabled(model.room?.busy == true || model.sending)
                }
                Spacer()
                Button("Save for this room") { Task { await model.configure(settings: editingSettings); if model.error == nil { showSetup = false } } }
                    .buttonStyle(BridgePrimaryButtonStyle())
                    .disabled(model.room == nil || model.room?.busy == true || model.sending)
            }
            if let error = model.error { Text(error).font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning) }
        }
        .padding(22)
        .frame(width: 560, height: 640)
        .background(BridgeTheme.ink)
        .accessibilityIdentifier("teamChat.setupSheet")
    }

    private func setupSection<Content: View>(_ title: String, icon: String?, tint: Color, avatar: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let avatar {
                    AgentAvatar(name: avatar, size: 16)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                }
                Text(title).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
            }
            content()
        }
        .bridgeCard(padding: 12)
    }

    private func modelField(_ title: String, value: Binding<String>, presets: [String]) -> some View {
        HStack(spacing: 8) {
            Text(title).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).frame(width: 74, alignment: .leading)
            TextField("Provider model ID", text: value)
                .textFieldStyle(.plain)
                .font(BridgeFont.mono)
                .foregroundStyle(BridgeTheme.textPrimary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .bridgeWell(cornerRadius: 6)
                .accessibilityLabel(title + " model")
            Menu("Presets") { ForEach(presets, id: \.self) { preset in Button(preset) { value.wrappedValue = preset } } }
                .frame(width: 90)
        }
    }

    private func effortField(_ title: String, value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).frame(width: 74, alignment: .leading)
            Picker(title, selection: value) { ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
        }
    }
}

/// One transcript entry. Teammates get an avatar and a left-aligned card; the
/// user's own messages sit right-aligned on the bridge gradient.
private struct MessageRow: View {
    var message: RoomMessage

    private var isUser: Bool { message.author == "You" }
    private var tint: Color { BridgeTheme.color(forParticipant: message.author) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(name: message.author, size: 22, thinking: message.state == "thinking")
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(message.author).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                    if let recipient = message.recipient {
                        Text("→ \(recipient)").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    }
                    if let kind = message.kind { Tag(text: kind) }
                    if let name = message.model {
                        Text(name).font(.system(size: 10, design: .monospaced)).foregroundStyle(BridgeTheme.textTertiary)
                            .lineLimit(1).truncationMode(.middle).help(name)
                    }
                    Spacer(minLength: 8)
                    Text(message.date, style: .time).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                }
                if message.state == "thinking" {
                    Text("Thinking…").font(BridgeFont.body).foregroundStyle(BridgeTheme.textSecondary)
                } else {
                    Text(message.text)
                        .font(BridgeFont.body)
                        .foregroundStyle(message.state == "complete" || isUser ? BridgeTheme.textPrimary : BridgeTheme.warning)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(isUser ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isUser {
                    RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous)
                        .fill(BridgeTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous)
                                .strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1)
                        )
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WorkRecordRow: View {
    var record: RoomWorkRecord
    var settings: RoomSettings?
    @State private var expanded = false

    private var stateColor: Color {
        switch record.state {
        case "complete": return BridgeTheme.success
        case "running": return BridgeTheme.codex
        case "failed", "blocked", "cancelled": return BridgeTheme.danger
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(BridgeTheme.reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    AgentAvatar(name: record.task.owner, size: 16, thinking: record.state == "running")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.task.title).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(expanded ? nil : 1)
                        Text("\(record.task.owner) · \(record.task.kind.rawValue.capitalized)").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    Spacer()
                    StatusDot(text: record.state.capitalized, color: stateColor)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(record.task.title), \(record.state). \(expanded ? "Hide" : "Show") step details")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.task.prompt).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(TeamPlanPresentation.reportedModel(record, settings: settings))
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    if let session = record.sessionID {
                        Text("Session \(session)").font(.system(size: 10, design: .monospaced)).foregroundStyle(BridgeTheme.textTertiary).textSelection(.enabled)
                    }
                    ForEach(record.activities) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: event.kind == "subagent" ? "person.2" : "terminal")
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(BridgeTheme.textSecondary).frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.label).foregroundStyle(BridgeTheme.textSecondary)
                                if event.kind == "subagent", let id = event.nativeID {
                                    Text("Reference \(id)").foregroundStyle(BridgeTheme.textTertiary).lineLimit(1).textSelection(.enabled)
                                }
                                if let parent = event.parentID { Text("Parent \(parent)").foregroundStyle(BridgeTheme.textTertiary).lineLimit(1) }
                            }
                        }
                        .font(BridgeFont.caption)
                    }
                    if let result = record.result {
                        Text(result).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(9)
        .bridgeWell()
    }
}


/// First-run guidance as three steps instead of a paragraph.
private struct TeamChatWelcome: View {
    private let steps: [(icon: String, title: String, detail: String)] = [
        ("folder.badge.plus", "Attach a project", "Pick the folder the team should work in."),
        ("play.circle", "Start the team", "The lead reads the chat and splits the work between Claude, Codex and Gemini."),
        ("text.bubble", "Ask for something", "Choose Discuss to talk it through, or Auto to let the lead decide when to build."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: -6) {
                AgentAvatar(name: "Gemini", size: 26)
                AgentAvatar(name: "Claude", size: 26)
                AgentAvatar(name: "Codex", size: 26)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Your team is ready").font(.system(size: 18, weight: .semibold)).foregroundStyle(BridgeTheme.textPrimary)
                Text("A lead plans, teammates build, and anyone can ask the others for help.")
                    .font(BridgeFont.body).foregroundStyle(BridgeTheme.textSecondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(BridgeTheme.ink).frame(width: 18, height: 18)
                                .background(BridgeTheme.brand, in: Circle())
                            Image(systemName: step.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                        }
                        Text(step.title).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                        Text(step.detail).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                    .bridgeCard(padding: 0)
                }
            }
            Text("Choose each teammate's model in Team setup. Sub-agents and tool activity show up in the build plan.")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

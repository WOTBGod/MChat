import SwiftUI
import SwiftData
import FoundationModels
import AppKit

struct ChatView: View {
    static let baseInstructions = """
    You are a helpful, friendly assistant running privately on the user's Mac.
    Answer questions directly and clearly.
    When notes from the user's vault or attached files are provided, use them as your main source. \
    You may draw reasonable conclusions from them, such as what the user has already covered and what they might study next.
    The user may change topics at any time; when they do, follow the new topic.
    Keep answers concise.
    """

    static let progressPhrases = [
        "left off", "where am i", "where was i", "progress", "recent", "latest",
        "last time", "what's next", "what next", "next step", "catch me up", "so far"
    ]

    static let overviewPhrases = [
        "summarize", "summary", "overview", "what is this", "what's this", "this file",
        "this document", "this pdf", "key points", "main points", "tl;dr", "tldr"
    ]

    static let listPhrases = [
        "list", "all the", "all of", "every", "how many", "what are the", "which ones",
        "show me all", "everything", "count", "total"
    ]

    // Requests to repeat or reformat the last answer: no note search needed
    static let repeatPhrases = [
        "retype", "repeat", "same list", "say that again", "again", "reformat",
        "as a table", "shorter", "rephrase"
    ]

    /// Largest amount of one note we'll send whole (~2,000 tokens)
    static let wholeNoteCharLimit = 8_000

    /// Questions this short are treated as follow-ups and searched with the previous question
    static let followUpWordLimit = 10

    let conversation: Conversation
    let vault: VaultSearch?
    let useVault: Bool

    @Environment(\.modelContext) private var context
    @AppStorage("vaultDescription") private var vaultDescription = ""
    @State private var session: LanguageModelSession
    @State private var instructionsText: String
    @State private var sessionStartOrder: Int
    @State private var draft = ""
    @State private var isResponding = false
    @State private var responseTask: Task<Void, Never>?
    @State private var tokenCount: Int?
    @FocusState private var inputFocused: Bool

    // Attachments
    @State private var attachmentIndex: VaultSearch?
    @State private var showFilePicker = false
    @State private var isDropTargeted = false
    @State private var attachError: String?

    init(conversation: Conversation, vault: VaultSearch?, useVault: Bool) {
        self.conversation = conversation
        self.vault = vault
        self.useVault = useVault

        let earlier = Self.recentHistory(conversation.sortedMessages)
        let instructions = earlier.isEmpty
            ? Self.baseInstructions
            : Self.baseInstructions + "\n\nEarlier in this conversation:\n" + earlier
        _instructionsText = State(initialValue: instructions)
        _session = State(initialValue: LanguageModelSession(instructions: instructions))
        _sessionStartOrder = State(initialValue: (conversation.sortedMessages.last?.order ?? -1) + 1)
    }

    // MARK: - Memory meter

    var contextLimit: Int { SystemLanguageModel.default.contextSize }

    var sessionText: String {
        ([instructionsText] + conversation.sortedMessages
            .filter { $0.order >= sessionStartOrder && !$0.isNotice }
            .map { $0.sentText ?? $0.text })
            .joined(separator: "\n")
    }

    var displayedTokens: Int { tokenCount ?? sessionText.count / 4 }

    func refreshTokenCount() async {
        tokenCount = try? await SystemLanguageModel.default.tokenCount(for: Instructions(sessionText))
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !isResponding
    }

    // MARK: - Layout

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(conversation.sortedMessages) { message in
                            MessageBubble(message: message)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: conversation.sortedMessages.last?.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            attachmentBar
            inputBar
        }
        .navigationTitle(conversation.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    ProgressView(value: min(Double(displayedTokens) / Double(contextLimit), 1))
                        .frame(width: 70)
                    Text("\(tokenCount == nil ? "~" : "")\(displayedTokens) / \(contextLimit)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .help(tokenCount == nil ? "Estimated model memory used" : "Model memory used (exact)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .overlay(Text("Drop to attach").font(.title3).padding(12).glassEffect())
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: DocumentReader.supportedTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .onAppear(perform: rebuildAttachmentIndex)
        .task { await refreshTokenCount() }
    }

    @ViewBuilder
    var attachmentBar: some View {
        if !conversation.attachments.isEmpty || attachError != nil {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(conversation.sortedAttachments) { file in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                Text(file.name).lineLimit(1)
                                Button { removeAttachment(file) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from this chat")
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(in: .capsule)
                        }
                    }
                    .padding(.horizontal)
                }
                if let attachError {
                    Text(attachError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.top, 6)
        }
    }

    var inputBar: some View {
        HStack(spacing: 8) {
            Button { showFilePicker = true } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .help("Attach files (PDF, Word, text)")
            .padding(.leading, 6)

            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(send)

            if isResponding {
                Button(action: stop) {
                    Image(systemName: "stop.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .help("Stop generating (Esc)")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
            }
        }
        .padding(8)
        .glassEffect(in: .rect(cornerRadius: 22))
        .padding()
        .onAppear { inputFocused = true }
    }

    // MARK: - Attachments

    func addFiles(_ urls: [URL]) {
        attachError = nil
        for url in urls {
            let allowed = url.startAccessingSecurityScopedResource()
            defer { if allowed { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try DocumentReader.text(from: url)
                conversation.attachments.append(Attachment(name: url.lastPathComponent, text: text))
            } catch {
                attachError = error.localizedDescription
            }
        }
        rebuildAttachmentIndex()
        inputFocused = true
    }

    func removeAttachment(_ file: Attachment) {
        conversation.attachments.removeAll { $0 == file }
        context.delete(file)
        rebuildAttachmentIndex()
    }

    func rebuildAttachmentIndex() {
        let docs = conversation.sortedAttachments.map { (name: $0.name, text: $0.text) }
        attachmentIndex = docs.isEmpty ? nil : VaultSearch(documents: docs)
    }

    // MARK: - Building the prompt

    func buildPrompt(for question: String, previousQuestion: String?) -> (prompt: String, sources: [String]) {
        let lower = question.lowercased()
        // "Retype that" / "repeat the list": answer from the conversation, not the notes
        if Self.repeatPhrases.contains(where: { lower.contains($0) }) {
            return ("\(question)\n\n(Use your previous answer in this conversation.)", [])
        }

        // Short follow-ups are searched together with the previous question
        let wordCount = question.split(separator: " ").count
        let searchQuery: String
        if let previousQuestion, wordCount <= Self.followUpWordLimit {
            searchQuery = previousQuestion + " " + question
        } else {
            searchQuery = question
        }
        let searchLower = searchQuery.lowercased()

        let isListQuestion = Self.listPhrases.contains { lower.contains($0) }
        var parts: [String] = []
        var allHits: [NoteChunk] = []
        var mayBeIncomplete = false

        // 1. Attached files
        if let attachmentIndex {
            let wantsOverview = Self.overviewPhrases.contains { lower.contains($0) }
            var fileHits = wantsOverview ? attachmentIndex.firstChunks(3) : []
            for hit in attachmentIndex.search(searchQuery, limit: 3)
            where !fileHits.contains(where: { $0.text == hit.text }) {
                fileHits.append(hit)
            }
            if fileHits.isEmpty { fileHits = attachmentIndex.firstChunks(2) }
            fileHits = Array(fileHits.prefix(4))

            let names = conversation.sortedAttachments.map(\.name).joined(separator: ", ")
            parts.append("The user attached these files to this chat: \(names)")
            parts.append("Excerpts from the attached files:\n" + Self.format(fileHits))
            allHits += fileHits
            if isListQuestion { mayBeIncomplete = true }
        }

        // 2. Vault notes
        if useVault, let vault {
            let isProgressQuestion = Self.progressPhrases.contains { searchLower.contains($0) }
            let limit = attachmentIndex == nil ? 3 : 2
            var vaultHits: [NoteChunk] = []
            var wholeNoteName: String?

            // A note named in the question, or the best note for a list question
            var target = vault.noteNamed(in: searchQuery)
            if target == nil && isListQuestion {
                target = vault.bestNotesForList(searchQuery).first
            }

            if let target {
                var used = 0
                for chunk in vault.allChunks(ofNote: target) {
                    if used + chunk.text.count > Self.wholeNoteCharLimit {
                        mayBeIncomplete = true      // note was cut short to fit
                        break
                    }
                    vaultHits.append(chunk)
                    used += chunk.text.count
                }
                wholeNoteName = target
            } else {
                if isProgressQuestion { vaultHits = vault.latestNoteChunks(limit: 2) }
                for hit in vault.search(searchQuery, limit: limit)
                where !vaultHits.contains(where: { $0.text == hit.text }) {
                    vaultHits.append(hit)
                }
                if isListQuestion { mayBeIncomplete = true }
            }

            if !vaultDescription.isEmpty {
                parts.append("About the user's notes vault: \(vaultDescription)")
            }
            if isProgressQuestion || (attachmentIndex == nil && wholeNoteName == nil) {
                parts.append("Notes the user edited most recently (newest first):\n\(vault.recentNotesSummary())")
            }
            if !vaultHits.isEmpty {
                let header = wholeNoteName.map { "The note \"\($0)\" (in full unless noted):" }
                    ?? "Relevant note excerpts:"
                parts.append(header + "\n" + Self.format(vaultHits))
            }
            allHits += vaultHits
        }

        guard !parts.isEmpty else { return (question, []) }

        var rules = """
        Use the information above as your main source. You can draw reasonable conclusions from it. \
        If it truly doesn't help, answer from general knowledge and mention that briefly.
        """
        if mayBeIncomplete {
            rules += " You may not have the complete information. If the question asks for a full list or a count, say the list may be incomplete."
        } else if isListQuestion {
            rules += " You were given the complete note, so list every matching item from it."
        }

        parts.append("\(rules)\n\nQuestion: \(question)")

        let sources = Array(Set(allHits.map(\.fileName))).sorted()
        return (parts.joined(separator: "\n\n"), sources)
    }

    static func format(_ chunks: [NoteChunk]) -> String {
        chunks.map { "[From: \($0.fileName)]\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
    }

    // MARK: - Errors

    static func friendlyMessage(for error: LanguageModelError) -> String {
        switch error {
        case .refusal:
            return "The model declined to answer this one. Try rephrasing, or start a new chat."
        case .guardrailViolation:
            return "Apple's safety filter blocked this request, even if it was harmless. Try rephrasing."
        case .rateLimited:
            return "The model is busy right now. Wait a moment and try again."
        case .timeout:
            return "The model took too long to respond. Try again or ask something shorter."
        case .unsupportedLanguageOrLocale:
            return "The on-device model doesn't support that language."
        default:
            return "Error: \(error.localizedDescription)"
        }
    }

    static func markStopped(_ reply: ChatMessage) {
        reply.text = reply.text.isEmpty ? "_Stopped._" : reply.text + "\n\n_Stopped._"
    }

    // MARK: - Sending and stopping

    func send() {
        let question = draft.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !isResponding else { return }

        let previousQuestion = conversation.sortedMessages.last(where: { $0.isUser })?.text
        let (modelPrompt, sources) = buildPrompt(for: question, previousQuestion: previousQuestion)
        print("\n===== PROMPT SENT TO MODEL =====\n\(modelPrompt)\n================================")

        let next = (conversation.sortedMessages.last?.order ?? -1) + 1
        let userMessage = ChatMessage(order: next, isUser: true, text: question, sentText: modelPrompt)
        let reply = ChatMessage(order: next + 1, isUser: false, text: "", sources: sources)
        conversation.messages.append(userMessage)
        conversation.messages.append(reply)

        if conversation.title == "New Chat" {
            conversation.title = String(question.prefix(40))
        }
        conversation.updatedAt = .now

        draft = ""
        isResponding = true
        inputFocused = true

        responseTask = Task {
            do {
                try await stream(modelPrompt, into: reply)
            } catch let error as LanguageModelError {
                if case .contextSizeExceeded = error {
                    await restartWithRecentHistory(prompt: modelPrompt, question: userMessage, reply: reply)
                } else {
                    reply.text = Self.friendlyMessage(for: error)
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    Self.markStopped(reply)
                } else {
                    reply.text = "Error: \(error.localizedDescription)"
                }
            }
            isResponding = false
            responseTask = nil
            inputFocused = true
            await refreshTokenCount()
        }
    }

    func stop() {
        responseTask?.cancel()
    }

    func stream(_ prompt: String, into reply: ChatMessage) async throws {
        for try await partial in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            reply.text = partial.content
        }
    }

    func restartWithRecentHistory(prompt: String, question: ChatMessage, reply: ChatMessage) async {
        let earlier = Self.recentHistory(
            conversation.sortedMessages.filter { $0.order >= sessionStartOrder && $0.order < question.order }
        )
        instructionsText = Self.baseInstructions + "\n\nRecent conversation, for context:\n" + earlier
        session = LanguageModelSession(instructions: instructionsText)
        tokenCount = nil

        let notice = ChatMessage(order: question.order, isUser: false,
                                 text: "Memory was full, so I started fresh and kept your last few messages.",
                                 isNotice: true)
        question.order += 1
        reply.order += 1
        conversation.messages.append(notice)
        sessionStartOrder = question.order

        do {
            try await stream(prompt, into: reply)
        } catch let error as LanguageModelError {
            if case .contextSizeExceeded = error {
                reply.text = "That message is too long for the on-device model. Try a shorter one or start a new chat."
            } else {
                reply.text = Self.friendlyMessage(for: error)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                Self.markStopped(reply)
            } else {
                reply.text = "Error: \(error.localizedDescription)"
            }
        }
    }

    static func recentHistory(_ messages: [ChatMessage]) -> String {
        messages
            .filter { !$0.isNotice && !$0.text.isEmpty }
            .suffix(4)
            .map { ($0.isUser ? "User: " : "Assistant: ") + String($0.text.prefix(500)) }
            .joined(separator: "\n")
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        if message.isNotice {
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            HStack {
                if message.isUser { Spacer(minLength: 60) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.formatted(message.text.isEmpty ? "Thinking…" : message.text))
                        .textSelection(.enabled)

                    if !message.isUser && !message.text.isEmpty {
                        HStack(spacing: 10) {
                            if !message.sources.isEmpty {
                                Label(message.sources.joined(separator: ", "), systemImage: "doc.text")
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button(action: copy) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy reply")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(message.isUser ? .white : .primary)
                .glassEffect(message.isUser ? .regular.tint(.blue) : .regular,
                             in: .rect(cornerRadius: 18))
                if !message.isUser { Spacer(minLength: 60) }
            }
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    static func formatted(_ text: String) -> AttributedString {
        var t = text

        // Obsidian links: [[Note|Shown name]] -> Shown name, [[Note]] -> Note
        t = t.replacingOccurrences(of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)

        // Bullets at the start of a line: "- item" or "* item" -> "• item"
        t = t.replacingOccurrences(of: #"(?m)^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)

        // Headings: "## Title" -> bold
        t = t.replacingOccurrences(of: #"(?m)^#{1,6}\s+(.+)$"#, with: "**$1**", options: .regularExpression)

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: t, options: options)) ?? AttributedString(t)
    }
}

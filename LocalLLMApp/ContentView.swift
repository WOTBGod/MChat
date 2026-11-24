import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(VaultStore.self) private var vaultStore
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var selection: Conversation?
    @AppStorage("useVault") private var useVault = true

    @State private var searchText = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    var filteredConversations: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { convo in
            convo.title.localizedCaseInsensitiveContains(query) ||
            convo.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filteredConversations) { convo in
                    NavigationLink(value: convo) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(convo.title).lineLimit(1)
                            Text(convo.updatedAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Rename…") { startRenaming(convo) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(convo) }
                    }
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search chats")
            .overlay {
                if filteredConversations.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { newChat() } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                }
            }
        } detail: {
            Group {
                if let selection {
                    ChatView(conversation: selection, vault: vaultStore.vault, useVault: useVault)
                        .id(selection.id)
                } else {
                    ContentUnavailableView("No chat selected",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Start a new chat from the sidebar."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        if vaultStore.vault != nil {
                            Toggle("Use notes in answers", isOn: $useVault)
                        }
                        SettingsLink {
                            Text("Vault Settings…")
                        }
                    } label: {
                        Label(vaultLabel, systemImage: "books.vertical")
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .alert("Rename Chat", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $newTitle)
            Button("Save") { finishRenaming() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onAppear {
            if selection == nil {
                if let first = conversations.first { selection = first } else { newChat() }
            }
        }
        // Coming back to the app: pick up notes you edited in Obsidian
        .onChange(of: scenePhase) {
            if scenePhase == .active { vaultStore.refreshIfStale() }
        }
    }

    var vaultLabel: String {
        if vaultStore.isIndexing {
            return vaultStore.progressTotal > 0
                ? "Indexing \(vaultStore.progressDone)/\(vaultStore.progressTotal)…"
                : "Indexing…"
        }
        guard let vault = vaultStore.vault else { return "No vault" }
        return useVault ? "\(vaultStore.folderName) · \(vault.notes.count) notes" : "\(vaultStore.folderName) (off)"
    }

    // MARK: - Actions

    func newChat() {
        searchText = ""
        if let current = selection, current.messages.isEmpty { return }
        let convo = Conversation()
        context.insert(convo)
        selection = convo
    }

    func delete(_ convo: Conversation) {
        if selection == convo { selection = nil }
        context.delete(convo)
    }

    func startRenaming(_ convo: Conversation) {
        newTitle = convo.title
        renaming = convo
    }

    func finishRenaming() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        if let convo = renaming, !title.isEmpty {
            convo.title = title
        }
        renaming = nil
    }
}

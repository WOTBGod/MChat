import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(VaultStore.self) private var vaultStore
    @AppStorage("vaultDescription") private var vaultDescription = ""
    @AppStorage("useVault") private var useVault = true
    @State private var showPicker = false

    var body: some View {
        Form {
            Section("Knowledge source") {
                if vaultStore.isIndexing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(vaultStore.progressDone),
                                     total: Double(max(vaultStore.progressTotal, 1)))
                        Text(vaultStore.progressTotal == 0
                             ? "Scanning \(vaultStore.folderName)…"
                             : "Checking \(vaultStore.progressDone) of \(vaultStore.progressTotal) notes…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let vault = vaultStore.vault {
                    LabeledContent("Vault", value: vaultStore.folderName)
                    LabeledContent("Contents", value: "\(vault.notes.count) notes · \(vault.chunks.count) chunks")
                    if let date = vaultStore.lastIndexed {
                        LabeledContent("Last checked",
                                       value: date.formatted(date: .omitted, time: .shortened))
                    }
                    if !vaultStore.lastRunSummary.isEmpty {
                        LabeledContent("Last run", value: vaultStore.lastRunSummary)
                    }
                    HStack {
                        Button("Change…") { showPicker = true }
                        Button("Re-index") { vaultStore.reload() }
                            .help("Pick up new or edited notes")
                        Button("Rebuild") { vaultStore.rebuildFromScratch() }
                            .help("Throw away the saved index and re-embed everything")
                        Spacer()
                        Button("Remove", role: .destructive) { vaultStore.remove() }
                    }
                    .disabled(vaultStore.isIndexing)
                } else if !vaultStore.isIndexing {
                    Text("No vault connected. Add a folder of notes (Obsidian or plain text) to use them in answers.")
                        .foregroundStyle(.secondary)
                    Button("Choose Vault…") { showPicker = true }
                }

                if let error = vaultStore.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Using your notes") {
                Toggle("Use notes in answers", isOn: $useVault)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Vault description")
                    TextEditor(text: $vaultDescription)
                        .font(.body)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    Text("Tell the model what these notes are, e.g. \"My investment banking technical prep: accounting and DCF notes, plus dated drill logs.\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                vaultStore.choose(url)
            }
        }
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class VaultStore {
    private(set) var vault: VaultSearch?
    private(set) var folderName = ""
    private(set) var lastIndexed: Date?
    private(set) var isIndexing = false
    private(set) var progressDone = 0
    private(set) var progressTotal = 0
    private(set) var lastRunSummary = ""
    var errorMessage: String?

    private let bookmarkKey = "vaultBookmark"

    init() {
        restore()
    }

    /// User picked a folder: remember it, then index it
    func choose(_ url: URL) {
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't remember this folder: \(error.localizedDescription)"
        }
        VaultIndexer.clearCache()
        load(url)
    }

    /// Check for new or edited notes (fast: unchanged notes come from the cache)
    func reload() {
        restore()
    }

    /// Called when you switch back to the app, at most every 30 seconds
    func refreshIfStale() {
        guard !isIndexing, let last = lastIndexed, Date.now.timeIntervalSince(last) > 30 else { return }
        restore()
    }

    /// Throw away the saved index and re-embed everything
    func rebuildFromScratch() {
        VaultIndexer.clearCache()
        restore()
    }

    func remove() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        VaultIndexer.clearCache()
        vault = nil
        folderName = ""
        lastIndexed = nil
        lastRunSummary = ""
        errorMessage = nil
    }

    // MARK: - Private

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)

            if isStale {
                let allowed = url.startAccessingSecurityScopedResource()
                if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                }
                if allowed { url.stopAccessingSecurityScopedResource() }
            }
            load(url)
        } catch {
            errorMessage = "Couldn't reopen your vault. Choose it again in Settings."
        }
    }

    private func load(_ url: URL) {
        guard !isIndexing else { return }
        isIndexing = true
        progressDone = 0
        progressTotal = 0
        folderName = url.lastPathComponent

        let allowed = url.startAccessingSecurityScopedResource()

        Task {
            // Do the slow work off the main thread so the app stays responsive
            let result = await Task.detached(priority: .userInitiated) {
                VaultIndexer.build(folder: url) { done, total in
                    Task { @MainActor in
                        self.progressDone = done
                        self.progressTotal = total
                    }
                }
            }.value

            if allowed { url.stopAccessingSecurityScopedResource() }

            vault = result.search
            lastIndexed = .now
            lastRunSummary = "\(result.indexed) indexed · \(result.reused) unchanged"
                + (result.removed > 0 ? " · \(result.removed) removed" : "")
            isIndexing = false
        }
    }
}

import Foundation

nonisolated enum VaultIndexer {

    /// Files that are instructions for AI tools, not the user's notes
    static let skippedFiles: Set<String> = ["claude.md", "agents.md"]

    nonisolated struct CachedFile: Codable, Sendable {
        let name: String
        let modified: Date
        let size: Int
        let chunks: [NoteChunk]
    }

    nonisolated struct Cache: Codable, Sendable {
        var folderPath: String
        var files: [String: CachedFile]
    }

    nonisolated struct Result: Sendable {
        let search: VaultSearch
        let indexed: Int
        let reused: Int
        let removed: Int
    }

    static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultIndex.plist")
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    static func build(folder: URL, progress: @Sendable (Int, Int) -> Void) -> Result {
        let old = loadCache(folderPath: folder.path)

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var found: [(url: URL, key: String, modified: Date, size: Int)] = []
        if let files = FileManager.default.enumerator(at: folder,
                                                      includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) {
            for case let url as URL in files
            where ["md", "txt"].contains(url.pathExtension.lowercased())
               && !skippedFiles.contains(url.lastPathComponent.lowercased()) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let key = String(url.path.dropFirst(folder.path.count))
                found.append((url, key,
                              values?.contentModificationDate ?? .distantPast,
                              values?.fileSize ?? 0))
            }
        }

        let embedding = VaultSearch.makeEmbedding()
        var newFiles: [String: CachedFile] = [:]
        var indexed = 0, reused = 0

        for (i, file) in found.enumerated() {
            if let cached = old?.files[file.key],
               cached.size == file.size,
               abs(cached.modified.timeIntervalSince(file.modified)) < 1 {
                newFiles[file.key] = cached
                reused += 1
            } else if let content = try? String(contentsOf: file.url, encoding: .utf8) {
                let name = file.url.deletingPathExtension().lastPathComponent
                let chunks = VaultSearch.split(content).map { piece in
                    NoteChunk(fileName: name, text: piece,
                              vector: VaultSearch.vector(for: name + ". " + piece, using: embedding))
                }
                newFiles[file.key] = CachedFile(name: name, modified: file.modified,
                                                size: file.size, chunks: chunks)
                indexed += 1
            }

            if i % 25 == 0 || i == found.count - 1 {
                progress(i + 1, found.count)
            }
        }

        let removed = old.map { $0.files.keys.filter { newFiles[$0] == nil }.count } ?? 0
        if indexed > 0 || removed > 0 || old == nil {
            saveCache(Cache(folderPath: folder.path, files: newFiles))
        }

        let ordered = newFiles.keys.sorted().compactMap { newFiles[$0] }
        let search = VaultSearch(
            chunks: ordered.flatMap(\.chunks),
            notes: ordered.map { NoteInfo(name: $0.name, modified: $0.modified) }
        )
        return Result(search: search, indexed: indexed, reused: reused, removed: removed)
    }

    private static func loadCache(folderPath: String) -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
              cache.folderPath == folderPath
        else { return nil }
        return cache
    }

    private static func saveCache(_ cache: Cache) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

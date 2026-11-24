import Foundation
import NaturalLanguage
import Accelerate

// One searchable piece of a note. Codable so it can be saved to disk.
nonisolated struct NoteChunk: Sendable, Codable {
    let fileName: String
    let text: String
    let vector: [Float]?          // meaning-vector, scaled to length 1 so similarity = dot product

    init(fileName: String, text: String, vector: [Float]?) {
        self.fileName = fileName
        self.text = text
        self.vector = vector
    }

    // Save vectors as raw bytes (much smaller and faster than a list of numbers)
    enum CodingKeys: String, CodingKey { case fileName, text, vector }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        text = try c.decode(String.self, forKey: .text)
        if let data = try c.decodeIfPresent(Data.self, forKey: .vector) {
            vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else {
            vector = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(text, forKey: .text)
        if let vector {
            try c.encode(vector.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .vector)
        }
    }
}

nonisolated struct NoteInfo: Sendable, Codable {
    let name: String
    let modified: Date
}

nonisolated struct VaultSearch: Sendable {
    private(set) var chunks: [NoteChunk] = []
    private(set) var notes: [NoteInfo] = []
    private var wordCounts: [[String: Int]] = []   // per chunk: word -> how many times it appears
    private var docFreq: [String: Int] = [:]       // word -> how many chunks contain it

    static let stopWords: Set<String> = [
        "the", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "were",
        "what", "how", "why", "when", "which", "who", "does", "do", "did", "it", "this",
        "that", "with", "as", "by", "be", "at", "from", "me", "my", "you", "your", "can",
        "about", "explain", "tell", "an"
    ]

    // MARK: - Building

    /// Build from chunks that are already embedded (from the indexer or the saved cache)
    init(chunks: [NoteChunk], notes: [NoteInfo]) {
        self.chunks = chunks
        self.notes = notes
        wordCounts = chunks.map { chunk in
            var counts: [String: Int] = [:]
            for w in Self.words(in: chunk.fileName + " " + chunk.text) { counts[w, default: 0] += 1 }
            return counts
        }
        for counts in wordCounts {
            for w in counts.keys { docFreq[w, default: 0] += 1 }
        }
    }

    /// Build from attached files in a chat
    init(documents: [(name: String, text: String)]) {
        let embedding = Self.makeEmbedding()
        var chunks: [NoteChunk] = []
        var notes: [NoteInfo] = []
        for doc in documents {
            notes.append(NoteInfo(name: doc.name, modified: .now))
            for piece in Self.chunk(doc.text) {
                chunks.append(NoteChunk(fileName: doc.name, text: piece,
                                        vector: Self.vector(for: piece, using: embedding)))
            }
        }
        self.init(chunks: chunks, notes: notes)
    }

    // MARK: - Text helpers

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
    }

    /// Split a note into chunks, starting a new one at each heading
    static func split(_ text: String, maxChars: Int = 1000) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if !current.isEmpty && (current.count + p.count > maxChars || p.hasPrefix("#")) {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + p
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Split by line and size (PDFs often have no blank lines)
    static func chunk(_ text: String, size: Int = 1000) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            while line.count > size {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(String(line.prefix(size)))
                line = String(line.dropFirst(size))
            }
            if current.count + line.count > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Embeddings

    static func makeEmbedding() -> NLEmbedding? {
        NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// Meaning-vector for some text, scaled to length 1
    static func vector(for text: String, using embedding: NLEmbedding?) -> [Float]? {
        guard let embedding, let raw = embedding.vector(for: text) else { return nil }
        let v = raw.map { Float($0) }
        let length = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return nil }
        return v.map { $0 / length }
    }

    // MARK: - Search

    func search(_ query: String, limit: Int = 3, keywordWeight: Double = 0.4) -> [NoteChunk] {
        guard !chunks.isEmpty else { return [] }

        // 1. Keyword scores (TF-IDF), using the pre-computed counts
        let queryWords = Set(Self.words(in: query))
        let total = Double(chunks.count)
        var keyword = [Double](repeating: 0, count: chunks.count)
        if !queryWords.isEmpty {
            for i in chunks.indices {
                var score = 0.0
                for w in queryWords {
                    guard let hits = wordCounts[i][w], let df = docFreq[w] else { continue }
                    score += (1 + log(Double(hits))) * log(1 + total / Double(df))
                }
                keyword[i] = score
            }
        }
        let maxKeyword = keyword.max() ?? 0

        // 2. Meaning scores: dot product of unit vectors = cosine similarity
        let queryVector = Self.vector(for: query, using: Self.makeEmbedding())

        var scored: [(index: Int, score: Double, kw: Double, sem: Double)] = []
        scored.reserveCapacity(chunks.count)
        for i in chunks.indices {
            let kw = maxKeyword > 0 ? keyword[i] / maxKeyword : 0
            var sem = 0.0
            if let q = queryVector, let v = chunks[i].vector, q.count == v.count {
                sem = max(0, Double(vDSP.dot(q, v)))
            }
            let score = queryVector == nil ? kw : keywordWeight * kw + (1 - keywordWeight) * sem
            scored.append((i, score, kw, sem))
        }

        let top = scored
            .filter { $0.kw > 0 || $0.sem > 0.5 }
            .sorted { $0.score > $1.score }
            .prefix(limit)

        print("\n🔎 \(query)")
        for r in top {
            print(String(format: "  %.2f  (keyword %.2f, meaning %.2f)  %@",
                         r.score, r.kw, r.sem, chunks[r.index].fileName))
        }

        return top.map { chunks[$0.index] }
    }

    // MARK: - Recency and overview

    func recentNotesSummary(limit: Int = 10) -> String {
        notes.sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { "- \($0.name) (edited \($0.modified.formatted(date: .abbreviated, time: .omitted)))" }
            .joined(separator: "\n")
    }

    func latestNoteChunks(limit: Int = 2) -> [NoteChunk] {
        guard let newest = notes.max(by: { $0.modified < $1.modified }) else { return [] }
        return Array(chunks.filter { $0.fileName == newest.name }.prefix(limit))
    }

    func firstChunks(_ n: Int) -> [NoteChunk] {
        Array(chunks.prefix(n))
    }
}

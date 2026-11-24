import Foundation

nonisolated extension VaultSearch {
    /// Title words that usually mean "this note is a summary of many things"
    static let summaryTitleWords: Set<String> = [
        "log", "index", "list", "tracker", "summary", "overview", "map",
        "progress", "dashboard", "master", "table"
    ]

    /// Words that describe what the user wants done, not the topic.
    /// Ignored when matching note titles (so "list" doesn't match "Linked List").
    static let requestWords: Set<String> = [
        "list", "all", "every", "everything", "show", "give", "count", "total",
        "many", "retype", "same", "again", "repeat", "full", "whole", "complete",
        "please", "okay", "ok", "then", "them", "ones", "have", "ive", "i've"
    ]

    /// Topic words of a question, without request words
    static func topicWords(in text: String) -> Set<String> {
        Set(words(in: text)).subtracting(requestWords)
    }

    /// Every chunk of one note, in order (the whole note)
    func allChunks(ofNote name: String) -> [NoteChunk] {
        chunks.filter { $0.fileName == name }
    }

    /// A note the question names outright, e.g. "my leetcode log" -> "LeetCode Log"
    func noteNamed(in query: String) -> String? {
        let queryWords = Set(Self.words(in: query))
        let lowerQuery = query.lowercased()
        let names = Set(chunks.map(\.fileName))

        let matches = names.filter { name in
            let titleWords = Set(Self.words(in: name))
            guard !titleWords.isEmpty else { return false }
            return (titleWords.count >= 2 && titleWords.isSubset(of: queryWords))
                || (name.count >= 6 && lowerQuery.contains(name.lowercased()))
        }
        return matches.max { Self.words(in: $0).count < Self.words(in: $1).count }
    }

    /// Best whole notes for a "list everything" question, best first
    func bestNotesForList(_ query: String, limit: Int = 3) -> [String] {
        let topic = Self.topicWords(in: query)
        guard !topic.isEmpty else { return [] }
        let topicQuery = topic.joined(separator: " ")
        var scores: [String: Double] = [:]

        for name in Set(chunks.map(\.fileName)) {
            let titleWords = Set(Self.words(in: name))
            let overlap = titleWords.intersection(topic).count
            guard overlap > 0 else { continue }
            scores[name, default: 0] += 3 * Double(overlap)
            // Summary notes are what list questions usually want
            if !titleWords.isDisjoint(with: Self.summaryTitleWords) {
                scores[name, default: 0] += 3
            }
        }

        // Notes with strong search hits on the topic words
        for hit in search(topicQuery, limit: 10) {
            scores[hit.fileName, default: 0] += 1
        }

        return scores
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}

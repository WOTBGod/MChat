import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers

// Pulls plain text out of PDFs, Word docs, and text files
enum DocumentReader {
    static let supportedTypes: [UTType] =
        [.pdf, .plainText, .rtf] +
        ["md", "markdown", "docx", "doc", "csv"].compactMap { UTType(filenameExtension: $0) }

    enum ReadError: LocalizedError {
        case unsupported(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "\(name) isn't a supported file type (PDF, Word, text, Markdown)."
            case .empty(let name):
                return "Couldn't find any text in \(name). If it's a scanned PDF, it has no text layer."
            }
        }
    }

    static func text(from url: URL) throws -> String {
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw ReadError.unsupported(url.lastPathComponent) }
            text = pdf.string ?? ""
        case "docx", "doc", "rtf", "rtfd":
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        case "txt", "md", "markdown", "csv", "json":
            text = try String(contentsOf: url, encoding: .utf8)
        default:
            throw ReadError.unsupported(url.lastPathComponent)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReadError.empty(url.lastPathComponent) }
        return trimmed
    }
}

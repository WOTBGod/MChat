import Foundation
import SwiftData

@Model
final class Conversation {
    var title: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []
    @Relationship(deleteRule: .cascade, inverse: \Attachment.conversation)
    var attachments: [Attachment] = []

    init(title: String = "New Chat") {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.order < $1.order }
    }

    var sortedAttachments: [Attachment] {
        attachments.sorted { $0.addedAt < $1.addedAt }
    }
}

@Model
final class ChatMessage {
    var order: Int
    var isUser: Bool
    var text: String
    var isNotice: Bool
    var sentText: String?
    var sources: [String]
    var conversation: Conversation?

    init(order: Int, isUser: Bool, text: String, isNotice: Bool = false,
         sentText: String? = nil, sources: [String] = []) {
        self.order = order
        self.isUser = isUser
        self.text = text
        self.isNotice = isNotice
        self.sentText = sentText
        self.sources = sources
    }
}

// A file attached to a chat: we keep its extracted text, not the file itself
@Model
final class Attachment {
    var name: String
    var text: String
    var addedAt: Date
    var conversation: Conversation?

    init(name: String, text: String) {
        self.name = name
        self.text = text
        self.addedAt = .now
    }
}

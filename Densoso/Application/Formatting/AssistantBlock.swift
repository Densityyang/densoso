import Foundation

enum AssistantBlock: Codable, Equatable, Sendable {
    case paragraph(String)
    case list(items: [String], ordered: Bool)
    case status(title: String, detail: String)
    case link(label: String, url: URL)
}

struct AssistantDocument: Codable, Equatable, Sendable {
    let blocks: [AssistantBlock]
    let usedPlainTextFallback: Bool
}

import Foundation

enum RestrictedMarkdownRenderer {
    static func parse(_ source: String) -> AssistantDocument {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard !containsForbiddenMarkup(normalized), hasBalancedInlineMarkers(normalized) else {
            return fallback(normalized)
        }
        let sanitized = sanitizeLinks(normalized)
        var blocks: [AssistantBlock] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var listOrdered: Bool?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }

        func flushList() {
            guard !listItems.isEmpty, let ordered = listOrdered else { return }
            blocks.append(.list(items: listItems, ordered: ordered))
            listItems.removeAll()
            listOrdered = nil
        }

        for line in sanitized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushList()
                continue
            }
            if let item = unorderedListItem(line) {
                flushParagraph()
                if listOrdered == true { flushList() }
                listOrdered = false
                listItems.append(item)
            } else if let item = orderedListItem(line) {
                flushParagraph()
                if listOrdered == false { flushList() }
                listOrdered = true
                listItems.append(item)
            } else {
                flushList()
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        flushList()
        guard !blocks.isEmpty else { return fallback(normalized) }
        return AssistantDocument(blocks: blocks, usedPlainTextFallback: false)
    }

    static func plainText(_ source: String) -> String {
        var text = source
        text = replacing(pattern: #"!\[([^\]]*)\]\([^\)]*\)"#, in: text, template: "$1")
        text = replacing(pattern: #"\[([^\]]+)\]\([^\)]*\)"#, in: text, template: "$1")
        text = replacing(pattern: #"<[^>]+>"#, in: text, template: "")
        for marker in ["**", "__", "*", "_", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallback(_ source: String) -> AssistantDocument {
        AssistantDocument(
            blocks: [.paragraph(plainText(source))],
            usedPlainTextFallback: true
        )
    }

    private static func containsForbiddenMarkup(_ source: String) -> Bool {
        source.range(of: #"<[^>]+>"#, options: .regularExpression) != nil
            || source.range(of: #"!\[[^\]]*\]\([^\)]*\)"#, options: .regularExpression) != nil
    }

    private static func hasBalancedInlineMarkers(_ source: String) -> Bool {
        let inlineOnly = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let leadingTrimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                guard leadingTrimmed.hasPrefix("* ") else { return line }
                return leadingTrimmed.dropFirst(2)
            }
            .joined(separator: "\n")
        let emphasisOnly = replacing(
            pattern: #"(?<=[\p{L}\p{N}])_(?=[\p{L}\p{N}])"#,
            in: inlineOnly,
            template: ""
        )
        return emphasisOnly.components(separatedBy: "**").count.isMultiple(of: 2) == false
            && emphasisOnly.filter { $0 == "*" }.count.isMultiple(of: 2)
            && emphasisOnly.filter { $0 == "_" }.count.isMultiple(of: 2)
            && emphasisOnly.filter { $0 == "`" }.count.isMultiple(of: 2)
    }

    private static func sanitizeLinks(_ source: String) -> String {
        let pattern = #"\[([^\]]+)\]\(([^\)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var result = source
        for match in regex.matches(in: source, range: range).reversed() {
            guard let whole = Range(match.range(at: 0), in: source),
                  let labelRange = Range(match.range(at: 1), in: source),
                  let urlRange = Range(match.range(at: 2), in: source) else { continue }
            let label = String(source[labelRange])
            let rawURL = String(source[urlRange])
            let replacement: String
            if let url = URL(string: rawURL), url.scheme?.lowercased() == "https" {
                replacement = "[\(label)](\(url.absoluteString))"
            } else {
                replacement = label
            }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    private static func unorderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* "] where trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dot = trimmed.firstIndex(of: "."),
              trimmed.index(after: dot) < trimmed.endIndex,
              trimmed[trimmed.index(after: dot)] == " ",
              !trimmed[..<dot].isEmpty,
              trimmed[..<dot].allSatisfy(\.isNumber) else { return nil }
        return String(trimmed[trimmed.index(dot, offsetBy: 2)...])
    }

    private static func replacing(
        pattern: String,
        in source: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source),
            withTemplate: template
        )
    }
}

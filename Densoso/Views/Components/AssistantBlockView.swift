import SwiftUI

struct AssistantBlockView: View {
    let document: AssistantDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let markdown):
                    inlineText(markdown)
                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(index + 1)." : "•")
                                    .foregroundStyle(.secondary)
                                inlineText(item)
                            }
                        }
                    }
                case .status(let title, let detail):
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                case .link(let label, let url):
                    Link(label, destination: url)
                }
            }
        }
    }

    private func inlineText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(RestrictedMarkdownRenderer.plainText(markdown))
    }
}

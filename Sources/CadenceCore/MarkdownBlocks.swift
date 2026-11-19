import Foundation

/// A small block-level Markdown parser. SwiftUI's `AttributedString(markdown:)` handles inline styling
/// (bold, italic, code, links) but draws headings and lists as plain runs, so blocks are split here and
/// each block's text is styled inline by the view.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case quote(String)
    case code(language: String?, text: String)
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    public var text: String
    /// Nesting depth, 0 = top level.
    public var depth: Int
    /// The number for ordered lists, nil for bullets.
    public var ordinal: Int?
    /// `- [ ]` / `- [x]` items: whether ticked. nil for ordinary items.
    public var task: Bool?

    public init(text: String, depth: Int = 0, ordinal: Int? = nil, task: Bool? = nil) {
        self.text = text; self.depth = depth; self.ordinal = ordinal; self.task = task
    }
}

public enum MarkdownBlocks {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [MarkdownListItem] = []
        var fence: (lang: String?, lines: [String])?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
        }
        func flushAll() { flushParagraph(); flushQuote(); flushList() }

        for rawLine in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var f = fence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: f.lang, text: f.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    f.lines.append(line)
                    fence = f
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (lang.isEmpty ? nil : lang, [])
                continue
            }
            if trimmed.isEmpty { flushAll(); continue }

            if let (level, text) = heading(trimmed) {
                flushAll()
                blocks.append(.heading(level: level, text: text))
                continue
            }
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flushParagraph(); flushQuote()
                items.append(item)
                continue
            }
            // A continuation line of a list item.
            if !items.isEmpty, line.hasPrefix("  ") {
                items[items.count - 1].text += " " + trimmed
                continue
            }
            flushQuote(); flushList()
            paragraph.append(trimmed)
        }
        if let f = fence { blocks.append(.code(language: f.lang, text: f.lines.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func heading(_ s: String) -> (Int, String)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return (min(3, hashes), text)
    }

    private static func isRule(_ s: String) -> Bool {
        let chars = s.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " }.count
        let s = line.dropFirst(indent)
        var text: Substring
        var ordinal: Int?
        if let m = s.first, "-*+".contains(m), s.dropFirst().first == " " {
            text = s.dropFirst(2)
        } else {
            let digits = s.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let after = s.dropFirst(digits.count)
            guard let p = after.first, p == "." || p == ")", after.dropFirst().first == " " else { return nil }
            ordinal = Int(digits)
            text = after.dropFirst(2)
        }
        var task: Bool?
        let lower = text.lowercased()
        if lower.hasPrefix("[ ] ") || lower.hasPrefix("[x] ") {
            task = lower.hasPrefix("[x]")
            text = text.dropFirst(4)
        }
        return MarkdownListItem(text: text.trimmingCharacters(in: .whitespaces), depth: min(3, indent / 2), ordinal: ordinal, task: task)
    }
}

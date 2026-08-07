import Foundation

/// Blocks a rendered topic or reply body is broken into for display.
enum ContentBlock: Identifiable, Hashable {
    case paragraph(AttributedString)
    case code(String)
    case quote(AttributedString)
    case list([AttributedString])
    case image(URL)
    case rule

    var id: String {
        switch self {
        case .paragraph(let s): return "p:\(s.description.hashValue)"
        case .code(let s): return "c:\(s.hashValue)"
        case .quote(let s): return "q:\(s.description.hashValue)"
        case .list(let items): return "l:\(items.map(\.description).joined().hashValue)"
        case .image(let url): return "i:\(url.absoluteString)"
        case .rule: return "hr"
        }
    }
}

/// Small purpose-built HTML reader for the subset V2EX emits: `<p> <br> <a>
/// <code> <pre> <blockquote> <img> <ul>/<ol>/<li> <strong> <em>`. Purpose-built
/// rather than `NSAttributedString(documentType: .html)` because that variant
/// is main-thread-only and far too slow for a 250-reply topic.
enum HTMLText {

    // MARK: Public entry points

    /// Full block-level parse for topic bodies and long replies.
    static func blocks(from html: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var scanner = Scanner(source: html)
        var pending = ""

        func flushParagraph() {
            let attributed = inline(pending)
            if !attributed.characters.isEmpty {
                blocks.append(.paragraph(attributed))
            }
            pending = ""
        }

        /// A `<p>` may contain `<img>` runs — V2EX renders images inside
        /// paragraphs. Pull each image out as its own block; the inline pass
        /// would otherwise collapse them into "[图片]" links.
        func appendParagraph(_ html: String) {
            var text = ""
            var innerScanner = Scanner(source: html)
            func flush() {
                let attributed = inline(text)
                if !attributed.characters.isEmpty { blocks.append(.paragraph(attributed)) }
                text = ""
            }
            while let chunk = innerScanner.next() {
                switch chunk {
                case .text(let t):
                    text += t
                case .element(let name, let attributes, let inner):
                    switch name {
                    case "img":
                        if let src = attributes["src"], let url = absoluteURL(src) {
                            flush()
                            blocks.append(.image(url))
                        }
                    case "br":
                        text += "\n"
                    case "a" where inner.contains("<img"):
                        // Linked image: promote it, drop the "[图片]" text.
                        if let src = imageSource(in: inner), let url = absoluteURL(src) {
                            flush()
                            blocks.append(.image(url))
                        } else {
                            text += reassemble(name: name, attributes: attributes, inner: inner)
                        }
                    default:
                        text += reassemble(name: name, attributes: attributes, inner: inner)
                    }
                }
            }
            flush()
        }

        while let chunk = scanner.next() {
            switch chunk {
            case .text(let text):
                pending += text
            case .element(let name, let attributes, let inner):
                switch name {
                case "p":
                    flushParagraph()
                    appendParagraph(inner)
                case "pre":
                    flushParagraph()
                    blocks.append(.code(decode(strip(inner)).trimmingCharacters(in: .newlines)))
                case "code" where inner.contains("\n"):
                    // A bare multi-line <code> is a fenced block on V2EX.
                    flushParagraph()
                    blocks.append(.code(decode(strip(inner)).trimmingCharacters(in: .newlines)))
                case "blockquote":
                    flushParagraph()
                    blocks.append(contentsOf: quoteBlocks(from: inner))
                case "ul", "ol":
                    flushParagraph()
                    let items = listItems(in: inner)
                    if !items.isEmpty { blocks.append(.list(items)) }
                case "img":
                    flushParagraph()
                    if let src = attributes["src"], let url = absoluteURL(src) {
                        blocks.append(.image(url))
                    }
                case "hr":
                    flushParagraph()
                    blocks.append(.rule)
                case "a" where inner.contains("<img"):
                    // Linked image outside a <p> — promote it instead of letting
                    // the inline pass collapse it into a "[图片]" link.
                    flushParagraph()
                    if let src = imageSource(in: inner), let url = absoluteURL(src) {
                        blocks.append(.image(url))
                    } else {
                        pending += reassemble(name: name, attributes: attributes, inner: inner)
                    }
                case "br":
                    pending += "\n"
                default:
                    // Inline-level tag encountered outside a paragraph: keep it
                    // in the running buffer so its formatting survives.
                    pending += reassemble(name: name, attributes: attributes, inner: inner)
                }
            }
        }
        flushParagraph()
        return blocks
    }

    /// Quote blocks keep their text but promote any images out of the inline
    /// pass (which would otherwise collapse `<img>` into a "[图片]" link).
    private static func quoteBlocks(from html: String) -> [ContentBlock] {
        var text = ""
        var result: [ContentBlock] = []
        var scanner = Scanner(source: html)

        func flush() {
            let attributed = inline(text)
            if !attributed.characters.isEmpty { result.append(.quote(attributed)) }
            text = ""
        }

        while let chunk = scanner.next() {
            switch chunk {
            case .text(let t):
                text += t
            case .element(let name, let attributes, let inner):
                switch name {
                case "img":
                    if let src = attributes["src"], let url = absoluteURL(src) {
                        flush()
                        result.append(.image(url))
                    }
                case "a" where inner.contains("<img"):
                    if let src = imageSource(in: inner), let url = absoluteURL(src) {
                        flush()
                        result.append(.image(url))
                    } else {
                        text += reassemble(name: name, attributes: attributes, inner: inner)
                    }
                default:
                    text += reassemble(name: name, attributes: attributes, inner: inner)
                }
            }
        }
        flush()
        return result
    }

    /// Inline-only parse: bold/italic/code/link runs, no block structure.
    /// Used for reply bodies and notification payloads.
    static func inline(_ html: String) -> AttributedString {
        var result = AttributedString()
        var scanner = Scanner(source: html)

        while let chunk = scanner.next() {
            switch chunk {
            case .text(let text):
                result += AttributedString(decode(text))
            case .element(let name, let attributes, let inner):
                var piece = inline(inner)
                switch name {
                case "strong", "b":
                    piece.inlinePresentationIntent = .stronglyEmphasized
                case "em", "i":
                    piece.inlinePresentationIntent = .emphasized
                case "code":
                    piece.inlinePresentationIntent = .code
                case "a":
                    if let url = linkTarget(href: attributes["href"], label: piece) {
                        piece.link = url
                    }
                case "br":
                    piece = AttributedString("\n")
                case "img":
                    if let src = attributes["src"], let url = absoluteURL(src) {
                        piece = AttributedString("[图片]")
                        piece.link = url
                    }
                default:
                    break
                }
                result += piece
            }
        }
        return trimmed(result)
    }

    /// Tags removed, entities decoded — for previews, search and notifications.
    static func plain(_ html: String) -> String {
        decode(strip(html))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text of the first `<a>` whose href contains `matching` (used to pull the
    /// topic title out of a notification string).
    static func firstLinkText(in html: String, matching: String) -> String? {
        var scanner = Scanner(source: html)
        while let chunk = scanner.next() {
            if case .element(let name, let attributes, let inner) = chunk,
               name == "a", attributes["href"]?.contains(matching) == true {
                return plain(inner)
            }
        }
        return nil
    }

    static func firstTopicID(in html: String) -> Int? {
        var scanner = Scanner(source: html)
        while let chunk = scanner.next() {
            if case .element(let name, let attributes, _) = chunk,
               name == "a", let href = attributes["href"], href.contains("/t/") {
                let digits = href.drop { $0 != "/" }
                    .split(separator: "/")
                    .compactMap { Int($0.prefix { $0.isNumber }) }
                return digits.first
            }
        }
        return nil
    }

    // MARK: Internals

    private static func listItems(in html: String) -> [AttributedString] {
        var items: [AttributedString] = []
        var scanner = Scanner(source: html)
        while let chunk = scanner.next() {
            if case .element(let name, _, let inner) = chunk, name == "li" {
                let attributed = inline(inner)
                if !attributed.characters.isEmpty { items.append(attributed) }
            }
        }
        return items
    }

    private static func reassemble(name: String, attributes: [String: String], inner: String) -> String {
        let attrs = attributes.map { " \($0.key)=\"\($0.value)\"" }.joined()
        return "<\(name)\(attrs)>\(inner)</\(name)>"
    }

    private static func trimmed(_ value: AttributedString) -> AttributedString {
        var result = value
        while let first = result.characters.first, first.isWhitespace {
            result.removeSubrange(result.startIndex..<result.index(afterCharacter: result.startIndex))
        }
        while let last = result.characters.last, last.isWhitespace {
            let end = result.endIndex
            result.removeSubrange(result.index(beforeCharacter: end)..<end)
        }
        return result
    }

    /// First `<img>` src inside a fragment — for linked-image paragraphs.
    static func imageSource(in html: String) -> String? {
        guard let match = html.range(
            of: #"<img[^>]*src\s*=\s*"([^"]+)""#,
            options: .regularExpression
        ) else { return nil }
        let fragment = String(html[match])
        guard let value = fragment.range(
            of: #"src\s*=\s*"[^"]+""#,
            options: .regularExpression
        ) else { return nil }
        return String(fragment[value])
            .replacingOccurrences(of: "src=\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// An anchor's destination, falling back to its own label when the `href`
    /// is unusable.
    ///
    /// The markdown `[https://example.com]()` — URL in the label slot, target
    /// left empty — is a common enough slip that V2EX renders it verbatim as
    /// `<a href="">https://example.com</a>`. That leaves a full URL sitting on
    /// screen with nothing behind it. The fallback insists on an http(s) URL
    /// with a host so an ordinary text label like "点这里" stays plain text
    /// rather than becoming a link to nowhere.
    static func linkTarget(href: String?, label: AttributedString) -> URL? {
        if let href, let url = absoluteURL(href) { return url }

        let text = String(label.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    static func absoluteURL(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        else if value.hasPrefix("/") { value = "https://www.v2ex.com" + value }
        return URL(string: value)
    }

    static func strip(_ html: String) -> String {
        var output = ""
        var insideTag = false
        for character in html {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { output.append(character) }
            }
        }
        return output
    }

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = text
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&hellip;": "…",
            "&mdash;": "—", "&ndash;": "–", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities.
        while let range = output.range(of: "&#[0-9]+;", options: .regularExpression) {
            let digits = output[range].dropFirst(2).dropLast()
            guard let value = UInt32(digits), let scalar = Unicode.Scalar(value) else {
                output.replaceSubrange(range, with: "")
                continue
            }
            output.replaceSubrange(range, with: String(Character(scalar)))
        }
        return output
    }

    // MARK: Tokenizer

    private enum Chunk {
        case text(String)
        case element(name: String, attributes: [String: String], inner: String)
    }

    /// Walks the string once, pairing each opening tag with its matching close
    /// (nesting-aware) and returning the raw inner HTML for recursion.
    private struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(source: String) {
            characters = Array(source)
        }

        mutating func next() -> Chunk? {
            guard index < characters.count else { return nil }

            if characters[index] != "<" {
                var text = ""
                while index < characters.count, characters[index] != "<" {
                    text.append(characters[index])
                    index += 1
                }
                return .text(text)
            }

            guard let tag = readTag() else {
                // A stray "<" that never closes — emit it as text.
                index += 1
                return .text("<")
            }

            if tag.isClosing {
                // Unbalanced closing tag; skip it.
                return next()
            }

            let voidElements: Set<String> = ["br", "img", "hr", "input", "meta", "link"]
            if tag.isSelfClosing || voidElements.contains(tag.name) {
                return .element(name: tag.name, attributes: tag.attributes, inner: "")
            }

            let inner = readInner(until: tag.name)
            return .element(name: tag.name, attributes: tag.attributes, inner: inner)
        }

        private struct Tag {
            let name: String
            let attributes: [String: String]
            let isClosing: Bool
            let isSelfClosing: Bool
        }

        /// Reads `<…>` starting at the current index, honouring quoted attributes.
        private mutating func readTag() -> Tag? {
            let start = index
            guard index < characters.count, characters[index] == "<" else { return nil }
            index += 1

            var raw = ""
            var quote: Character?
            while index < characters.count {
                let character = characters[index]
                if let active = quote {
                    if character == active { quote = nil }
                    raw.append(character)
                } else if character == "\"" || character == "'" {
                    quote = character
                    raw.append(character)
                } else if character == ">" {
                    index += 1
                    return parse(raw: raw)
                } else {
                    raw.append(character)
                }
                index += 1
            }
            index = start
            return nil
        }

        private func parse(raw: String) -> Tag {
            var body = raw
            let isClosing = body.hasPrefix("/")
            if isClosing { body.removeFirst() }
            let isSelfClosing = body.hasSuffix("/")
            if isSelfClosing { body.removeLast() }

            var name = ""
            var rest = Substring(body)
            while let character = rest.first, !character.isWhitespace {
                name.append(character)
                rest = rest.dropFirst()
            }

            return Tag(
                name: name.lowercased(),
                attributes: isClosing ? [:] : parseAttributes(String(rest)),
                isClosing: isClosing,
                isSelfClosing: isSelfClosing
            )
        }

        private func parseAttributes(_ source: String) -> [String: String] {
            var attributes: [String: String] = [:]
            var remainder = Substring(source)

            while !remainder.isEmpty {
                remainder = remainder.drop { $0.isWhitespace }
                guard !remainder.isEmpty else { break }

                var key = ""
                while let character = remainder.first, character != "=", !character.isWhitespace {
                    key.append(character)
                    remainder = remainder.dropFirst()
                }
                guard !key.isEmpty else { remainder = remainder.dropFirst(); continue }

                remainder = remainder.drop { $0.isWhitespace }
                guard remainder.first == "=" else {
                    attributes[key.lowercased()] = ""
                    continue
                }
                remainder = remainder.dropFirst().drop { $0.isWhitespace }

                var value = ""
                if let quote = remainder.first, quote == "\"" || quote == "'" {
                    remainder = remainder.dropFirst()
                    while let character = remainder.first, character != quote {
                        value.append(character)
                        remainder = remainder.dropFirst()
                    }
                    if !remainder.isEmpty { remainder = remainder.dropFirst() }
                } else {
                    while let character = remainder.first, !character.isWhitespace {
                        value.append(character)
                        remainder = remainder.dropFirst()
                    }
                }
                attributes[key.lowercased()] = HTMLText.decode(value)
            }
            return attributes
        }

        /// Consumes up to the matching `</name>`, tracking nested same-name tags.
        private mutating func readInner(until name: String) -> String {
            var depth = 1
            var inner = ""

            while index < characters.count {
                if characters[index] == "<" {
                    let checkpoint = index
                    if let tag = readTag() {
                        if tag.name == name && !tag.isSelfClosing {
                            if tag.isClosing {
                                depth -= 1
                                if depth == 0 { return inner }
                            } else {
                                depth += 1
                            }
                        }
                        inner += String(characters[checkpoint..<index])
                        continue
                    }
                    index = checkpoint
                }
                inner.append(characters[index])
                index += 1
            }
            return inner
        }
    }
}
import Foundation
import SwiftSoup

/// One HTML5 parse shared by metadata, structured payload, and lyric extraction.
/// The document stays local to a synchronous provider lookup; it is never shared
/// between concurrent requests or used to execute scripts or load resources.
final class LyricsHTMLPage {
    private static let asciiWhitespace = CharacterSet(charactersIn: " \t\n\u{000C}\r")
    private static let hiddenTags: Set<String> = ["script", "style", "noscript", "svg", "template", "head", "title"]
    private static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "section", "dl", "dt", "dd"]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private let document: Document
    private var scripts: [(id: String, type: String, body: String)] = []
    private(set) var documentTitle: String?
    private(set) var metadataTitles: [String] = []
    private(set) var identityURLReferences: [String] = []

    static func parse(_ html: String, context: @autoclosure () -> String) -> LyricsHTMLPage? {
        reportingParseErrors(context: context) { try LyricsHTMLPage(html) }
    }

    static func fragmentText(_ html: String, context: @autoclosure () -> String) -> String? {
        reportingParseErrors(context: context) {
            let fragment = try SwiftSoup.parseBodyFragment(html)
            return visibleText(in: fragment.body() ?? fragment)
        }
    }

    private static func reportingParseErrors<Value>(
        context: () -> String, _ parse: () throws -> Value
    ) -> Value? {
        do {
            return try parse()
        } catch {
            DebugLog.log("Lyrics HTML parse failed context='\(context())': \(error)")
            return nil
        }
    }

    init(_ html: String) throws {
        // Force HTML parsing, even when an XML declaration precedes the page.
        document = try SwiftSoup.parseHTML(html)
        var contents: [String: String] = [:]
        var title: String?
        var nodes: [Node] = [document]
        while let node = nodes.popLast() {
            guard let element = node as? Element else { continue }
            switch element.tagNameNormal() {
            case "template", "noscript", "svg":
                continue
            case "script":
                scripts.append((try element.attr("id"), try element.attr("type"), element.data()))
            case "meta":
                let property = try element.attr(element.hasAttr("property") ? "property" : "name").lowercased()
                if let content = try element.attr("content").nonEmpty {
                    if contents[property] == nil { contents[property] = content }
                    if property == "og:url" { identityURLReferences.append(content) }
                }
            case "link":
                let relations = try element.attr("rel").lowercased()
                    .components(separatedBy: Self.asciiWhitespace).filter { !$0.isEmpty }
                if relations.contains("canonical"), let href = try element.attr("href").nonEmpty {
                    identityURLReferences.append(href)
                }
            case "title":
                if title == nil { title = try element.text() }
            default:
                break
            }
            nodes.append(contentsOf: element.getChildNodes().reversed())
        }
        documentTitle = title?.nonEmpty
        metadataTitles = LyricsTextNormalization.uniqueNonEmptyStrings([
            contents["og:title"] ?? "", contents["twitter:title"] ?? "", title ?? ""
        ])
    }

    var structuredData: [String] {
        scripts.filter {
            $0.type.trimmingCharacters(in: Self.asciiWhitespace).lowercased() == "application/ld+json"
        }.map(\.body)
    }

    func scriptContent(withID id: String) -> String {
        // HTML attribute names are insensitive; ID values are case-sensitive.
        scripts.first(where: { $0.id == id })?.body ?? ""
    }

    func visibleText() -> String {
        Self.visibleText(in: document.body() ?? document)
    }

    func visibleText(in selector: String, excluding excludedSelector: String? = nil) -> String? {
        guard let excludedNodes = excludedNodes(matching: excludedSelector),
              let element = select(selector)?.first(where: {
                  Self.isVisible($0, excluding: excludedNodes)
              }) else { return nil }
        return Self.visibleText(in: element, excluding: excludedNodes)
    }

    struct TextRegion {
        let text: String
        let isBounded: Bool
    }

    func textRegion(
        preferred selector: String, excluding controls: String, excludingInContainer: String? = nil
    ) -> TextRegion? {
        guard var excludedNodes = excludedNodes(matching: controls),
              let matches = select(selector) else { return nil }
        let container = matches.first { Self.isVisible($0, excluding: excludedNodes, excludingHeaders: true) }
        // Optional container cleanup can fail without losing an established
        // boundary or the primary control exclusions. select logs the failure.
        if let container, let excludingInContainer,
           let elements = select(excludingInContainer, in: container) {
            excludedNodes.formUnion(elements.map { ObjectIdentifier($0) })
        }
        return TextRegion(
            text: Self.visibleText(
                in: container ?? document.body() ?? document,
                excluding: excludedNodes, preservingHeaderHeadings: container == nil
            ),
            isBounded: container != nil
        )
    }

    private func select(_ selector: String, in root: Element? = nil) -> Elements? {
        Self.reportingParseErrors(context: { "CSS selector '\(selector)'" }) {
            try (root ?? document).select(selector)
        }
    }

    private func excludedNodes(matching selector: String?) -> Set<ObjectIdentifier>? {
        guard let selector else { return [] }
        guard let elements = select(selector) else { return nil }
        return Set(elements.map { ObjectIdentifier($0) })
    }

    func visibleText(afterCommentContaining marker: String) -> String? {
        var nodes: [Node] = [document]
        while let node = nodes.popLast() {
            if let comment = node as? Comment, comment.getData().localizedCaseInsensitiveContains(marker),
               Self.isVisible(comment) {
                var pieces: [String] = []
                var sibling = comment.nextSibling()
                while let current = sibling {
                    pieces.append(Self.visibleText(in: current))
                    sibling = current.nextSibling()
                }
                return pieces.joined()
            }
            nodes.append(contentsOf: node.getChildNodes().reversed())
        }
        return nil
    }

    func visibleSections(in selector: String, headingTag: String) -> [(heading: String, text: String)] {
        guard let container = select(selector)?.first(where: Self.isVisible),
              let headings = select(headingTag, in: container) else { return [] }
        return headings.filter(Self.isVisible).map { heading in
            var pieces: [String] = []
            var sibling = heading.nextSibling()
            while let current = sibling {
                if let element = current as? Element, element.tagNameNormal() == headingTag { break }
                pieces.append(Self.visibleText(in: current))
                sibling = current.nextSibling()
            }
            return (Self.visibleText(in: heading), pieces.joined())
        }
    }

    private static func isVisible(_ node: Node) -> Bool {
        isVisible(node, excluding: [])
    }

    private static func isVisible(
        _ node: Node, excluding excludedNodes: Set<ObjectIdentifier>, excludingHeaders: Bool = false
    ) -> Bool {
        var ancestor: Node? = node
        while let current = ancestor {
            if excludedNodes.contains(ObjectIdentifier(current)) { return false }
            if excludingHeaders, let element = current as? Element, element.tagNameNormal() == "header" { return false }
            if let element = current as? Element, hiddenTags.contains(element.tagNameNormal()) { return false }
            ancestor = current.parent()
        }
        return true
    }

    private static func visibleText(
        in root: Node, excluding excludedNodes: Set<ObjectIdentifier> = [],
        preservingHeaderHeadings: Bool = false
    ) -> String {
        // Keep lyric line breaks instead of DOM text()'s whitespace collapsing.
        // Iteration also avoids a second recursion limit for deeply nested HTML.
        var pieces: [String] = []
        var nodes: [(node: Node, closing: Bool, headingsOnly: Bool)] = [(root, false, false)]
        while let (node, closing, headingsOnly) = nodes.popLast() {
            guard !excludedNodes.contains(ObjectIdentifier(node)) else { continue }
            if let text = node as? TextNode {
                if !headingsOnly { pieces.append(text.getWholeText()) }
            } else if let element = node as? Element {
                let name = element.tagNameNormal()
                guard !hiddenTags.contains(name) else { continue }
                // Headers can contain real anchors. Retain only their headings,
                // while nested navigation, ad slots and buttons stay excluded.
                if preservingHeaderHeadings && name == "header" {
                    nodes.append(contentsOf: element.getChildNodes().reversed().map { ($0, false, true) })
                    continue
                }
                if headingsOnly && !headingTags.contains(name) {
                    nodes.append(contentsOf: element.getChildNodes().reversed().map { ($0, false, true) })
                    continue
                }
                if closing || name == "br" {
                    pieces.append("\n")
                } else {
                    if blockTags.contains(name) {
                        if let previous = pieces.last, !previous.hasSuffix("\n") { pieces.append("\n") }
                        nodes.append((element, true, false))
                    }
                    nodes.append(contentsOf: element.getChildNodes().reversed().map { ($0, false, false) })
                }
            }
        }
        return pieces.joined()
    }
}

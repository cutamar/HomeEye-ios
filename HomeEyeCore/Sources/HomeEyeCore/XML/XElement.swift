import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum XMLError: Error {
    case doctypeNotAllowed
    case invalid
}

/// Minimal namespace-agnostic XML element. Names are local names (prefix stripped).
public struct XElement {
    public let name: String
    public let attributes: [String: String]
    public internal(set) var elements: [XElement]
    public internal(set) var text: String

    /// Character data and children interleaved in document order.
    fileprivate var parts: [Part] = []
    fileprivate enum Part {
        case text(String)
        case child(Int)
    }

    init(name: String, attributes: [String: String] = [:], elements: [XElement] = [], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.elements = elements
        self.text = text
    }

    /// All descendant text in document order.
    public var textContent: String {
        var out = ""
        for p in parts {
            switch p {
            case .text(let s): out += s
            case .child(let i): if i < elements.count { out += elements[i].textContent }
            }
        }
        return out
    }

    /// All descendants (excluding self), depth-first in document order.
    public func all(_ localName: String) -> [XElement] {
        var out: [XElement] = []
        collect(localName, into: &out)
        return out
    }

    private func collect(_ localName: String, into out: inout [XElement]) {
        for e in elements {
            if e.name == localName { out.append(e) }
            e.collect(localName, into: &out)
        }
    }

    /// First descendant in document order; stops at the first match.
    public func first(_ localName: String) -> XElement? {
        for e in elements {
            if e.name == localName { return e }
            if let f = e.first(localName) { return f }
        }
        return nil
    }

    public func children(_ localName: String) -> [XElement] {
        elements.filter { $0.name == localName }
    }

    public func text(_ localName: String) -> String? {
        first(localName)?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func attribute(_ name: String) -> String? { attributes[name] }
}

public enum XML {
    public static func parse(_ xml: String) throws -> XElement {
        try parse(Array(xml.utf8))
    }

    public static func parse(_ data: [UInt8]) throws -> XElement {
        guard !data.isEmpty else { throw XMLError.invalid }
        // Only ASCII-compatible UTF-8 input is accepted. libxml2 autodetects UTF-16/32/EBCDIC
        // from the bytes and honours `encoding=` in the XML declaration (e.g. UTF-7), either of
        // which would slip past the text scan below. NUL bytes reveal UTF-16/32; the declaration
        // is checked explicitly further down.
        if data.contains(0) { throw XMLError.invalid }
        var start = 0
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { start = 3 }
        while start < data.count, [0x20, 0x09, 0x0A, 0x0D].contains(data[start]) { start += 1 }
        guard start < data.count, data[start] == UInt8(ascii: "<") else { throw XMLError.invalid }
        try checkDeclaredEncoding(data, from: start)
        // Reject DTDs/entities up front (billion-laughs, XXE). This scan is the primary
        // defence; the delegate entity/DTD hooks in Builder are only a backstop on Darwin
        // (swift-corelibs-foundation does not invoke them).
        let upper = String(decoding: data, as: UTF8.self).uppercased()
        if upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") {
            throw XMLError.doctypeNotAllowed
        }
        let parser = XMLParser(data: Data(data))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = Builder()
        parser.delegate = delegate
        // On Linux parse() can return true despite a recorded error, so check both.
        let ok = parser.parse() && parser.parserError == nil
        if let failure = delegate.failure { throw failure }
        guard ok, let root = delegate.root else { throw XMLError.invalid }
        return root
    }

    /// Rejects an XML declaration whose encoding is anything but UTF-8 / US-ASCII.
    private static func checkDeclaredEncoding(_ data: [UInt8], from start: Int) throws {
        let prefix = Array("<?xml".utf8)
        guard data.count >= start + prefix.count + 1,
              Array(data[start..<(start + prefix.count)]) == prefix,
              [0x20, 0x09, 0x0A, 0x0D].contains(data[start + prefix.count]) else { return }
        var end = start + prefix.count
        while end + 1 < data.count, !(data[end] == UInt8(ascii: "?") && data[end + 1] == UInt8(ascii: ">")) { end += 1 }
        guard end + 1 < data.count else { throw XMLError.invalid }
        let decl = String(decoding: data[start..<end], as: UTF8.self)
        guard let r = decl.range(of: "encoding") else { return }
        var rest = decl[r.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard rest.first == "=" else { throw XMLError.invalid }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { throw XMLError.invalid }
        let value = rest.dropFirst().prefix { $0 != quote }
        let enc = value.lowercased()
        guard enc == "utf-8" || enc == "us-ascii" else { throw XMLError.invalid }
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    private static func local(_ qname: String) -> String {
        if let i = qname.lastIndex(of: ":") { return String(qname[qname.index(after: i)...]) }
        return qname
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XElement] = []
        var root: XElement?
        var failure: XMLError?
        static let maxDepth = 256
        static let maxElements = 50_000
        var elementCount = 0

        private func abort(_ parser: XMLParser, _ error: XMLError) {
            failure = error
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            abort(parser, .doctypeNotAllowed)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            abort(parser, .doctypeNotAllowed)
        }

        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
            abort(parser, .doctypeNotAllowed)
        }

        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String,
                    forElement elementName: String, type: String?, defaultValue: String?) {
            abort(parser, .doctypeNotAllowed)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            elementCount += 1
            if elementCount > Builder.maxElements { abort(parser, .invalid); return }
            if stack.count >= Builder.maxDepth || (stack.isEmpty && root != nil) { abort(parser, .invalid); return }
            var attrs: [String: String] = [:]
            for (k, v) in attributeDict where k != "xmlns" && !k.hasPrefix("xmlns:") {
                attrs[XML.local(k)] = v
            }
            stack.append(XElement(name: XML.local(elementName), attributes: attrs))
        }

        private func append(_ s: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += s
            stack[stack.count - 1].parts.append(.text(s))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let done = stack.popLast() else { return }
            if stack.isEmpty {
                root = done
            } else {
                let top = stack.count - 1
                let index = stack[top].elements.count
                stack[top].parts.append(.child(index))
                stack[top].elements.append(done)
            }
        }
    }
}

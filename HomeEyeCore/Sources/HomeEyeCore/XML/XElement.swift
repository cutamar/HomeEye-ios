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
    public var elements: [XElement]
    public var text: String

    /// Character data and children interleaved in document order.
    fileprivate var parts: [Part] = []
    fileprivate enum Part {
        case text(String)
        case child(Int)
    }

    public init(name: String, attributes: [String: String] = [:], elements: [XElement] = [], text: String = "") {
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
            case .child(let i): out += elements[i].textContent
            }
        }
        return out
    }

    /// All descendants (excluding self), depth-first in document order.
    public func all(_ localName: String) -> [XElement] {
        var out: [XElement] = []
        for e in elements {
            if e.name == localName { out.append(e) }
            out.append(contentsOf: e.all(localName))
        }
        return out
    }

    public func first(_ localName: String) -> XElement? { all(localName).first }

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
        // Reject DTDs/entities up front (billion-laughs, XXE).
        let upper = String(decoding: data, as: UTF8.self).uppercased()
        if upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") {
            throw XMLError.doctypeNotAllowed
        }
        let parser = XMLParser(data: Data(data))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = Builder()
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw XMLError.invalid }
        return root
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

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
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
                stack[top].parts.append(.child(stack[top].elements.count))
                stack[top].elements.append(done)
            }
        }
    }
}

//
//  HTMLTemplate.swift
//  MacDown
//
//  A minimal Handlebars-compatible template renderer, replacing the
//  handlebars-objc dependency. It supports the subset used by MacDown's page
//  templates:
//
//    {{{ name }}}                  raw substitution
//    {{ name }}                    HTML-escaped substitution
//    {{#each list}} … {{/each}}    iteration; `this` is the current item
//

import Foundation

public struct HTMLTemplate: Sendable {
    public enum Value: Sendable {
        case string(String)
        case list([String])
    }

    private indirect enum Token {
        case text(String)
        case variable(String, escaped: Bool)
        case each(String, [Token])
    }

    private let tokens: [Token]

    public init(_ source: String) {
        var scanner = Substring(source)
        tokens = HTMLTemplate.parse(&scanner, until: nil)
    }

    public func render(_ context: [String: Value]) -> String {
        var out = ""
        HTMLTemplate.render(tokens, context: context, this: nil, into: &out)
        return out
    }

    // MARK: - Parsing

    private static func parse(_ s: inout Substring, until closing: String?) -> [Token] {
        var tokens: [Token] = []
        while !s.isEmpty {
            guard let open = s.range(of: "{{") else {
                tokens.append(.text(String(s)))
                s = s[s.endIndex...]
                break
            }
            if open.lowerBound > s.startIndex {
                tokens.append(.text(String(s[s.startIndex..<open.lowerBound])))
            }
            let triple = s[open.upperBound...].hasPrefix("{")
            let bodyStart = triple ? s.index(after: open.upperBound) : open.upperBound
            let closer = triple ? "}}}" : "}}"
            guard let close = s[bodyStart...].range(of: closer) else {
                tokens.append(.text(String(s[open.lowerBound...])))
                s = s[s.endIndex...]
                break
            }
            let body = s[bodyStart..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            s = s[close.upperBound...]

            if body.hasPrefix("#each") {
                let name = body.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let inner = parse(&s, until: "each")
                tokens.append(.each(name, inner))
            } else if body.hasPrefix("/") {
                if closing != nil { return tokens }
            } else {
                tokens.append(.variable(body, escaped: !triple))
            }
        }
        return tokens
    }

    // MARK: - Rendering

    private static func render(_ tokens: [Token], context: [String: Value],
                               this: String?, into out: inout String) {
        for token in tokens {
            switch token {
            case .text(let t):
                out += t
            case .variable(let name, let escaped):
                var value = ""
                if name == "this" {
                    value = this ?? ""
                } else if case .string(let s)? = context[name] {
                    value = s
                }
                out += escaped ? MPEscapeHTML(value) : value
            case .each(let name, let inner):
                guard case .list(let items)? = context[name] else { continue }
                for item in items {
                    render(inner, context: context, this: item, into: &out)
                }
            }
        }
    }
}

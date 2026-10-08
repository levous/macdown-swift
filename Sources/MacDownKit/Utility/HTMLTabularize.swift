//
//  HTMLTabularize.swift
//  MacDown
//
//  Ported from NSObject+HTMLTabularize.m. Renders front matter as HTML
//  tables.
//

import Foundation

public func MPEscapeHTML(_ string: String) -> String {
    var result = ""
    result.reserveCapacity(string.utf8.count)
    for c in string {
        switch c {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        case "'": result += "&#39;"
        default: result.append(c)
        }
    }
    return result
}

extension YAMLValue {
    public var htmlTable: String {
        switch self {
        case .null:
            return ""
        case .string(let s):
            return MPEscapeHTML(s)
        case .sequence(let items):
            let cells = items.map { "<td>\($0.htmlTable)</td>" }.joined()
            return "<table><tbody><tr>\(cells)</tr></tbody></table>"
        case .mapping(let pairs):
            let heads = pairs.map { "<th>\($0.key.htmlTable)</th>" }.joined()
            let cells = pairs.map { "<td>\($0.value.htmlTable)</td>" }.joined()
            return "<table><thead><tr>\(heads)</tr></thead>"
                + "<tbody><tr>\(cells)</tr></tbody></table>"
        }
    }
}

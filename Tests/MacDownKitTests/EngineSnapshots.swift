//
//  EngineSnapshots.swift
//  MacDownKitTests
//
//  What the original engines produced, recorded on 2026-10-22 just before
//  they were removed: hoedown's HTML (with MacDown's patches) and escaping,
//  and PEG Markdown Highlight's style parser (pmh_styleparser.c). The port
//  matched them byte for byte, and the tests keep it that way against these
//  recordings (Resources/engine-snapshots.json).
//

import Foundation
import Testing
@testable import MacDownKit

enum EngineSnapshots {
    static let values: [String: String] = {
        let url = Bundle.module.url(forResource: "engine-snapshots", withExtension: "json",
                                    subdirectory: "Resources")!
        return try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }()

    /// The recording named `key`.
    static func value(_ key: String) throws -> String {
        try #require(values[key], "no snapshot \(key.debugDescription)")
    }
}

/// A theme parse result as text, one attribute per line, to compare with
/// the recorded C parser's.
func themeDescription(_ style: ThemeStyle) -> String {
    func color(_ c: ThemeStyle.Color) -> String {
        String(format: "%02x%02x%02x%02x", c.alpha, c.red, c.green, c.blue)
    }
    func describe(_ attribute: ThemeStyle.Attribute) -> String {
        let value = switch attribute.value {
        case .foregroundColor(let c): "foreground \(color(c))"
        case .backgroundColor(let c): "background \(color(c))"
        case .caretColor(let c): "caret \(color(c))"
        case .fontSize(let points, let relative): "size \(points) relative \(relative)"
        case .fontFamily(let family): "family \(family)"
        case .fontStyle(let italic, let bold, let underlined):
            "style italic \(italic) bold \(bold) underlined \(underlined)"
        case .other(let string): "other \(string)"
        }
        return "  \(attribute.name): \(value)"
    }
    var lines: [String] = []
    for (name, attributes) in [("editor", style.editor), ("editor-current-line", style.currentLine),
                               ("editor-selection", style.selection)] {
        lines.append(name)
        lines += attributes.map(describe)
    }
    for element in style.elements {
        lines.append(element.element)
        lines += element.attributes.map(describe)
    }
    lines += style.errors.map { "error \($0)" }
    return lines.joined(separator: "\n")
}

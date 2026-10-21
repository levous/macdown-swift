//
//  HTMLToMarkdown+Renderer.swift
//  MacDownKit
//
//  Blocks of inline runs as Markdown text.
//

import Foundation

extension HTMLToMarkdown {
    struct Renderer {
        let options: Options

        func render(_ blocks: [Block]) -> Result {
            let markdown = blocks.map(render).joined(separator: "\n\n")
            if blocks.count == 1, case .paragraph = blocks[0] {
                return Result(markdown: markdown, isInline: true)
            }
            return Result(markdown: markdown + "\n", isInline: false)
        }

        func render(_ block: Block) -> String {
            switch block {
            case .paragraph(let inlines):
                return render(inlines)
            }
        }

        func render(_ inlines: [Inline]) -> String {
            inlines.map { inline in
                switch inline {
                case .text(let text): text
                }
            }.joined()
        }
    }
}

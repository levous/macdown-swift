# Third-party licenses

What each license here covers in MacDown:

| File | Covers |
|---|---|
| `cmark-gfm.txt` | [swift-cmark](https://github.com/swiftlang/swift-cmark) (cmark-gfm and its GFM extensions), the Markdown parser |
| `peg-markdown-highlight.txt` | The Swift ports of PEG Markdown Highlight's editor highlighter (`MarkdownHighlighter.swift`) and theme parser (`ThemeStyleParser.swift`). The C library itself is no longer used; the ports keep the `.style` themes working |
| `libyaml.txt` | libyaml, through [Yams](https://github.com/jpsim/Yams), for front matter |
| `prism.txt` | Prism, syntax highlighting in the preview |
| `mermaid.txt` | Mermaid diagrams |
| `graphviz.txt` | Graphviz (viz.js) diagrams |
| `markdown-mark.txt` | The Markdown mark image in the help |
| `macdown.txt` | The original MacDown, which this app ports |

hoedown and PEG Markdown Highlight's C parser were removed on 2026-10-22,
when the move to cmark-gfm finished (docs/MACDOWN-PORT.md).

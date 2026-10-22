// Saves everything on the clipboard as a paste fixture: one file per type,
// named after the type identifier, plus a manifest.json listing the types,
// their sizes and the source app.
//
//     swift Tools/capture-pasteboard.swift <source> [output directory] [--pasteboard <name>]
//
// The output directory defaults to Tests/MacDownKitTests/Resources/Paste/<source>
// (relative to the current directory, so run it from the repository root).
// --pasteboard reads a named pasteboard instead of the general one.
//
// Capturing a source app, with Tests/MacDownKitTests/Resources/Paste/sample.md
// (generated content only, never real documents):
//
// - MacDown's preview: open sample.md, select all in the preview, copy, then
//   run this tool with source "macdown-preview".
// - Browsers (Safari, Chrome): open the HTML exported from MacDown
//   (File ▸ Export ▸ HTML) in the browser, select all, copy.
// - Google Docs, Word, Pages, TextEdit, Notion: paste the copied preview into
//   a new document, fix anything the app lost (lists, the merged-cell table),
//   then select all in that app and copy.
// - Code editors (VS Code, Xcode, Terminal, JetBrains): open sample.md (or
//   `cat` it in Terminal), select the Swift code block's lines and copy.
//
// Use the app's name in lower case as the source (safari, chrome, google-docs,
// word, pages, textedit, notion, vscode, xcode, terminal, macdown-preview).

import AppKit

var args = Array(CommandLine.arguments.dropFirst())
var pasteboardName: String?
if let index = args.firstIndex(of: "--pasteboard"), index + 1 < args.count {
    pasteboardName = args[index + 1]
    args.removeSubrange(index...index + 1)
}
guard let source = args.first, !source.isEmpty else {
    FileHandle.standardError.write(Data("usage: capture-pasteboard <source> [dir] [--pasteboard <name>]\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: args.count > 1
    ? args[1] : "Tests/MacDownKitTests/Resources/Paste/\(source)")
let pasteboard = pasteboardName.map { NSPasteboard(name: .init($0)) } ?? .general

guard let item = pasteboard.pasteboardItems?.first, !item.types.isEmpty else {
    FileHandle.standardError.write(Data("the clipboard is empty\n".utf8))
    exit(1)
}
if (pasteboard.pasteboardItems?.count ?? 0) > 1 {
    FileHandle.standardError.write(Data("note: \(pasteboard.pasteboardItems!.count) items; saving the first\n".utf8))
}

try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var entries: [[String: Any]] = []
for type in item.types {
    guard let data = item.data(forType: type) else { continue }
    let file = type.rawValue.replacingOccurrences(of: "/", with: "_")
    try data.write(to: directory.appendingPathComponent(file))
    entries.append(["type": type.rawValue, "file": file, "size": data.count])
    print("\(type.rawValue): \(data.count) bytes")
}
let manifest: [String: Any] = ["source": source, "types": entries]
let json = try JSONSerialization.data(withJSONObject: manifest,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: directory.appendingPathComponent("manifest.json"))
print("saved \(entries.count) types → \(directory.path)")

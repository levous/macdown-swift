//
//  MacDownCommands.swift
//  MacDown
//
//  The menu bar, ported from MainMenu.xib. Commands act on the focused
//  document window's controller.
//

import SwiftUI

public struct MacDownCommands: Commands {
    @FocusedValue(\.documentController) private var controller

    public init() {}

    public var body: some Commands {
        // Replace SwiftUI's printing items: the preview is what gets printed.
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") {
                NSPageLayout().runModal(with: NSPrintInfo.shared)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print…") { controller?.printDocument() }
                .keyboardShortcut("p")
                .disabled(controller == nil)
        }

        CommandGroup(replacing: .importExport) {
            Menu("Export") {
                Button("HTML…") { controller?.exportHtml() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("PDF…") { controller?.exportPdf() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
            .disabled(controller == nil)
        }

        TextEditingCommands()
        ToolbarCommands()

        CommandGroup(before: .toolbar) {
            Button("Render Markdown") { controller?.renderNow() }
                .keyboardShortcut("r")
            Divider()
            Button("Left 1:3 Right") { controller?.setLeftPaneFraction(0.25) }
            Button("Left 1:1 Right") { controller?.setLeftPaneFraction(0.5) }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Button("Left 3:1 Right") { controller?.setLeftPaneFraction(0.75) }
            Button(LocalizedStringKey(controller?.previewVisible ?? true
                   ? "Hide Preview Pane" : "Restore Preview Pane")) {
                controller?.togglePreviewPane()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!(controller?.canRestorePreview ?? false))
            Button(LocalizedStringKey(controller?.editorVisible ?? true
                   ? "Hide Editor Pane" : "Restore Editor Pane")) {
                controller?.toggleEditorPane()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Format") {
            FormatMenuContent(controller: controller)
        }

        CommandMenu("Plug-ins") {
            PlugInMenuContent()
        }

        CommandGroup(replacing: .help) {
            Button("MacDown Help") { AppSupport.openBundledFile("help", "md") }
            Button("Contributing to MacDown") {
                AppSupport.openBundledFile("contribute", "md")
            }
        }
    }
}

struct FormatMenuContent: View {
    let controller: DocumentController?

    var body: some View {
        Group {
            Group {
                Button("Copy HTML") { controller?.copyHtml() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                Button("Strong") { controller?.toggleStrong() }
                    .keyboardShortcut("b")
                Button("Emphasize") { controller?.toggleEmphasis() }
                    .keyboardShortcut("i")
                Button("Underline") { controller?.toggleUnderline() }
                    .keyboardShortcut("u")
                Button("Strikethrough") { controller?.toggleStrikethrough() }
                    .keyboardShortcut("-")
                Button("Highlight") { controller?.toggleHighlight() }
                    .keyboardShortcut("=")
                Button("Inline Code") { controller?.toggleInlineCode() }
                    .keyboardShortcut("k")
                Button("Comment") { controller?.toggleComment() }
                    .keyboardShortcut("/")
            }
            Divider()
            Menu("Convert To") {
                ForEach(1...6, id: \.self) { level in
                    Button("Header \(level)") { controller?.convertToHeader(level: level) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")))
                }
                Button("Paragraph") { controller?.convertToHeader(level: 0) }
                    .keyboardShortcut("0")
            }
            Divider()
            Group {
                Button("Ordered List") { controller?.toggleOrderedList() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Unordered List") { controller?.toggleUnorderedList() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Blockquote") { controller?.toggleBlockquote() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            Divider()
            Button("Shift Right") { controller?.indent() }
                .keyboardShortcut("]")
            Button("Shift Left") { controller?.unindent() }
                .keyboardShortcut("[")
            Divider()
            Group {
                Button("Link") { controller?.toggleLink() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Image") { controller?.toggleImage() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("New Paragraph") { controller?.insertNewParagraph() }
            }
        }
        .disabled(controller == nil)
    }
}

struct PlugInMenuContent: View {
    @ObservedObject private var plugIns = PlugInController.shared

    var body: some View {
        if plugIns.plugIns.isEmpty {
            Text("No Plug-ins Installed")
        }
        ForEach(plugIns.plugIns) { plugIn in
            Button(plugIn.name) { plugIn.run() }
        }
    }
}

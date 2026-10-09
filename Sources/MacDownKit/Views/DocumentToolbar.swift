//
//  DocumentToolbar.swift
//  MacDown
//
//  Ported from MPToolbarController.m. The toolbar is customizable; comment,
//  highlight and strikethrough are available but hidden by default, as in
//  the original.
//

import SwiftUI

struct DocumentToolbar: CustomizableToolbarContent {
    let controller: DocumentController

    private func icon(_ name: String, _ label: LocalizedStringKey) -> some View {
        Label {
            Text(label)
        } icon: {
            Image(name, bundle: .main)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 19, height: 19)
        }
    }

    private func button(_ name: String, _ label: LocalizedStringKey,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(name, label) }
            .help(Text(label))
    }

    /// Lays the buttons out as one toolbar item, so they share a single
    /// background like adjacent single-button items do. A ControlGroup is
    /// drawn as separate buttons instead.
    private func group(_ label: LocalizedStringKey,
                       @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0) { content() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(label))
    }

    var body: some CustomizableToolbarContent {
        // Only without autosaving; then it's enabled when there's something
        // to save.
        if !Preferences.shared.autosavesDocuments {
            ToolbarItem(id: "save") {
                Button { controller.save() } label: {
                    Label {
                        Text("Save")
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .regular))
                            .frame(width: 19, height: 19)
                    }
                }
                .help(Text("Save"))
                .disabled(!controller.hasUnsavedChanges)
            }
            if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        }
        ToolbarItem(id: "indent-group") {
            group("Shift Left/Right") {
                button("ToolbarIconShiftLeft", "Shift Left") { controller.unindent() }
                button("ToolbarIconShiftRight", "Shift Right") { controller.indent() }
            }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItem(id: "text-formatting-group") {
            group("Text Styles") {
                button("ToolbarIconBold", "Strong") { controller.toggleStrong() }
                button("ToolbarIconItalic", "Emphasize") { controller.toggleEmphasis() }
                button("ToolbarIconUnderlined", "Underline") { controller.toggleUnderline() }
            }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItem(id: "heading-group") {
            group("Headings") {
                button("ToolbarIconHeading1", "Heading 1") { controller.convertToHeader(level: 1) }
                button("ToolbarIconHeading2", "Heading 2") { controller.convertToHeader(level: 2) }
                button("ToolbarIconHeading3", "Heading 3") { controller.convertToHeader(level: 3) }
            }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItem(id: "list-group") {
            group("Ordered/Unordered List") {
                button("ToolbarIconUnorderedList", "Unordered List") {
                    controller.toggleUnorderedList()
                }
                button("ToolbarIconOrderedList", "Ordered List") {
                    controller.toggleOrderedList()
                }
            }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItem(id: "blockquote") {
            button("ToolbarIconBlockquote", "Blockquote") { controller.toggleBlockquote() }
        }
        ToolbarItem(id: "code") {
            button("ToolbarIconInlineCode", "Inline Code") { controller.toggleInlineCode() }
        }
        ToolbarItem(id: "link") {
            button("ToolbarIconLink", "Link") { controller.toggleLink() }
        }
        ToolbarItem(id: "image") {
            button("ToolbarIconImage", "Image") { controller.toggleImage() }
        }
        ToolbarItem(id: "copy-html") {
            button("ToolbarIconCopyHTML", "Copy HTML") { controller.copyHtml() }
        }
        ToolbarItem(id: "comment", showsByDefault: false) {
            button("ToolbarIconComment", "Comment") { controller.toggleComment() }
        }
        ToolbarItem(id: "highlight", showsByDefault: false) {
            button("ToolbarIconHighlight", "Highlight") { controller.toggleHighlight() }
        }
        ToolbarItem(id: "strikethrough", showsByDefault: false) {
            button("ToolbarIconStrikethrough", "Strikethrough") {
                controller.toggleStrikethrough()
            }
        }
        ToolbarItem(id: "layout") {
            Menu {
                Button(LocalizedStringKey(controller.editorVisible
                                          ? "Hide Editor Pane" : "Restore Editor Pane")) {
                    controller.toggleEditorPane()
                }
                Button(LocalizedStringKey(controller.previewVisible
                                          ? "Hide Preview Pane" : "Restore Preview Pane")) {
                    controller.togglePreviewPane()
                }
            } label: {
                icon("ToolbarIconEditorAndPreview", "Layout")
            }
            .help(Text("Layout"))
        }
    }
}

//
//  DocumentView.swift
//  MacDown
//
//  The document window's content: editor and preview side by side, the word
//  count widget and the toolbar.
//

import SwiftUI

extension FocusedValues {
    @Entry public var documentController: DocumentController?
}

public struct DocumentView: View {
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    // Created once on appear; constructing it builds an NSTextView and a
    // WKWebView, which must not happen on every re-render.
    @State private var controller: DocumentController?

    public init(document: MarkdownDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
    }

    public var body: some View {
        Group {
            if let controller {
                DocumentContentView(controller: controller, document: document,
                                    fileURL: fileURL)
            } else {
                Color(nsColor: .textBackgroundColor)
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        .onAppear {
            if controller == nil {
                controller = DocumentController(document: document, fileURL: fileURL)
            }
        }
    }
}

struct DocumentContentView: View {
    let controller: DocumentController
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    @SceneStorage("editorFraction") private var storedFraction: Double = 0.5

    var body: some View {
        let editorOnRight = controller.editorOnRight
        let leadingFraction = editorOnRight
            ? 1 - controller.editorFraction : controller.editorFraction

        DocumentSplitView(
            fraction: leadingFraction,
            dividerColor: controller.dividerColor.map { Color(nsColor: $0) },
            onResize: { fraction in
                controller.userDidResizeSplit(to: editorOnRight ? 1 - fraction : fraction)
            }
        ) {
            if editorOnRight { previewPane } else { editorPane }
        } trailing: {
            if editorOnRight { editorPane } else { previewPane }
        }
        .frame(minWidth: 400, minHeight: 300)
        .toolbar(id: "MacDownToolbar") { DocumentToolbar(controller: controller) }
        .focusedSceneValue(\.documentController, controller)
        .onAppear {
            controller.editorFraction = storedFraction
            DispatchQueue.main.async { controller.viewDidAppear() }
        }
        .onDisappear { controller.tearDown() }
        .onChange(of: fileURL) { _, url in controller.fileURL = url }
        .onChange(of: ObjectIdentifier(document)) { _, _ in
            controller.replaceDocument(document)
        }
        .onChange(of: controller.editorFraction) { _, fraction in
            if fraction > 0.001 && fraction < 0.999 {
                storedFraction = fraction
            }
        }
    }

    private var editorPane: some View {
        EditorRepresentable(controller: controller)
            .background(Color(nsColor: controller.editorBackgroundColor))
            .overlay(alignment: .bottomLeading) {
                if controller.showsWordCount {
                    WordCountWidget(controller: controller)
                        .padding(8)
                }
            }
    }

    private var previewPane: some View {
        PreviewRepresentable(controller: controller)
    }
}

struct WordCountWidget: View {
    let controller: DocumentController
    @AppStorage("editorWordCountType") private var wordCountType = 0

    var body: some View {
        Menu {
            Picker("Count", selection: $wordCountType) {
                ForEach(WordCountType.allCases, id: \.rawValue) { type in
                    Text(controller.wordCountTitle(for: type)).tag(type.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(controller.wordCountTitle(
                for: WordCountType(rawValue: wordCountType) ?? .words))
                .monospacedDigit()
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .opacity(0.9)
        .disabled(!controller.isTextCountReady)
    }
}

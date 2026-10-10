//
//  MarkdownDocument.swift
//  MacDown
//
//  The SwiftUI document model. The editor's NSTextView is the source of truth
//  while a window is open; `text` is kept in sync for saving.
//

import Combine
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    public static let markdownText = UTType(importedAs: "net.daringfireball.markdown",
                                            conformingTo: .plainText)
}

/// Content handed to the next new document (e.g. text piped to the shell
/// utility).
public enum PendingDocumentContent {
    private static let storage = Mutex<String?>(nil)

    public static func set(_ text: String?) {
        storage.withLock { $0 = text }
    }

    /// Returns the pending text and clears it.
    public static func take() -> String? {
        storage.withLock { value in
            defer { value = nil }
            return value
        }
    }
}

public final class MarkdownDocument: ReferenceFileDocument, @unchecked Sendable {
    public typealias Snapshot = String

    public static let readableContentTypes: [UTType] = [.markdownText, .plainText, .text]
    public static let writableContentTypes: [UTType] = [.markdownText, .plainText]

    /// The document's text. Accessed on the main actor.
    public var text: String

    public let objectWillChange = ObservableObjectPublisher()

    private let writtenText = Mutex<String?>(nil)

    /// The text this document last wrote to disk, so its own saves aren't
    /// mistaken for changes made by another application.
    public var lastWrittenText: String? { writtenText.withLock { $0 } }

    public init() {
        text = PendingDocumentContent.take() ?? ""
    }

    public init(text: String) {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let content = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        text = content
    }

    public func snapshot(contentType: UTType) throws -> String {
        var text = self.text
        // Read user defaults directly; this may be called off the main actor.
        let ensuresNewline = UserDefaults.standard.bool(forKey: .editorEnsuresNewlineAtEndOfFile)
        if ensuresNewline, let last = text.unicodeScalars.last,
           !CharacterSet.newlines.contains(last) {
            text += "\n"
        }
        return text
    }

    public func fileWrapper(snapshot: String,
                            configuration: WriteConfiguration) throws -> FileWrapper {
        writtenText.withLock { $0 = snapshot }
        return FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}

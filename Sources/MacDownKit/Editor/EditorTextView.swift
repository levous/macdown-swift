//
//  EditorTextView.swift
//  MacDown
//
//  Ported from MPEditorView.m.
//

import AppKit
import UniformTypeIdentifiers

public final class EditorTextView: NSTextView {
    /// Whether the editor allows scrolling past the end of the text.
    public var scrollsPastEnd = false {
        didSet {
            if scrollsPastEnd {
                DispatchQueue.main.async { [weak self] in
                    self?.updateContentGeometry()
                }
            } else {
                // Clears contentRect to fall back to the frame.
                storedContentRect = .zero
                setFrameSize(frame.size)
            }
        }
    }

    /// Called when the frame changes (used to apply width limiting).
    public var frameDidChange: ((EditorTextView) -> Void)?

    private var storedContentRect: NSRect = .zero
    private var trailingHeight: CGFloat = 0

    public var contentRect: NSRect {
        storedContentRect == .zero ? frame : storedContentRect
    }

    public static func makeScrollableEditor() -> (NSScrollView, EditorTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: contentSize.width,
                                                     height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(frame: NSRect(origin: .zero, size: contentSize),
                                      textContainer: container)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = true
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    // MARK: - Overrides

    public override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if scrollsPastEnd {
            let ch = contentRect.size.height
            let eh = enclosingScrollView?.contentSize.height ?? 0
            var offset = min(ch, eh)
            offset -= trailingHeight + 2 * textContainerInset.height
            if offset > 0 { size.height += offset }
        }
        let widthChanged = size.width != frame.size.width
        super.setFrameSize(size)
        if widthChanged { frameDidChange?(self) }
    }

    public override var string: String {
        didSet {
            if scrollsPastEnd {
                DispatchQueue.main.async { [weak self] in
                    self?.updateContentGeometry()
                }
            }
        }
    }

    public override func didChangeText() {
        super.didChangeText()
        if scrollsPastEnd { updateContentGeometry() }
    }

    // MARK: - Dragging images

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if imageFileURLs(from: sender.draggingPasteboard).isEmpty {
            return super.draggingEntered(sender)
        }
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.link) { return .link }
        if mask.contains(.copy) { return .copy }
        return super.draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = imageFileURLs(from: sender.draggingPasteboard)
        guard let url = urls.first else {
            return super.performDragOperation(sender)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "image/jpeg"
        let markup = "![](data:\(mime);base64,\(data.base64EncodedString()))"
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        insertText(markup, replacementRange: NSRange(location: index, length: 0))
        return true
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL] ?? []
    }

    // MARK: - Private

    private func updateContentGeometry() {
        guard let layoutManager, let textContainer else { return }
        let content = string as NSString
        layoutManager.ensureLayout(for: textContainer)
        var r = layoutManager.usedRect(for: textContainer)

        let visible = CharacterSet.whitespacesAndNewlines.inverted
        let lastRange = content.rangeOfCharacter(from: visible, options: .backwards)
        var junkRect = r
        if lastRange.location != NSNotFound {
            let firstJunk = lastRange.location + lastRange.length
            let junkRange = NSRange(location: firstJunk, length: content.length - firstJunk)
            let glyphs = layoutManager.glyphRange(forCharacterRange: junkRange,
                                                  actualCharacterRange: nil)
            junkRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        }
        trailingHeight = junkRect.size.height

        let inset = textContainerInset
        r.size.width += 2 * inset.width
        r.size.height += 2 * inset.height
        storedContentRect = r
        setFrameSize(frame.size)    // Force size update.
    }
}

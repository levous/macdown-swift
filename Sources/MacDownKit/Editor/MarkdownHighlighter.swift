//
//  MarkdownHighlighter.swift
//  MacDown
//
//  Swift port of HGMarkdownHighlighter and HGMarkdownHighlightingStyle from
//  PEG Markdown Highlight (Copyright 2011-2013 Ali Rantakari, MIT/GPL2+; see
//  Licenses/peg-markdown-highlight.txt). The spans now come from the
//  cmark-gfm document model; PEG's C parser is no longer used.
//

import AppKit

/// A single highlighted span, in UTF-16 offsets.
struct HighlightSpan: Sendable {
    var pos: Int
    var end: Int
    var address: String?
}

/// The element types themes style and the highlighter highlights: PEG
/// Markdown Highlight's (`pmh_element_type`, in its order, which the themes'
/// names follow; see `ThemeStyle.elementNames`), then those it didn't have.
enum HighlightElement: Int, CaseIterable {
    case link, autoLinkURL, autoLinkEmail, image, code, html, htmlEntity, emph, strong
    case listBullet, listEnumerator, comment, h1, h2, h3, h4, h5, h6, blockquote, verbatim
    case htmlBlock, hrule, reference, note, math, highlight, superscript
}

/// Highlight spans, indexed by `HighlightElement` raw value. They come from
/// the document model (`HighlightMapper`).
struct HighlightElements: Sendable {
    var spans: [[HighlightSpan]]
}

/// Attributes applied to one Markdown element type.
struct HighlightingStyle {
    static let fontInformationKey = NSAttributedString.Key("HGFontInformation")
    static let minFontSize: CGFloat = 4

    var elementType: Int
    var attributesToAdd: [NSAttributedString.Key: Any] = [:]
    var fontName: String?
    var fontSize: CGFloat?
    var fontTraitsToAdd: NSFontTraitMask = []

    static func color(_ argb: ThemeStyle.Color) -> NSColor {
        NSColor(deviceRed: CGFloat(argb.red) / 255.0,
                green: CGFloat(argb.green) / 255.0,
                blue: CGFloat(argb.blue) / 255.0,
                alpha: CGFloat(argb.alpha) / 255.0)
    }

    init(elementType: Int, foreground: NSColor? = nil, background: NSColor? = nil,
         traits: NSFontTraitMask = []) {
        self.elementType = elementType
        if let foreground { attributesToAdd[.foregroundColor] = foreground }
        if let background { attributesToAdd[.backgroundColor] = background }
        fontTraitsToAdd = traits
    }

    /// A theme rule's style. Element types are indexes in
    /// `ThemeStyle.elementNames`, which follows PEG Markdown Highlight's order.
    init?(_ rule: ThemeStyle.ElementStyle, baseFont: NSFont?) {
        guard let type = ThemeStyle.elementNames.firstIndex(of: rule.element) else { return nil }
        elementType = type
        var fontSize: CGFloat = 0
        var relative = false
        for attribute in rule.attributes {
            switch attribute.value {
            case .foregroundColor(let color):
                attributesToAdd[.foregroundColor] = Self.color(color)
            case .backgroundColor(let color):
                attributesToAdd[.backgroundColor] = Self.color(color)
            case .fontStyle(let italic, let bold, let underlined):
                if italic { fontTraitsToAdd.insert(.italicFontMask) }
                if bold { fontTraitsToAdd.insert(.boldFontMask) }
                if underlined {
                    attributesToAdd[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            case .fontSize(let points, let isRelative):
                fontSize = CGFloat(points)
                relative = isRelative
            case .fontFamily(let name):
                fontName = name
            case .caretColor, .other:
                break
            }
        }
        if fontSize != 0 {
            var actual = relative ? (baseFont?.pointSize ?? 0) + fontSize : fontSize
            if actual < Self.minFontSize { actual = Self.minFontSize }
            self.fontSize = actual
        }
    }

    static func defaultStyles() -> [HighlightingStyle] {
        func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1)
        }
        func dark(_ h: CGFloat) -> NSColor { hsb(h, 1, 0.4) }
        func light(_ h: CGFloat) -> NSColor { hsb(h, 0.2, 1) }
        func dim(_ h: CGFloat) -> NSColor { hsb(h, 0.2, 0.5) }
        let green: CGFloat = 0.34, yellow: CGFloat = 0.15, blue: CGFloat = 0.67
        let red: CGFloat = 0, magenta: CGFloat = 0.87, cyan: CGFloat = 0.5
        let darkGray = hsb(0, 0, 0.2), medGray = hsb(0, 0, 0.5), lightGray = hsb(0, 0, 0.9)

        func t(_ type: HighlightElement) -> Int { type.rawValue }
        var styles: [HighlightingStyle] = []
        for h in [HighlightElement.h1, .h2, .h3, .h4, .h5, .h6] {
            styles.append(.init(elementType: t(h), foreground: dark(blue),
                                background: light(blue), traits: .boldFontMask))
        }
        styles += [
            .init(elementType: t(.hrule), foreground: darkGray, background: lightGray),
            .init(elementType: t(.listBullet), foreground: dark(magenta)),
            .init(elementType: t(.listEnumerator), foreground: dark(magenta)),
            .init(elementType: t(.link), foreground: dark(cyan), background: light(cyan)),
            .init(elementType: t(.autoLinkURL), foreground: dark(cyan), background: light(cyan)),
            .init(elementType: t(.autoLinkEmail), foreground: dark(cyan), background: light(cyan)),
            .init(elementType: t(.image), foreground: dark(magenta), background: light(magenta)),
            .init(elementType: t(.reference), foreground: dim(red)),
            .init(elementType: t(.code), foreground: dark(green), background: light(green)),
            .init(elementType: t(.emph), foreground: dark(yellow), traits: .italicFontMask),
            .init(elementType: t(.strong), foreground: dark(magenta), traits: .boldFontMask),
            .init(elementType: t(.htmlEntity), foreground: medGray),
            .init(elementType: t(.comment), foreground: medGray),
            .init(elementType: t(.verbatim), foreground: dark(green), background: light(green)),
            .init(elementType: t(.blockquote), foreground: dark(magenta),
                  traits: .unboldFontMask),
        ]
        return styles
    }
}

/// Highlights Markdown syntax in an NSTextView.
@MainActor
public final class MarkdownHighlighter {
    public weak var textView: NSTextView? {
        didSet { if textView != nil { readClearTextStylesFromTextView() } }
    }
    public var resetTypingAttributes = true
    public var makeLinksClickable = false
    public private(set) var isActive = false
    /// Whether the idle pass is styling the rest of the document. Its storage
    /// edits come a chunk at a time; layout-dependent work can wait for
    /// `onIdlePassFinished` instead of following each one.
    public private(set) var isInIdlePass = false
    /// How long after an edit the idle pass waits, so it doesn't restyle the
    /// whole document per keystroke.
    var idleDelayAfterEdit: TimeInterval = 0.5
    /// Called when the idle pass has styled the whole document.
    public var onIdlePassFinished: (() -> Void)?

    var styles: [HighlightingStyle] = HighlightingStyle.defaultStyles() {
        didSet { applyStyleDependencies() }
    }

    private var cachedElements: HighlightElements?
    private var clearFontTraitMask: NSFontTraitMask = []
    private var defaultTextSize: CGFloat = 0
    private var defaultTextColor: NSColor?
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] = [:]
    /// Character ranges styled with `cachedElements`.
    private(set) var highlightedRanges = IndexSet()
    private var isHighlighting = false
    private var idlePassScheduled = false
    private var idlePassDidHighlight = false
    /// The idle pass doesn't run before this date.
    var idleStartDate = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    public init(textView: NSTextView? = nil) {
        self.textView = textView
        if textView != nil { readClearTextStylesFromTextView() }
    }

    // MARK: - Spans

    /// Highlights with the document model's spans for the current text.
    func update(_ elements: HighlightElements) {
        if isActive {
            setElements(elements)
        } else {
            cachedElements = elements
            highlightedRanges = IndexSet()
        }
    }

    public func highlightNow() {
        highlightedRanges = IndexSet()
        highlightVisibleRange()
    }

    private func setElements(_ elements: HighlightElements) {
        cachedElements = elements
        highlightedRanges = IndexSet()
        highlightVisibleRange()
    }

    // MARK: - Highlighting

    private func clearFontTraits(for current: NSFontTraitMask) -> NSFontTraitMask {
        let opposites: [(NSFontTraitMask, NSFontTraitMask)] = [
            (.unitalicFontMask, .italicFontMask), (.italicFontMask, .unitalicFontMask),
            (.boldFontMask, .unboldFontMask), (.unboldFontMask, .boldFontMask),
            (.expandedFontMask, .condensedFontMask),
            (.condensedFontMask, .expandedFontMask),
        ]
        var traits: NSFontTraitMask = []
        for (trait, opposite) in opposites where !current.contains(trait) {
            traits.insert(opposite)
        }
        return traits
    }

    private func clearHighlighting(in range: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        storage.applyFontTraits(clearFontTraitMask, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.removeAttribute(.link, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        if resetTypingAttributes,
           let paragraph = defaultTypingAttributes[.paragraphStyle] {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        if let defaultTextColor {
            storage.addAttribute(.foregroundColor, value: defaultTextColor, range: range)
        } else {
            storage.removeAttribute(.foregroundColor, range: range)
        }
        let size = defaultTextSize
        let baseFont = defaultTypingAttributes[.font] as? NSFont
        storage.enumerateAttribute(.font, in: range,
                                   options: .longestEffectiveRangeNotRequired) {
            value, subrange, _ in
            guard let font = value as? NSFont else { return }
            var converted = font
            if let baseFont, font.familyName != baseFont.familyName {
                converted = NSFontManager.shared.convert(
                    converted, toFace: baseFont.fontName) ?? converted
            }
            if converted.pointSize != size {
                converted = NSFontManager.shared.convert(converted, toSize: size)
            }
            if converted != font {
                storage.addAttribute(.font, value: converted, range: subrange)
            }
        }
    }

    public func readClearTextStylesFromTextView() {
        guard let textView else { return }
        let font = textView.font
        clearFontTraitMask = clearFontTraits(
            for: font.map { NSFontManager.shared.traits(of: $0) } ?? [])
        defaultTextSize = font?.pointSize ?? NSFont.systemFontSize
        defaultTextColor = textView.textColor

        var attrs: [NSAttributedString.Key: Any] = [:]
        if let bg = textView.backgroundColor as NSColor? { attrs[.backgroundColor] = bg }
        if let fg = textView.textColor { attrs[.foregroundColor] = fg }
        if let font { attrs[.font] = font }
        if let paragraph = textView.defaultParagraphStyle { attrs[.paragraphStyle] = paragraph }
        defaultTypingAttributes = attrs
    }

    private func applyHighlighting(_ elements: HighlightElements, in range: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        let rangeEnd = NSMaxRange(range)
        storage.beginEditing()
        defer { storage.endEditing() }
        clearHighlighting(in: range)

        let sourceLength = storage.length
        let linkTypes = [HighlightElement.link, .autoLinkURL, .autoLinkEmail].map(\.rawValue)
        for style in styles {
            guard style.elementType < elements.spans.count else { continue }
            for span in elements.spans[style.elementType] {
                // Ignore empty elements and ones that end before our range.
                if span.end <= span.pos || span.end <= range.location { continue }
                // Elements are ordered by pos; stop at the first past our range.
                if span.pos >= rangeEnd { break }

                let pos = min(max(span.pos, 0), sourceLength)
                var len = span.end - span.pos
                if pos + len > sourceLength { len = sourceLength - pos }
                let hlRange = NSRange(location: pos, length: len)

                if makeLinksClickable, linkTypes.contains(style.elementType),
                   var address = span.address {
                    if style.elementType == HighlightElement.autoLinkEmail.rawValue,
                       !address.hasPrefix("mailto:") {
                        address = "mailto:" + address
                    }
                    storage.addAttribute(.link, value: address, range: hlRange)
                }

                if style.fontName != nil || style.fontSize != nil {
                    let manager = NSFontManager.shared
                    storage.enumerateAttribute(
                        .font, in: hlRange, options: .longestEffectiveRangeNotRequired
                    ) { value, subrange, _ in
                        guard var font = value as? NSFont else { return }
                        if let size = style.fontSize, size != font.pointSize {
                            font = manager.convert(font, toSize: size)
                        }
                        if let name = style.fontName, name != font.fontName {
                            font = manager.convert(font, toFace: name) ?? font
                        }
                        storage.addAttribute(.font, value: font, range: subrange)
                    }
                }
                storage.addAttributes(style.attributesToAdd, range: hlRange)
                if !style.fontTraitsToAdd.isEmpty {
                    storage.applyFontTraits(style.fontTraitsToAdd, range: hlRange)
                }
            }
        }
    }

    /// Screens of text past each edge of the visible area that are
    /// highlighted ahead of scrolling, so text is styled before it shows.
    static let overscanScreens: CGFloat = 1
    /// Characters per chunk, and time per main queue turn, for highlighting
    /// the rest of the document after the visible part.
    static let idleChunkLength = 8_192
    static let idleTimeBudget: TimeInterval = 0.004

    /// Highlights what's visible, plus the overscan, that isn't highlighted
    /// yet, then schedules highlighting the rest of the document.
    func highlightVisibleRange() {
        guard let textView, cachedElements != nil, !isHighlighting else { return }
        guard let range = overscannedRange(of: textView) else {
            scheduleIdlePass()
            return
        }
        let missing = IndexSet(integersIn: Range(range)!)
            .subtracting(highlightedRanges)
        highlight(missing.rangeView.map { NSRange($0) })
        if resetTypingAttributes {
            textView.typingAttributes = defaultTypingAttributes
        }
        finishIdlePassIfDone()
        scheduleIdlePass()
    }

    /// The visible text grown by the overscan, in whole paragraphs, or nil
    /// when nothing is visible.
    private func overscannedRange(of textView: NSTextView) -> NSRange? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return nil }
        let visibleRect = textView.enclosingScrollView?.contentView.documentVisibleRect
            ?? textView.visibleRect
        // A hidden editor shows nothing (and an empty rect would select
        // every glyph).
        guard !visibleRect.isEmpty else { return nil }
        let margin = visibleRect.height * Self.overscanScreens
        var rect = visibleRect.insetBy(dx: 0, dy: -margin)
        rect.origin.y -= textView.textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)
        let string = textView.string as NSString
        let clamped = NSIntersectionRange(charRange,
                                          NSRange(location: 0, length: string.length))
        return string.paragraphRange(for: clamped)
    }

    /// Highlights ranges in one storage edit, keeping the visible text in
    /// place when styles above it change line heights (themes can set font
    /// sizes, and NSScrollView doesn't anchor its content).
    private func highlight(_ ranges: [NSRange]) {
        guard let textView, let storage = textView.textStorage,
              let cachedElements, !ranges.isEmpty
        else { return }
        isHighlighting = true
        defer { isHighlighting = false }
        let anchor = visibleAnchor(of: textView)
        storage.beginEditing()
        for range in ranges {
            applyHighlighting(cachedElements, in: range)
            if let bounds = Range(range) { highlightedRanges.insert(integersIn: bounds) }
        }
        storage.endEditing()
        guard let anchor, ranges.contains(where: { $0.location < anchor.character }),
              let scrollView = textView.enclosingScrollView,
              let y = lineTop(of: anchor.character, in: textView)
        else { return }
        let delta = y - anchor.y
        guard abs(delta) >= 0.5 else { return }
        let clipView = scrollView.contentView
        let origin = NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY + delta)
        // The text view resizes itself once the text below is laid out
        // again; until then it may be too short to scroll that far.
        let height = origin.y + clipView.bounds.height
        if textView.frame.height < height {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: height))
        }
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The first visible character and the top of its line.
    private func visibleAnchor(of textView: NSTextView) -> (character: Int, y: CGFloat)? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let clipView = textView.enclosingScrollView?.contentView,
              clipView.bounds.minY > 0
        else { return nil }
        let point = NSPoint(x: 0, y: clipView.bounds.minY - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard let y = lineTop(of: character, in: textView) else { return nil }
        return (character, y)
    }

    private func lineTop(of character: Int, in textView: NSTextView) -> CGFloat? {
        guard let layoutManager = textView.layoutManager,
              character < (textView.textStorage?.length ?? 0)
        else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    // MARK: - Idle highlighting

    /// Highlights the rest of the document a little at a time, nearest the
    /// visible text first (below it, then above it), so that scrolling
    /// finds it already styled.
    private func scheduleIdlePass() {
        guard !idlePassScheduled,
              highlightedRanges.count < textView?.textStorage?.length ?? 0
        else { return }
        idlePassScheduled = true
        let delay = max(0, idleStartDate.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idlePassScheduled = false
                guard self.isActive else { return }
                // Edits meanwhile pushed the start back.
                if self.idleStartDate > Date() {
                    self.scheduleIdlePass()
                } else {
                    self.runIdlePass()
                }
            }
        }
    }

    private func runIdlePass() {
        guard let textView, cachedElements != nil, !isHighlighting else { return }
        let visibleLocation = overscannedRange(of: textView)?.location ?? 0
        let string = textView.string as NSString
        var missing = IndexSet(integersIn: 0..<string.length)
            .subtracting(highlightedRanges)
        let deadline = Date().addingTimeInterval(Self.idleTimeBudget)
        isInIdlePass = true
        while Date() < deadline,
              let chunk = Self.nextChunk(of: missing, after: visibleLocation, in: string) {
            highlight([chunk])
            missing.remove(integersIn: Range(chunk)!)
            idlePassDidHighlight = true
        }
        isInIdlePass = false
        finishIdlePassIfDone()
        scheduleIdlePass()
    }

    /// Reports that the document is fully styled, if the idle pass styled
    /// part of it (scrolling may style the last of it).
    private func finishIdlePassIfDone() {
        guard idlePassDidHighlight,
              highlightedRanges.count >= textView?.textStorage?.length ?? 0
        else { return }
        idlePassDidHighlight = false
        onIdlePassFinished?()
    }

    /// The next unhighlighted chunk: the first one at or after `location`,
    /// else the last one before it, in whole paragraphs.
    static func nextChunk(of missing: IndexSet, after location: Int,
                          in string: NSString) -> NSRange? {
        if let range = missing.rangeView.first(where: { $0.upperBound > location }) {
            let lower = max(range.lowerBound, location)
            let upper = min(range.upperBound, lower + idleChunkLength)
            let paragraph = string.paragraphRange(for: NSRange(location: upper == 0 ? 0 : upper - 1,
                                                               length: 0))
            return NSRange(location: lower,
                           length: min(NSMaxRange(paragraph), range.upperBound) - lower)
        }
        if let range = missing.rangeView.last {
            let upper = range.upperBound
            let lower = max(range.lowerBound, upper - idleChunkLength)
            let paragraph = string.paragraphRange(for: NSRange(location: lower, length: 0))
            let start = max(paragraph.location, range.lowerBound)
            return NSRange(location: start, length: upper - start)
        }
        return nil
    }

    public func clearHighlighting() {
        highlightedRanges = IndexSet()
        guard let length = textView?.textStorage?.length else { return }
        clearHighlighting(in: NSRange(location: 0, length: length))
    }

    // MARK: - Styles

    private func applyStyleDependencies() {
        guard let textView else { return }
        // Make link styles match the styles set for LINK elements.
        if let style = styles.first(where: { $0.elementType == HighlightElement.link.rawValue }) {
            var attrs = style.attributesToAdd
            attrs[.cursor] = NSCursor.pointingHand
            textView.linkTextAttributes = attrs
        }
    }

    private static let defaultSelectedTextAttributes: [NSAttributedString.Key: Any] =
        NSTextView(frame: NSRect(x: 1, y: 1, width: 1, height: 1))
            .selectedTextAttributes

    /// Resets to default styles.
    public func resetStyles() {
        styles = HighlightingStyle.defaultStyles()
    }

    /// Applies a PEG Markdown Highlight stylesheet (`.style` file contents).
    ///
    /// - Returns: Error messages from parsing the stylesheet.
    @discardableResult
    public func applyStyles(fromStylesheet stylesheet: String) -> [String] {
        let theme = ThemeStyle(parsing: stylesheet)
        let baseFont = (defaultTypingAttributes[.font] as? NSFont) ?? textView?.font
        styles = theme.elements.compactMap { HighlightingStyle($0, baseFont: baseFont) }

        if let textView {
            clearHighlighting()

            for attribute in theme.editor {
                switch attribute.value {
                case .backgroundColor(let color):
                    textView.backgroundColor = HighlightingStyle.color(color)
                case .foregroundColor(let color):
                    textView.textColor = HighlightingStyle.color(color)
                case .caretColor(let color):
                    textView.insertionPointColor = HighlightingStyle.color(color)
                default:
                    break
                }
            }

            var selection = Self.defaultSelectedTextAttributes
            for attribute in theme.selection {
                switch attribute.value {
                case .backgroundColor(let color):
                    selection[.backgroundColor] = HighlightingStyle.color(color)
                case .foregroundColor(let color):
                    selection[.foregroundColor] = HighlightingStyle.color(color)
                case .fontStyle(_, _, let underlined):
                    if underlined {
                        selection[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                default:
                    break
                }
            }
            textView.selectedTextAttributes = selection
            readClearTextStylesFromTextView()
        }
        highlightNow()
        return theme.errors.map(\.description)
    }

    // MARK: - Activation

    public func activate() {
        guard let textView else { return }
        applyStyleDependencies()
        isActive = true
        if cachedElements != nil { highlightVisibleRange() }

        let center = NotificationCenter.default
        // Edits move the text, so what was highlighted no longer lines up.
        // Posted synchronously, while `editedMask` is valid, and for
        // programmatic changes too.
        observers.append(center.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage, queue: nil
        ) { [weak self] note in
            let edited = (note.object as? NSTextStorage)?.editedMask
                .contains(.editedCharacters) ?? false
            guard edited else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.highlightedRanges = IndexSet()
                // Restyle only around the visible text while the user is
                // typing; the rest of the document waits for a pause.
                self.idleStartDate = Date().addingTimeInterval(self.idleDelayAfterEdit)
            }
        })
        if let clipView = textView.enclosingScrollView?.contentView {
            // Scrolling or resizing reveals text outside the highlighted range.
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification,
                         NSView.frameDidChangeNotification] {
                observers.append(center.addObserver(
                    forName: name, object: clipView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.textViewDidScroll() }
                })
            }
        }
    }

    public func deactivate() {
        guard isActive else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        // The spans are kept: they're the model's, for the current text,
        // and restyle the editor when it's activated again.
        highlightedRanges = IndexSet()
        isActive = false
    }

    private func textViewDidScroll() {
        // Style newly revealed text right away, before it's drawn; mostly
        // it's already styled by the overscan or the idle pass.
        highlightVisibleRange()
    }
}

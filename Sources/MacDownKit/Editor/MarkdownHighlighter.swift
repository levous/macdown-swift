//
//  MarkdownHighlighter.swift
//  MacDown
//
//  Swift port of HGMarkdownHighlighter and HGMarkdownHighlightingStyle from
//  PEG Markdown Highlight (Copyright 2011-2013 Ali Rantakari, MIT/GPL2+).
//  The PEG parser and stylesheet parser remain in C (CPegMarkdown).
//

import AppKit
import CPegMarkdown

/// A single highlighted span, in UTF-16 offsets.
struct HighlightSpan: Sendable {
    var pos: Int
    var end: Int
    var address: String?
}

/// Parsed spans, indexed by `pmh_element_type` raw value.
struct HighlightElements: Sendable {
    var spans: [[HighlightSpan]]

    static func parse(_ markdown: String, extensions: Int32) -> HighlightElements {
        var result: UnsafeMutablePointer<UnsafeMutablePointer<pmh_element>?>?
        markdown.withCString { cString in
            pmh_markdown_to_elements(UnsafeMutablePointer(mutating: cString),
                                     extensions, &result)
        }
        guard let result else {
            return HighlightElements(spans: Array(repeating: [],
                                                  count: Int(pmh_NUM_LANG_TYPES)))
        }
        pmh_sort_elements_by_pos(result)
        defer { pmh_free_elements(result) }

        // The parser reports Unicode code point offsets; NSString uses UTF-16.
        // Gather indexes of surrogate pairs to convert.
        let utf16 = Array(markdown.utf16)
        var surrogatePairIndexes: [Int] = []
        for (i, unit) in utf16.enumerated() where UTF16.isLeadSurrogate(unit) {
            surrogatePairIndexes.append(i)
        }

        var spans: [[HighlightSpan]] = []
        for langType in 0..<Int(pmh_NUM_LANG_TYPES) {
            var list: [HighlightSpan] = []
            var cursor = result[langType]
            while let element = cursor {
                var pos = Int(element.pointee.pos)
                var end = Int(element.pointee.end)
                if !surrogatePairIndexes.isEmpty {
                    var posShift = 0, endShift = 0, passedPairs = 0
                    for pairIndex in surrogatePairIndexes {
                        let u = pairIndex - passedPairs
                        if u < pos {
                            posShift += 1
                            endShift += 1
                        } else if u < end {
                            endShift += 1
                        } else {
                            break
                        }
                        passedPairs += 1
                    }
                    pos += posShift
                    end += endShift
                }
                let address = element.pointee.address.map { String(cString: $0) }
                list.append(HighlightSpan(pos: pos, end: end, address: address))
                cursor = element.pointee.next
            }
            spans.append(list)
        }
        return HighlightElements(spans: spans)
    }
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

        func t(_ type: pmh_element_type) -> Int { Int(type.rawValue) }
        var styles: [HighlightingStyle] = []
        for h in [pmh_H1, pmh_H2, pmh_H3, pmh_H4, pmh_H5, pmh_H6] {
            styles.append(.init(elementType: t(h), foreground: dark(blue),
                                background: light(blue), traits: .boldFontMask))
        }
        styles += [
            .init(elementType: t(pmh_HRULE), foreground: darkGray, background: lightGray),
            .init(elementType: t(pmh_LIST_BULLET), foreground: dark(magenta)),
            .init(elementType: t(pmh_LIST_ENUMERATOR), foreground: dark(magenta)),
            .init(elementType: t(pmh_LINK), foreground: dark(cyan), background: light(cyan)),
            .init(elementType: t(pmh_AUTO_LINK_URL), foreground: dark(cyan), background: light(cyan)),
            .init(elementType: t(pmh_AUTO_LINK_EMAIL), foreground: dark(cyan), background: light(cyan)),
            .init(elementType: t(pmh_IMAGE), foreground: dark(magenta), background: light(magenta)),
            .init(elementType: t(pmh_REFERENCE), foreground: dim(red)),
            .init(elementType: t(pmh_CODE), foreground: dark(green), background: light(green)),
            .init(elementType: t(pmh_EMPH), foreground: dark(yellow), traits: .italicFontMask),
            .init(elementType: t(pmh_STRONG), foreground: dark(magenta), traits: .boldFontMask),
            .init(elementType: t(pmh_HTML_ENTITY), foreground: medGray),
            .init(elementType: t(pmh_COMMENT), foreground: medGray),
            .init(elementType: t(pmh_VERBATIM), foreground: dark(green), background: light(green)),
            .init(elementType: t(pmh_BLOCKQUOTE), foreground: dark(magenta),
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
    public var extensions: Int32 = Int32(pmh_EXT_NONE.rawValue)
    public var waitInterval: TimeInterval = 0
    public var resetTypingAttributes = true
    public var makeLinksClickable = false
    public private(set) var isActive = false
    /// Spans come from elsewhere (the swift-markdown document model, via
    /// `update(_:)`) instead of the highlighter's own PEG parse.
    public var usesExternalElements = false

    var styles: [HighlightingStyle] = HighlightingStyle.defaultStyles() {
        didSet { applyStyleDependencies() }
    }

    private var cachedElements: HighlightElements?
    private var clearFontTraitMask: NSFontTraitMask = []
    private var defaultTextSize: CGFloat = 0
    private var defaultTextColor: NSColor?
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] = [:]
    private var parseGeneration = 0
    private var scrollWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    public init(textView: NSTextView? = nil) {
        self.textView = textView
        if textView != nil { readClearTextStylesFromTextView() }
    }

    // MARK: - Parsing

    func requestParsing() {
        guard let textView, !usesExternalElements else { return }
        parseGeneration += 1
        let generation = parseGeneration
        let markdown = textView.string
        let extensions = self.extensions
        Task { [weak self] in
            let elements = await Task.detached(priority: .userInitiated) {
                HighlightElements.parse(markdown, extensions: extensions)
            }.value
            guard let self, self.isActive, generation == self.parseGeneration
            else { return }
            self.cachedElements = elements
            self.applyVisibleRangeHighlighting()
        }
    }

    public func parseAndHighlightNow() {
        requestParsing()
    }

    /// Highlights with spans parsed elsewhere, for the current text.
    func update(_ elements: HighlightElements) {
        parseGeneration += 1    // Any PEG parse in flight is stale.
        cachedElements = elements
        if isActive { applyVisibleRangeHighlighting() }
    }

    public func highlightNow() {
        applyVisibleRangeHighlighting()
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
        let linkTypes = [pmh_LINK, pmh_AUTO_LINK_URL, pmh_AUTO_LINK_EMAIL]
            .map { Int($0.rawValue) }
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
                    if style.elementType == Int(pmh_AUTO_LINK_EMAIL.rawValue),
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

    func applyVisibleRangeHighlighting() {
        guard let textView, let cachedElements,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }
        let visibleRect = textView.enclosingScrollView?.contentView.documentVisibleRect
            ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect,
                                                  in: container)
        var charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)
        let length = textView.textStorage?.length ?? 0
        charRange = NSIntersectionRange(charRange, NSRange(location: 0, length: length))
        applyHighlighting(cachedElements, in: charRange)
        if resetTypingAttributes {
            textView.typingAttributes = defaultTypingAttributes
        }
    }

    public func clearHighlighting() {
        guard let length = textView?.textStorage?.length else { return }
        clearHighlighting(in: NSRange(location: 0, length: length))
    }

    // MARK: - Styles

    private func applyStyleDependencies() {
        guard let textView else { return }
        // Make link styles match the styles set for LINK elements.
        if let style = styles.first(where: { $0.elementType == Int(pmh_LINK.rawValue) }) {
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
        requestParsing()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.textDidChange() }
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
        scrollWorkItem?.cancel()
        cachedElements = nil
        parseGeneration += 1
        isActive = false
    }

    private func textDidChange() {
        if waitInterval <= 0 {
            requestParsing()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + waitInterval) {
                [weak self] in
                MainActor.assumeIsolated { self?.requestParsing() }
            }
        }
    }

    private func textViewDidScroll() {
        guard cachedElements != nil else { return }
        // No need to over render; wait a little.
        scrollWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyVisibleRangeHighlighting() }
        }
        scrollWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }
}

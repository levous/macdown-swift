//
//  CoreTests.swift
//  MacDown
//
//  Ported from the original MacDownTests (XCTest) to Swift Testing.
//

import AppKit
import Foundation
import Testing
@testable import MacDownKit

private func fixture(_ name: String, _ ext: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: ext,
                      subdirectory: "Resources")!
}

@Suite struct StringLookupTests {
    @Test func previousNewline() {
        var string: NSString = "123\n45"
        for i in 0..<4 { #expect(string.locationOfFirstNewline(before: i) == -1) }
        for i in 4..<string.length { #expect(string.locationOfFirstNewline(before: i) == 3) }
        #expect(string.locationOfFirstNewline(before: 10000) == 3)

        string = "\n1234"
        #expect(string.locationOfFirstNewline(before: 0) == -1)
        for i in 1..<string.length { #expect(string.locationOfFirstNewline(before: i) == 0) }

        string = "1234\n"
        #expect(string.locationOfFirstNewline(before: string.length) == 4)

        string = "1234"
        for i in 0..<6 { #expect(string.locationOfFirstNewline(before: i) == -1) }
    }

    @Test func nextNewline() {
        var string: NSString = "123\n45"
        for i in 0..<3 { #expect(string.locationOfFirstNewline(after: i) == 3) }
        for i in 3..<6 { #expect(string.locationOfFirstNewline(after: i) == 6) }
        #expect(string.locationOfFirstNewline(after: 10000) == string.length)

        string = "1234\n"
        for i in 0..<4 { #expect(string.locationOfFirstNewline(after: i) == 4) }
        #expect(string.locationOfFirstNewline(after: 4) == 5)
    }

    @Test func firstNonWhitespace() {
        var string: NSString = "12345"
        for i in 0..<string.length {
            #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: i) == 0)
        }
        string = "  12345"
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 0) == 0)
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 1) == 1)
        for i in 2..<string.length {
            #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: i) == 2)
        }
        string = "\n12345"
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 0) == 0)
        for i in 1..<string.length {
            #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: i) == 1)
        }
        string = "\n  12345"
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 0) == 0)
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 1) == 1)
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 2) == 2)
        for i in 3..<string.length {
            #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: i) == 3)
        }
        string = "\n\n 12"
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 1) == 1)
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 4) == 3)
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 9) == 3)
        string = "\n\n1\n"
        #expect(string.locationOfFirstNonWhitespaceCharacterInLine(before: 9) == 4)
    }

    @Test func titleString() {
        #expect("# 123".titleString == "123")
        #expect("#123".titleString == nil)
        #expect("\n# 123\n".titleString == "123")
        #expect("## 123\n# 456\n789".titleString == "456")
        #expect("456\n## 123\n\n789\n".titleString == "123")
        #expect("123\n456\n".titleString == nil)
        #expect("####### 123\n".titleString == nil)
    }

    @Test func hasExtension() {
        #expect("foo.css".hasExtension("css"))
        #expect("foo.min.css".hasExtension("css"))
        #expect(!"foo.csss".hasExtension("css"))
    }

    @Test func frontMatter() {
        let text = "---\ntitle: Hello\ntags: [a, b]\n---\n# Body"
        let (object, offset) = text.frontMatter()
        #expect(object?["title"] == .string("Hello"))
        #expect(object?["tags"] == .sequence([.string("a"), .string("b")]))
        #expect(text.ns.substring(from: offset) == "\n# Body")

        let none = "# No front matter".frontMatter()
        #expect(none.object == nil)
        #expect(none.offset == 0)
    }
}

@Suite struct AssetTests {
    @Test func defaultAssetTypes() {
        #expect(Asset.css(nil).typeName == "text/css")
        #expect(Asset.javaScript(nil).typeName == "text/javascript")
    }

    @Test func assetNone() {
        #expect(Asset.javaScript(nil).html(for: .none) == nil)
    }

    @Test func embedded() {
        let url = fixture("test", "txt")
        let script = Asset(url: url, typeName: "text/plain", kind: .script)
        #expect(script.html(for: .embedded)
                == "<script type=\"text/plain\">\nFoobar\n</script>")
    }

    @Test func fullLink() {
        let url = fixture("test", "txt")
        let script = Asset(url: url, typeName: "text/plain", kind: .script)
        #expect(script.html(for: .fullLink)
                == "<script type=\"text/plain\" src=\"\(url.absoluteString)\"></script>")
    }

    @Test func css() {
        let url = fixture("test", "css")
        let ss = Asset.css(url)
        #expect(ss.html(for: .none) == nil)
        #expect(ss.html(for: .embedded)
                == "<style type=\"text/css\">\nbody { font-size: 15px; }\n</style>")
        #expect(ss.html(for: .fullLink)
                == "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(url.absoluteString)\">")
    }

    @Test func javaScript() {
        let url = fixture("test", "js")
        let script = Asset.javaScript(url)
        #expect(script.html(for: .none) == nil)
        #expect(script.html(for: .embedded)
                == "<script type=\"text/javascript\">\nconsole.log('test');\n</script>")
        #expect(script.html(for: .fullLink)
                == "<script type=\"text/javascript\" src=\"\(url.absoluteString)\"></script>")
    }

    @Test func forcedEmbedded() {
        let url = fixture("test", "js")
        let script = Asset.embeddedScript(url, type: AssetType.mathJaxConfig)
        let tag = "<script type=\"text/x-mathjax-config\">\nconsole.log('test');\n</script>"
        #expect(script.html(for: .none) == nil)
        #expect(script.html(for: .embedded) == tag)
        #expect(script.html(for: .fullLink) == tag)
    }
}

@Suite struct HTMLTabularizeTests {
    @Test func string() {
        #expect(YAMLValue.string("Foobar").htmlTable == "Foobar")
        #expect(YAMLValue.string("<b>").htmlTable == "&lt;b&gt;")
    }

    @Test func array() {
        let array = YAMLValue.sequence([.string("Foo"), .string("42"),
                                        .string("2.71828"), .null])
        #expect(array.htmlTable == "<table><tbody><tr><td>Foo</td><td>42</td>"
                + "<td>2.71828</td><td></td></tr></tbody></table>")
    }

    @Test func dictionary() {
        let dict = YAMLValue.mapping([
            (key: .string("Info"), value: .sequence([.string("Moo")])),
            (key: .string("Foo"), value: .string("Bar")),
        ])
        #expect(dict.htmlTable == "<table><thead><tr><th>Info</th><th>Foo</th>"
                + "</tr></thead><tbody><tr><td><table><tbody><tr><td>Moo</td>"
                + "</tr></tbody></table></td><td>Bar</td></tr></tbody></table>")
    }
}

@Suite struct ColorTests {
    @Test func hexStringToColor() throws {
        let color = try #require(NSColor(htmlName: "#123456"))
        #expect(abs(color.redComponent - 0x12 / 255.0) < 0.0001)
        #expect(abs(color.greenComponent - 0x34 / 255.0) < 0.0001)
        #expect(abs(color.blueComponent - 0x56 / 255.0) < 0.0001)
    }

    @Test func colorNameToColor() throws {
        let color = try #require(NSColor(htmlName: "red"))
        #expect(color.redComponent == 1.0)
        #expect(color.greenComponent == 0.0)
        #expect(color.blueComponent == 0.0)
    }

    @Test func rgbToColor() throws {
        let color = try #require(NSColor(htmlName: "rgb(255, 0, 0)"))
        #expect(color.redComponent == 1.0)
    }
}

@Suite struct UtilityTests {
    @Test func getObjectFromJavaScript() {
        let code = "var obj = { foo: 'bar', baz: 42 }; var arr = [0, null, {}];"
        let obj = MPGetObjectFromJavaScript(code, "obj") as? NSDictionary
        #expect(obj == ["foo": "bar", "baz": 42] as NSDictionary)
        let arr = MPGetObjectFromJavaScript(code, "arr") as? NSArray
        #expect(arr == [0, NSNull(), [String: Any]()] as NSArray)
    }

    @Test func template() {
        let t = HTMLTemplate("<a>{{{ x }}}</a>{{#each list}}[{{{this}}}]{{/each}}{{ y }}")
        #expect(t.render(["x": .string("<b>"), "list": .list(["1", "2"]),
                          "y": .string("<i>")])
                == "<a><b></a>[1][2]&lt;i&gt;")
    }
}

@Suite @MainActor struct PreferencesTests {
    @Test func font() throws {
        let suite = "MacDownTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        // Fresh install defaults.
        #expect(preferences.extensionTables)
        #expect(preferences.editorStyleName == "Tomorrow+")
        #expect(preferences.htmlTemplateName == "Default")

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        preferences.editorBaseFont = font
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.editorBaseFont == font)
    }
}

@Suite struct RendererTests {
    func parse(_ text: String, ext: UInt32 = 0x7 | (1 << 4), renderer: UInt32 = 0,
               toc: Bool = false, frontMatter: Bool = false) -> ParseResult {
        MarkdownParser.parse(text, settings: ParseSettings(
            extensionFlags: ext, rendererFlags: renderer,
            rendersTOC: toc, detectsFrontMatter: frontMatter))
    }

    @Test func basic() {
        let result = parse("# Hello\n\n*world*")
        #expect(result.body.contains("<h1 id=\"toc_0\">Hello</h1>"))
        #expect(result.body.contains("<em>world</em>"))
    }

    @Test func fencedCodeMapsAliasesAndCollectsLanguages() {
        let result = parse("```js\nvar a = 1;\n```\n\n```c++\nint x;\n```\n")
        #expect(result.body.contains("<code class=\"language-javascript\">var a = 1;</code>"))
        #expect(result.body.contains("<div><pre><code class=\"language-cpp\">"))
        #expect(result.languages.contains("javascript"))
        #expect(result.languages.contains("cpp"))
        // cpp requires c, which requires clike; dependencies come first.
        let c = result.languages.firstIndex(of: "c")!
        let cpp = result.languages.firstIndex(of: "cpp")!
        #expect(c < cpp)
    }

    @Test func noLanguage() {
        let result = parse("```\nplain\n```\n")
        #expect(result.body.contains("<code class=\"language-none\">plain</code>"))
    }

    @Test func taskList() {
        let result = parse("- [ ] todo\n- [x] done\n", renderer: 1 << 4)
        #expect(result.body.contains("<li class=\"task-list-item\"><input type=\"checkbox\"> todo"))
        #expect(result.body.contains("<input type=\"checkbox\" checked> done"))
    }

    @Test func lineNumbersAndInformation() {
        let result = parse("```python:example.py\nprint(1)\n```\n",
                           renderer: (1 << 5) | (1 << 6))
        #expect(result.body.contains(
            "<pre class=\"line-numbers\" data-information=\"example.py\"><code class=\"language-python\">"))
    }

    @Test func tableOfContents() {
        let result = parse("[TOC]\n\n# One\n\n## Two\n", toc: true)
        #expect(result.body.contains("<ul class=\"toc\">"))
        #expect(result.body.contains("<a href=\"#toc_1\">Two</a>"))
        #expect(!result.body.contains("[TOC]"))
    }

    @Test func frontMatter() {
        let result = parse("---\ntitle: Test\n---\nBody", frontMatter: true)
        #expect(result.body.hasPrefix(
            "<table><thead><tr><th>title</th></tr></thead><tbody><tr><td>Test</td></tr></tbody></table>\n"))
        #expect(result.body.contains("<p>Body</p>"))
    }

    @Test func unicode() {
        let result = parse("# 中文 😀\n")
        #expect(result.body.contains("中文 😀"))
    }

    @Test func previewPage() {
        var settings = PageSettings()
        settings.syntaxHighlighting = true
        settings.lineNumbers = true
        let result = parse("```swift\nlet a = 1\n```\n")
        let html = PageBuilder.previewHTML(title: "Doc", result: result,
                                           settings: settings)
        #expect(html.contains("<title>Doc</title>"))
        #expect(html.contains("prism-core.min.js"))
        #expect(html.contains("prism-swift"))
        #expect(html.contains("prism-line-numbers"))
        #expect(html.contains("prism.css"))
    }

    @Test func exportPageIsSelfContained() {
        var settings = PageSettings()
        settings.syntaxHighlighting = true
        let result = parse("```swift\nlet a = 1\n```\n")
        let html = PageBuilder.exportHTML(title: nil, result: result,
                                          settings: settings, withStyles: false,
                                          withHighlighting: true)
        #expect(!html.contains("src=\"file:"))
        #expect(html.contains("<script type=\"text/javascript\">"))
    }
}

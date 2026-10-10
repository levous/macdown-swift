//
//  PrismLanguages.swift
//  MacDownKit
//
//  Code block languages for Prism, shared by both Markdown engines (FR-10):
//  aliases map to Prism's names (`js` → `javascript`), and each language
//  brings the scripts it depends on.
//

import Foundation

/// Collects the Prism languages a document's code blocks use, with their
/// dependencies first.
final class LanguageCollector {
    private(set) var languages: [String] = []

    func add(_ lang: String) {
        // Move language to root of dependencies.
        languages.removeAll { $0 == lang }
        languages.insert(lang, at: 0)

        // Add dependencies of this language.
        let require = (PrismLanguages.languages[lang] as? [String: Any])?["require"]
        if let require = require as? String {
            add(require)
        } else if let require = require as? [String] {
            require.forEach(add)
        } else if let require {
            NSLog("Unknown Prism language requirement %@ dropped for unknown format",
                  String(describing: require))
        }
    }
}

/// Language metadata read from `syntax_highlighting.json` and Prism's
/// `components.js`.
enum PrismLanguages {
    static let aliases: [String: String] = {
        guard let url = MPPaths.resourceBundle.url(
            forResource: "syntax_highlighting", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let info = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return [:] }
        return info["aliases"] as? [String: String] ?? [:]
    }()

    nonisolated(unsafe) static let languages: [String: Any] = {
        guard let url = MPPaths.resourceBundle.url(
            forResource: "components", withExtension: "js", subdirectory: "Prism")
        else { return [:] }
        let code = MPPaths.readFile(at: url)
        let components = MPGetObjectFromJavaScript(code, "components") as? [String: Any]
        return components?["languages"] as? [String: Any] ?? [:]
    }()
}

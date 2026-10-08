//
//  Utilities.swift
//  MacDown
//
//  Ported from MPUtilities.m.
//

import Foundation
import JavaScriptCore

public enum MPPaths {
    public static let stylesDirectoryName = "Styles"
    public static let styleFileExtension = "css"
    public static let themesDirectoryName = "Themes"
    public static let themeFileExtension = "style"
    public static let plugInsDirectoryName = "PlugIns"
    public static let plugInFileExtension = "plugin"

    /// The bundle containing MacDown's built-in resources (styles, themes,
    /// Prism, templates, …).
    public static var resourceBundle: Bundle { Bundle.module }

    /// Override for the data root directory. Used by tests.
    nonisolated(unsafe) public static var dataRootOverride: URL?

    /// `~/Library/Application Support/MacDown`.
    public static var dataRootDirectory: URL {
        if let override = dataRootOverride {
            return override
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent(MacDownGlobalsBridge.dataDirectoryName,
                                           isDirectory: true)
    }

    public static func dataDirectory(_ relativePath: String? = nil) -> URL {
        guard let relativePath else { return dataRootDirectory }
        return dataRootDirectory.appendingPathComponent(relativePath,
                                                        isDirectory: true)
    }

    public static func pathToDataFile(_ name: String, in directory: String) -> URL {
        dataDirectory(directory).appendingPathComponent(name)
    }

    /// Lists names (without extension) of files in a data directory that
    /// have the given extension.
    public static func listEntries(inDirectory dirName: String,
                                   withExtension ext: String) -> [String] {
        let dir = dataDirectory(dirName)
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.compactMap { name -> String? in
            let path = dir.appendingPathComponent(name).path
            guard (name as NSString).pathExtension == ext,
                  manager.fileExists(atPath: path)
            else { return nil }
            return (name as NSString).deletingPathExtension
        }
    }

    public static func stylePath(forName name: String?) -> URL? {
        guard var name, !name.isEmpty else { return nil }
        if (name as NSString).pathExtension != styleFileExtension {
            name = (name as NSString).appendingPathExtension(styleFileExtension)!
        }
        return pathToDataFile(name, in: stylesDirectoryName)
    }

    public static func themePath(forName name: String) -> URL {
        var name = name
        if (name as NSString).pathExtension != themeFileExtension {
            name = (name as NSString).appendingPathExtension(themeFileExtension)!
        }
        return pathToDataFile(name, in: themesDirectoryName)
    }

    /// URL of a Prism highlighting theme. Falls back to the default theme.
    public static func highlightingThemeURL(forName name: String?) -> URL? {
        var file = "prism-\((name ?? "").lowercased())"
        if (file as NSString).pathExtension == "css" {
            file = (file as NSString).deletingPathExtension
        }
        let bundle = resourceBundle
        if let url = bundle.url(forResource: file, withExtension: "css",
                                subdirectory: "Prism/themes") {
            return url
        }
        return bundle.url(forResource: "prism", withExtension: "css",
                          subdirectory: "Prism/themes")
    }

    /// Names of bundled Prism themes, capitalized, e.g. "Okaidia".
    public static func highlightingThemeNames() -> [String] {
        let urls = resourceBundle.urls(forResourcesWithExtension: "css",
                                       subdirectory: "Prism/themes") ?? []
        return urls.map(\.lastPathComponent)
            .filter { $0.count > 10 }
            .map { name -> String in
                let start = name.index(name.startIndex, offsetBy: 6)
                let end = name.index(name.endIndex, offsetBy: -4)
                return String(name[start..<end]).capitalized
            }
            .sorted()
    }

    public static func readFile(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// Name of the application data directory. Kept as "MacDown" so styles and
/// themes are shared with the original application.
enum MacDownGlobalsBridge {
    static let dataDirectoryName = "MacDown"
}

public enum MPCharacters {
    public static func isWhitespace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    public static func isNewline(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }

    public static func stringIsNewline(_ s: String) -> Bool {
        let ns = s as NSString
        guard ns.length == 1 else { return false }
        return isNewline(ns.character(at: 0))
    }
}

/// Evaluates JavaScript and returns the value of a global variable converted
/// to Foundation objects (via JSON).
public func MPGetObjectFromJavaScript(_ code: String, _ variableName: String) -> Any? {
    guard !code.isEmpty, let context = JSContext() else { return nil }
    var failed = false
    context.exceptionHandler = { _, _ in failed = true }
    context.evaluateScript(code)
    guard !failed,
          let value = context.objectForKeyedSubscript(variableName),
          let json = context.objectForKeyedSubscript("JSON")?
              .invokeMethod("stringify", withArguments: [value]),
          !failed,
          let string = json.toString(),
          let data = string.data(using: .utf8)
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

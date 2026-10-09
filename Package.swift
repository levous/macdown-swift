// swift-tools-version: 6.4
//
// MacDown (Swift) — core package.
//
// The macOS application target itself lives in project.yml (XcodeGen), and
// depends on the `MacDownKit` library defined here. Everything that can be
// built and tested from the command line lives in this package.

import PackageDescription

let package = Package(
    name: "MacDownCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MacDownKit", targets: ["MacDownKit"]),
        .library(name: "MacDownShared", targets: ["MacDownShared"]),
        .executable(name: "macdown", targets: ["macdown-cmd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // Replaces hoedown and PEG Markdown Highlight
        // (docs/intents/swift-markdown-migration.md). Pinned exactly: its
        // output is compared against the HTML diff harness.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
        // swift-markdown's cmark-gfm, used directly by the footnote spike.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
    ],
    targets: [
        // Hoedown 3.0.7 plus MacDown's renderer patches (task lists, code block
        // information, Prism-compatible code blocks, TOC class).
        .target(
            name: "CHoedown",
            path: "Sources/CHoedown",
            exclude: ["LICENSE"],
            cSettings: [
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),
        // PEG Markdown Highlight. pmh_parser.c is generated from
        // pmh_grammar.leg with greg; see Vendor/README.md.
        .target(
            name: "CPegMarkdown",
            path: "Sources/CPegMarkdown",
            cSettings: [
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),
        // Constants shared by the app and the `macdown` command line utility.
        .target(
            name: "MacDownShared",
            path: "Sources/MacDownShared"
        ),
        .target(
            name: "MacDownKit",
            dependencies: [
                "CHoedown",
                "CPegMarkdown",
                "MacDownShared",
                .product(name: "Yams", package: "Yams"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/MacDownKit",
            resources: [
                .copy("Resources/Styles"),
                .copy("Resources/Themes"),
                .copy("Resources/Templates"),
                .copy("Resources/Extensions"),
                .copy("Resources/MathJax"),
                .copy("Resources/Prism"),
                .copy("Resources/syntax_highlighting.json"),
                .copy("Resources/help.md"),
                .copy("Resources/contribute.md"),
                .process("Resources/Localization"),
            ]
        ),
        .executableTarget(
            name: "macdown-cmd",
            dependencies: ["MacDownShared"],
            path: "Sources/macdown-cmd"
        ),
        .testTarget(
            name: "MacDownKitTests",
            dependencies: [
                "MacDownKit",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Tests/MacDownKitTests",
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

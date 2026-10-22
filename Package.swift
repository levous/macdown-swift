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
        // The Markdown parser (see docs/ARCHITECTURE.md, "Parse with cmark-gfm
        // directly"), pinned exactly: the renderer tests and the paste round
        // trip compare its output byte for byte.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
    ],
    targets: [
        // Constants shared by the app and the `macdown` command line utility.
        .target(
            name: "MacDownShared",
            path: "Sources/MacDownShared"
        ),
        .target(
            name: "MacDownKit",
            dependencies: [
                "MacDownShared",
                .product(name: "Yams", package: "Yams"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
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
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Tests/MacDownKitTests",
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

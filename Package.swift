// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TiantingIM",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TiantingIM", targets: ["TiantingIM"]),
        .library(name: "TiantingIMTesting", targets: ["TiantingIMTesting"]),
    ],
    targets: [
        .target(name: "TiantingIM"),
        .target(name: "TiantingIMTesting", dependencies: ["TiantingIM"]),
        .testTarget(
            name: "TiantingIMTests",
            dependencies: ["TiantingIM", "TiantingIMTesting"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "TiantingIMIntegrationTests",
            dependencies: ["TiantingIM"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

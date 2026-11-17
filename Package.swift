// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Velinshot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VelinshotCore", targets: ["VelinshotCore"]),
        .executable(name: "Velinshot", targets: ["Velinshot"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "VelinshotCore"),
        .executableTarget(name: "Velinshot", dependencies: ["VelinshotCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "VelinshotCoreTests", dependencies: ["VelinshotCore"], exclude: ["README.md"])
    ],
    swiftLanguageVersions: [.v5]
)

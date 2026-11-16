// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Velinshot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VelinshotCore", targets: ["VelinshotCore"]),
        .executable(name: "Velinshot", targets: ["Velinshot"])
    ],
    targets: [
        .target(name: "VelinshotCore"),
        .executableTarget(name: "Velinshot", dependencies: ["VelinshotCore"]),
        .testTarget(name: "VelinshotCoreTests", dependencies: ["VelinshotCore"])
    ],
    swiftLanguageVersions: [.v5]
)

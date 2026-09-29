// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "OmaQuoteMac",
    platforms: [.macOS(.v26)],
    products: [.library(name: "OmaQuoteCore", targets: ["OmaQuoteCore"])],
    targets: [
        .target(name: "OmaQuoteCore", resources: [.copy("Resources")]),
        .executableTarget(name: "OmaQuoteMac", dependencies: ["OmaQuoteCore"]),
        .executableTarget(name: "omaquote", dependencies: ["OmaQuoteCore"]),
        .testTarget(name: "OmaQuoteCoreTests", dependencies: ["OmaQuoteCore"]),
    ]
)

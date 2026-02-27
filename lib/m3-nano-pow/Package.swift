// swift-tools-version: 5.9
// Note: Swift 6 compatibility
import PackageDescription

let package = Package(
    name: "m3-nano-pow",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "NanoPoW",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            resources: [
                .process("Shaders.metal"),
                .process("Default.metallib")
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrKit",
    // iOS 18 to match HerdrTailcat's embedded tailcat xcframework (and HerdrSSH).
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"])
    ],
    dependencies: [
        .package(path: "../HerdrTailcat")
    ],
    targets: [
        .target(
            name: "HerdrKit",
            dependencies: [
                .product(name: "HerdrTailcat", package: "HerdrTailcat")
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit"])
    ],
    // Keep Swift 5 semantics; the bump to tools 6.0 is only for the iOS 18
    // platform literal, not a move to the Swift 6 language mode.
    swiftLanguageModes: [.v5]
)

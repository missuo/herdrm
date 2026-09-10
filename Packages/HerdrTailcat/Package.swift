// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrTailcat",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "HerdrTailcat", targets: ["HerdrTailcat"])
    ],
    targets: [
        // The gomobile-built tailcat (WireGuard/DERP) client. One xcframework
        // serves macOS + iOS, like HerdrSSH's libssh2/OpenSSL artifacts.
        .binaryTarget(
            name: "Tailcat",
            path: "Artifacts/Tailcat.xcframework"
        ),
        .target(
            name: "HerdrTailcat",
            dependencies: ["Tailcat"]
        ),
    ]
)

// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LastideKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LastideKit", targets: ["LastideKit"]),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.1")],
    targets: [
        .target(
            name: "LastideKit",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            exclude: ["Sync/Constraints.md"],
            resources: [.copy("Resources/Demo")]
        ),
        .testTarget(
            name: "LastideKitTests",
            dependencies: ["LastideKit", .product(name: "Crypto", package: "swift-crypto")],
            resources: [.copy("Vectors")]
        ),
    ]
)

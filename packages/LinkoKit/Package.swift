// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinkoKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LinkoKit", targets: ["LinkoKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "LinkoKit",
            dependencies: ["Yams"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "LinkoKitTests",
            dependencies: ["LinkoKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

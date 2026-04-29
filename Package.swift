// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "rtr",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "rtr",
            path: "Sources/rtr",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "rtrTests",
            dependencies: ["rtr"],
            path: "Tests/rtrTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

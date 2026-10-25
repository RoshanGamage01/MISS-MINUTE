// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minutes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MinutesCore", targets: ["MinutesCore"]),
        .executable(name: "Minutes", targets: ["Minutes"])
    ],
    targets: [
        .target(
            name: "MinutesCore",
            path: "Sources/MinutesCore"
        ),
        .executableTarget(
            name: "Minutes",
            dependencies: ["MinutesCore"],
            path: "Sources/Minutes",
            exclude: ["Info.plist", "Minutes.entitlements"]
        ),
        .testTarget(
            name: "MinutesCoreTests",
            dependencies: ["MinutesCore"],
            path: "Tests/MinutesCoreTests"
        )
    ]
)

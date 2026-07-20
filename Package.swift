// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarTender",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BarTender", targets: ["BarTender"])
    ],
    targets: [
        .executableTarget(
            name: "BarTender",
            path: "Sources/BarTender",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "BarTenderTests",
            dependencies: ["BarTender"],
            path: "Tests/BarTenderTests"
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "multi-dev-ctrl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "multi-dev-ctrl", targets: ["MultiDevCtrlApp"])
    ],
    targets: [
        .executableTarget(
            name: "MultiDevCtrlApp",
            path: "Sources/MultiDevCtrlApp"
        )
    ]
)

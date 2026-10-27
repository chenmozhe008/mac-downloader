// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shandian",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Shandian", targets: ["Shandian"])],
    targets: [
        .executableTarget(name: "Shandian", path: "Sources/Shandian")
    ]
)

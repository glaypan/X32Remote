// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "X32Remote",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "X32RemoteCore",
            targets: ["X32RemoteCore"]
        )
    ],
    targets: [
        .target(
            name: "X32RemoteCore",
            path: "Sources/X32RemoteCore"
        ),
        .testTarget(
            name: "X32RemoteCoreTests",
            dependencies: ["X32RemoteCore"],
            path: "Tests/X32RemoteCoreTests"
        )
    ]
)

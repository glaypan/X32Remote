// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "X32Remote",
    // macOS 10.15 声明只为让 `swift test` 能在 macOS runner 上跑：
    // 不声明 macOS 平台时，SPM 宿主编译的部署目标默认过低，
    // ShowEngine 的 Task.sleep 会报 "only available in macOS 10.15"。
    // 对 iOS 构建无影响（App 层的 Observation 不在本包内）。
    platforms: [.iOS(.v15), .macOS(.v10_15)],
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

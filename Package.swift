// swift-tools-version: 6.0
import PackageDescription

// 使用单个动态入口产品，交由 xtool 打包为 iPhone / iPad 应用。
let package = Package(
    name: "MioLib",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17)],
    products: [.library(name: "MioLib", targets: ["MioLib"])],
    dependencies: [
        .package(path: "Packages/MioLibCore"),
        .package(path: "Vendor/Readium")
    ],
    targets: [
        .target(name: "MioLib", dependencies: [
            "MioLibCore",
            .product(name: "ReadiumShared", package: "Readium"),
            .product(name: "ReadiumStreamer", package: "Readium"),
            .product(name: "ReadiumNavigator", package: "Readium")
        ], resources: [.process("Resources")])
    ],
    swiftLanguageModes: [.v5]
)

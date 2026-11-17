// swift-tools-version: 6.0
import PackageDescription

// 核心包不依赖 UIKit，确保真实数据流程可在 WSL 中运行测试。
let package = Package(
    name: "MioLibCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MioLibCore", targets: ["MioLibCore"])],
    dependencies: [.package(path: "../../Vendor/MioZIPFoundation")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "CLibMobi", path: "Sources/CLibMobi", publicHeadersPath: "include", cSettings: [
            .define("USE_XMLWRITER"), .define("HAVE_UNISTD_H"), .define("HAVE_STRDUP"),
            .define("PACKAGE_VERSION", to: "\"0.12\""), .headerSearchPath("vendor")
        ], linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv", .when(platforms: [.iOS, .macOS]))]),
        .target(name: "MioLibCore", dependencies: ["CSQLite", "CLibMobi", .product(name: "MioZIPFoundation", package: "MioZIPFoundation")]),
        .testTarget(name: "MioLibCoreTests", dependencies: ["MioLibCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)

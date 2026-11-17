// swift-tools-version: 6.0
import PackageDescription

// 上游 3.0.1 的接口不变；仅 Linux 压缩分支修复 async 指针生命周期。
let package=Package(name:"MioZIPFoundation",platforms:[.iOS(.v13),.macOS(.v11)],products:[.library(name:"MioZIPFoundation",targets:["MioZIPFoundation"])],targets:[
    .systemLibrary(name:"MioCZLib",path:"Sources/CZLib",pkgConfig:"zlib"),
    .target(name:"MioZIPFoundation",dependencies:[.target(name:"MioCZLib",condition:.when(platforms:[.linux]))],path:"Sources/ZIPFoundation",resources:[.copy("Resources/PrivacyInfo.xcprivacy")],cSettings:[.define("_GNU_SOURCE",to:"1")])
],swiftLanguageModes:[.v5])

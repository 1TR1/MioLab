# ZIPFoundation 来源

固定来源：readium/ZIPFoundation 3.0.1，MIT 许可。

保留上游 Apple Compression 实现。Linux 的 Data+Compression.swift 改用显式分配、释放的输入输出缓冲区，修复在同步 withUnsafeMutableBytes 闭包中 await 导致无法编译的问题，并在输入提前耗尽时报错。

Package.swift 精简为实际使用的库目标；修复版独立命名为 MioZIPFoundation / MioCZlib。Readium 保留自己的上游模块，避免 SwiftPM 的包身份冲突。

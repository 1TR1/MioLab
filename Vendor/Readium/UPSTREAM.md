# Readium 固定源码

来源：Readium Swift Toolkit 3.11.1，发布提交 `9a8c094`，BSD-3-Clause 许可。

保留上游 Sources、Tests、Package.swift 和 LICENSE。唯一的兼容性改动是将 ZIP 依赖改为相邻的 `MioZIPFoundation`，并更新对应模块引用。

原因：上游 ZIP 包在 Linux 主机执行 Package.swift 时通过 `canImport(Compression)` 选择宿主分支，会把 Linux 的 zlib 搜索路径传入 iOS 链接。修复模块通过目标平台条件选择依赖；Apple 平台使用 SDK 的 Compression，Linux 使用 zlib。

阅读、导航、搜索和标注实现保持 3.11.1 的源码逻辑。

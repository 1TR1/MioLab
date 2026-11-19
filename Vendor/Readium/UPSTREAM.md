# Readium 固定源码

来源：Readium Swift Toolkit 3.11.1，发布提交 `9a8c094`，BSD-3-Clause 许可。

保留上游 Sources、Tests、Package.swift 和 LICENSE。ZIP 依赖改为相邻的 `MioZIPFoundation`，并更新对应模块引用。

原因：上游 ZIP 包在 Linux 主机执行 Package.swift 时通过 `canImport(Compression)` 选择宿主分支，会把 Linux 的 zlib 搜索路径传入 iOS 链接。修复模块通过目标平台条件选择依赖；Apple 平台使用 SDK 的 Compression，Linux 使用 zlib。

EPUB 注释回调支持 `epub:type` 的 `noteref` 标记、`doc-noteref` 角色和常见的「注」链接。回调从书内读取相对地址与片段 ID 指向的注释内容，供 MioLib 预览和跳转。

注释点击由书页隔离脚本直接报告书内目标，避免依赖 WebKit 点击与导航回调的到达顺序。流式定位兼容旧书的 `a[name]` 锚点。MioLib 的注释跳转确认目标文档已加载及页内定位已完成后，再显示返回栏。

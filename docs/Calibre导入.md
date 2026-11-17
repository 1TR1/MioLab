# Calibre 导入说明

MioLib 1.1.0 可以直接浏览电脑 Calibre 的内容服务器，将所选书籍下载到手机书库。支持 Calibre 的 Atom / OPDS 1 目录，无须安装 Calibre 插件。

## 连接与导入

1. 电脑打开 Calibre，点击“连接／共享 → 启动内容服务器”。再次打开此菜单，记下停止服务器选项旁显示的电脑 IP 和端口。
2. 手机与电脑使用同一局域网。在 MioLib 书架点击“＋ → 从 Calibre 导入”。
3. 输入电脑服务器地址，例如 `http://192.168.1.5:8080`。已有 OPDS 地址也可以直接填写，反向代理的路径前缀会保留。
4. 若 Calibre 开启了访问认证，填写内容服务器的账号和密码。这与 Apple 账号无关。
5. 点击“连接书库”，允许 iOS 访问本地网络。打开“按最新”“按作者”等目录，或者输入关键词搜索。
6. 勾选书籍，按需修改“格式”及“导入到”书架，点击右上角“导入 N 本”。每本书只导入选定的一种格式，默认优先 EPUB。
7. 下载成功后，文件进入 MioLib 导入队列。关闭面板后在目标书架查看；解析失败可通过书架“⋯ → 导入记录”重试。

## 取消、重试与数据

- “停止下载”会中止当前传输并删除半成品，已经加入导入队列的书籍继续处理。
- 下载失败的条目保留选择和错误说明，重新点击“导入”可重试这些书籍。单本失败不阻断后续书籍。
- 浏览目录按服务器分页加载。“选择已加载的书籍”只选择当前已经加载的条目，可继续“加载更多”再选择。
- EPUB、TXT、PDF、无 DRM 的 MOBI / AZW3 沿用现有格式限制。书籍原文件和阅读副本保存在 MioLib 内部书库。
- 重复检测依据文件内容。Calibre 可能在下载时更新文件中的元数据，因此同一书目在 Calibre 修改后可能作为不同文件导入。
- 服务器地址与用户名保存于此设备；密码只留在本次连接的内存中，关闭面板后需重新填写。连接信息不包含在书库备份中。

## 无法连接时

- 手机不能使用 `localhost` 或 `127.0.0.1` 访问电脑；请使用 Calibre 菜单显示的电脑 IP。
- 确认 Calibre 内容服务器仍在运行，手机与电脑在同一局域网。访客 Wi-Fi 或校园网可能隔离设备。
- 在“iPhone 设置 → App → MioLib → 本地网络”中允许访问；不同系统版本的设置层级可能不同。
- 若 Windows 防火墙询问，请允许 Calibre 在所使用的可信网络通信；不需要关闭整个防火墙。
- 认证失败时核对 Calibre 内容服务器的账号、密码及该账号的书库权限。应用使用系统 Basic / Digest 认证，不支持网页登录表单或自签名证书绕过。
- HTTP 404 可能表示目录或书籍已移除，也可能表示搜索没有匹配结果。可返回上级或重新连接书库。
- 更改服务器或代理地址时填写最终地址；应用不跟随指向其他服务器的目录、下载或重定向。

## 当前验证

已在 Windows Calibre 9.14 的独立中文样书库完成目录、搜索、下载与入库联调；通过真实 HTTP 夹具验证 Basic 认证、分页、去重、取消清理、错误密码、跨服务器跳转和大小限制。

WSL 的 Swift Foundation 不实现 Digest 认证，该项自动测试明确跳过，iOS 由 Apple 的 URLSession 处理，仍需设备联调。网络权限弹窗、局域网连接与大书库滚动也需在实际网络和设备上验收。

依据：[Calibre 内容服务器官方说明](https://manual.calibre-ebook.com/server.html)、[Calibre OPDS 说明](https://manual.calibre-ebook.com/faq.html)、[Swift Foundation 的 Digest 实现状态](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/FoundationNetworking/URLSession/URLSessionTask.swift)。

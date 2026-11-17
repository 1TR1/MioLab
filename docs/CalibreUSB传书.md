# Calibre 直接 USB 传书

MioLib 1.2.0 配合桌面端的 **MioLib USB** 插件，可以在 Calibre 中选书后通过数据线直接发送到 iPhone。手机打开 MioLib 后自动校验、入库，无须启动内容服务器，也无须 Wi-Fi。

## 这台电脑的使用步骤

1. 用数据线连接 iPhone，解锁并信任此电脑。
2. 在 Calibre 中选中一本或多本书，点击工具栏 **MioLib USB**（完整名称“发送到 MioLib（USB）”）；右键菜单也提供同一入口。
3. 选择“自动选择（EPUB 优先）”或指定格式，点击“通过 USB 发送”。失败或未发送的书可直接重试。
4. 传输完成后打开手机上的 MioLib。默认自动导入“未归类”；已有相同文件时不会新增重复书目。
5. 若要改变自动接收开关或目标书架，在 MioLib 打开“＋ → 电脑 USB 传书 → Calibre USB”。

传书中止时，已发送成功的书籍会继续入库。其他 App 或 Apple Devices / Finder 手动复制的文件仍需在 USB 页面选择后导入。

## 支持范围

- 手机：MioLib 1.2.0 及以上，iOS / iPadOS 17 及以上。
- 桌面插件首版：Windows，Calibre 7 及以上；本机验证版本为 9.14。
- 设备服务：Windows 已有的 Apple Devices 或 iTunes 驱动和信任配对。
- 此版本复用本机 `Xtool-Ubuntu-24.04` WSL 环境及其 `libimobiledevice`、`libplist`，不要求用户手工启动桥接终端。插件只在发送期间启动自己的辅助进程。
- 支持 EPUB、TXT、PDF、无 DRM 的 MOBI / AZW3；每本只发送一种格式，默认优先 EPUB。其他格式可先在 Calibre 中转换。
- 单本最大 512 MB，TXT、MOBI / AZW3 的阅读转换仍沿用应用既有的更小上限。
- 同时只选择一台装有 MioLib 的 USB 设备；Mac 桌面插件与 Calibre 自带的“发送到设备”驱动接入暂未实现。

## 在其他电脑安装

1. 安装 Apple Devices / iTunes，先确认可以识别并信任 iPhone。
2. 准备名为 `Xtool-Ubuntu-24.04` 的 WSL 发行版，安装 Python 3、`libimobiledevice6` 和 `libplist-2.0-4`。这台开发电脑已具备环境。
3. 在 Calibre 的“首选项 → 插件 → 从文件加载插件”中选择 `MioLib-Calibre-USB-1.0.0.zip`，然后重启 Calibre。
4. 在“首选项 → 工具栏与菜单”中加入 **MioLib USB**。也可退出 Calibre 后，用其自带 `calibre-debug` 执行项目的 `tools/configure-calibre-usb.py`，自动添加按钮。

在此项目目录中，也可正常退出 Calibre 后运行 `tools/Install-CalibreUSB.ps1`，一次完成插件打包、安装和按钮配置。

插件 ZIP 由 `tools/build-calibre-plugin.py` 生成；源码位于 `Integrations/CalibreUSB`。界面按钮使用 Calibre 官方的 InterfaceAction 插件机制，USB 后端调用系统已安装的 libimobiledevice 公开接口，不更换或重新绑定 Apple 驱动。

## 数据完整性与故障处理

- 插件从 Calibre 通过线程安全接口复制只读快照，不改动电脑原书。书名与作者写入独立传书清单，MioLib 显示 Calibre 中的标题和作者。
- 手机仅接收专用 `.CalibreUSB` 目录。每本文件先写 `.part`，完成后改名，最后原子提交清单；未完成书籍不会被入库。
- MioLib 按清单核对文件大小与 SHA-256，成功入库后才清理对应传输副本。已持久化的失败或取消任务保留原状态，可在导入记录中重试。
- “已发送”表示文件已完整送达应用传输区。DRM、损坏、空间不足等解析错误显示在手机导入记录，不能仅凭桌面发送成功判断已经可以阅读。
- USB 服务连接失败时，打开 Apple Devices / iTunes，解锁手机并重新插线接受信任；不需要关闭防火墙。
- 取消会正常结束当前 USB 调用并尽量清理未提交临时文件。突然拔线或进程被强制终止可能留下没有完成清单的目录；不会被自动导入。
- iOS 不允许此传输唤醒已经关闭的 App。完成发送后须打开 MioLib，或让 MioLib 保持前台以自动接收。

参考：[Calibre 插件开发说明](https://manual.calibre-ebook.com/creating_plugins.html)、[Calibre 数据库复制接口](https://manual.calibre-ebook.com/db_api.html)、[libimobiledevice](https://libimobiledevice.org/)。

本机验收已完成：Calibre 9.14 发送中文样书，iPhone 13 / iOS 18.3.2 上的 MioLib 1.2.0 自动入库，用户确认正文显示正常。详细记录见 `docs/验证记录.md`。

# MioLib

面向 iPhone / iPad 的本地电子书阅读器，最低 iOS / iPadOS 17。使用 SwiftUI、Readium 3.11.1、PDFKit、SQLite 和 xtool 开发。

当前版本 1.6.3：保留列表 / 封面两种展示，列表统一显示书架与图书，封面模式的书架底板与书籍封面同尺寸、同为 2:3；新增单张 / 四宫格书架封面切换。界面、字号与个人资料的使用方法见 [书架与阅读空间](docs/书架与阅读空间.md)。

## 功能

- 从其他 App 的“用其他应用打开 / 拷贝到”、文件选择器和电脑 USB 文件共享导入。
- 连接 Calibre 内容服务器，浏览分类、搜索书库、选择格式并批量导入到指定书架。
- Calibre 桌面端的 MioLib USB 按钮：选书后经数据线直接发送，手机打开 MioLib 后自动校验并入库。
- EPUB、TXT、PDF，以及无 DRM 的 MOBI / AZW3；TXT 和 Kindle 文件在本机生成阅读副本，保留原书。
- 多级书架、批量移动、收藏、最近阅读、已读状态、全库书名搜索。
- 修改书籍与书架的标题和封面，支持照片 / 图片文件与裁切。
- 书架封面可从其中书籍选择；书籍封面可从书页选取，阅读界面可直接使用当前页。
- 书架封面支持单张 / 四宫格切换；四宫格显示直属书籍的前四张封面，不足四本留空，样式随偏好及备份保存。
- 书架支持列表 / 封面，右上角三点可选择并记住布局和排序；旧版网格设置自动转为封面，范围使用下拉筛选。
- 书架“编辑”模式支持两种视图多选，批量收藏、已读状态、移动与删除。
- iOS 26 起使用原生 Liquid Glass；iOS 17–18 使用通透材质和弹性动效，遵循减少动态效果与减少透明度。
- 底部导航合并为“书架 / 我的”，“我的”分类管理笔记、偏好、备份与关于。
- 阅读目录保留内置层级，下方提供滑动和输入定位；排版滑块具有可见格点、吸附和触感。
- 分类统一称为“书架”，封面使用纵向书籍比例及细玻璃包边；App 图标采用用户提供的图片。
- “我的阅读空间”可进入个人资料与数据管理，支持本机头像、昵称、简介及完整备份恢复。
- 目录与定位区独立布局；字号格点位于轨道上，配有实时预览和增大／减小按钮。
- “我的”分别提供界面字体和阅读字体入口，界面字号、字型独立保存并随备份恢复。
- 文字排版、横向分页 / 纵向滚动、四种主题、目录、书内搜索、续读。
- 书签、高亮、批注、笔记集中管理及 Markdown / JSON 导出。
- 完整书库备份恢复，包含原书、阅读副本、封面、书架、进度和笔记。

## 本机开发环境

Windows 项目目录为 `D:\Projects\MioLib`，使用现有 WSL 发行版 `Xtool-Ubuntu-24.04`。当前工具链为 xtool 1.24.0、Swift 6.4.2、iPhoneOS 27.1 SDK，部署目标为 iOS 17。

```powershell
# 编译 Debug，不登录 Apple，也不修改设备。
wsl -d Xtool-Ubuntu-24.04 -- bash -lc 'cd /mnt/d/Projects/MioLib && xtool dev build'

# 生成 Release IPA；未带 --sign 时是未签名包。
wsl -d Xtool-Ubuntu-24.04 -- bash -lc 'cd /mnt/d/Projects/MioLib && xtool dev build --configuration release --ipa'
```

常规产物位于 `xtool/MioLib.app` 或 `xtool/MioLib.ipa`。应用包与构建缓存已排除在版本控制之外。

## 在自己的 iPhone 上安装

1. 连接数据线并解锁 iPhone，在手机上接受“信任此电脑”。
2. 在一个终端启动设备桥接，保持窗口运行：

```powershell
# 复用 Windows 的 Apple Mobile Device 服务，无须重新绑定 USB 驱动。
wsl -d Xtool-Ubuntu-24.04 -- bash -lc 'cd /mnt/d/Projects/MioLib && python3 tools/usbmux_bridge.py'
```

3. 在另一个项目终端登录 Apple 账号：

```powershell
# 密码输入没有字符或星号反馈；直接输入密码后按回车。
.\tools\Login-Apple.ps1
```

账号、密码与验证码仅在本机交互终端输入，不写入脚本或命令行参数。普通 Apple 账号通过 xtool 的 password 模式登录。

4. 运行安装脚本：

```powershell
# 使用 Release 配置构建、签名并安装到 USB 设备。
.\tools\Install-Device.ps1
```

按照手机提示开启开发者模式。若提示不受信任的开发者，在“设置 → 通用 → VPN 与设备管理”中信任相应开发者。普通账号的开发签名可能需要定期重新安装；重新安装时保持同一 Apple 账号与 Bundle ID，以保留应用数据。

开发时请勿同时运行多个桥接实例；正在运行的实例通过 Ctrl+C 停止。桥接只监听当前 WSL 用户的 Unix socket，不开放局域网端口。

## 电脑 USB 批量传书

1. Windows 打开 Apple Devices（已有 iTunes 文件共享也可），或在 Mac 打开 Finder。
2. 选择设备的“文件”页面，再选择 MioLib，批量复制 EPUB / TXT / PDF / MOBI / AZW3。
3. 等待复制完成，回到 MioLib，选择“＋ → 电脑 USB 传书 → 刷新传入文件”。
4. 选择待导入书籍及目标书架，然后批量导入。

应用成功入库后，会在确认传输源内容一致的情况下清理对应传输副本。失败记录保留独立暂存文件，可以重试；TXT 可以指定 UTF-8、UTF-16LE、UTF-16BE 或 GB18030 编码。

## 从 Calibre 导入

**直接 USB 传书（1.2.0）**：电脑 Calibre 安装随项目交付的 MioLib USB 插件，选书后点击工具栏“MioLib USB → 通过 USB 发送”，再打开手机 MioLib 自动入库。该桌面插件首版支持当前 Windows + WSL 环境；完整安装步骤及限制见 [Calibre USB 传书](docs/CalibreUSB传书.md)。

**内容服务器导入（1.1.0）**：

1. 在电脑 Calibre 中选择“连接／共享 → 启动内容服务器”，查看显示的 IP 地址与端口。
2. 将手机与电脑连接至同一局域网，在 MioLib 打开“＋ → 从 Calibre 导入”。
3. 输入 `http://电脑IP:端口`，需要时填写 Calibre 内容服务器的用户名与密码，点击“连接书库”。应用会自动补齐 `/opds`。
4. 浏览分类或搜索书名，勾选书籍，选择目标书架后点击“导入”。可为同一本书选择 EPUB、PDF、TXT、MOBI 或 AZW3，默认优先 EPUB。

首次连接时允许 iOS 的“本地网络”访问。下载逐本进行，可停止并重试；下载完成后沿用已有导入队列的去重、转换和错误记录。地址与用户名保存在本机，密码只用于当前面板。详细排错见 [Calibre 导入说明](docs/Calibre导入.md)。

此入口使用 [Calibre 官方内容服务器的 OPDS 目录](https://manual.calibre-ebook.com/faq.html)，书籍下载后可离线阅读。

## 测试

```powershell
# 本机 sqlite3 头文件按用户目录解压安装，避免要求系统 sudo 密码。
wsl -d Xtool-Ubuntu-24.04 -- bash -lc 'cd /mnt/d/Projects/MioLib && PKG_CONFIG_PATH=/home/mako/.local/miolib-deps/usr/lib/x86_64-linux-gnu/pkgconfig swift test --package-path Packages/MioLibCore'
```

其他 Linux 环境可安装 `libsqlite3-dev`、`zlib1g-dev` 后直接运行核心包测试。测试使用独立临时书库，不访问真实阅读数据。

## 项目结构与数据

- `Sources/MioLib`：原生界面、阅读会话、PDFKit / Readium 适配。
- `Packages/MioLibCore`：真实 SQLite 存储、导入、TXT / Kindle 转换与备份恢复。
- `Vendor/MioZIPFoundation`：Readium ZIPFoundation 3.0.1 固定源码，仅修复 Linux 分支的 async 编译与缓冲区生命周期，保留 Apple 平台实现。
- `Vendor/Readium`：Readium 3.11.1 固定源码，将 ZIP 依赖连接到按目标平台选择的兼容模块，避免 WSL 的 Linux 库参与 iOS 链接。
- `tools`：本机登录、安装、图标生成与 Windows / WSL 设备桥接脚本。

正式书库位于应用内部 Application Support 目录；Documents 用于 USB 传输。书目、书架和标注使用稳定 UUID。删除书籍先软删除以提供撤销；备份只包含当前有效书库。恢复会校验路径、版本、关联与文件 SHA-256 后再提交。

## 格式与验证边界

- 单文件导入上限 512 MB；TXT 上限 128 MB；MOBI / AZW3 上限 64 MB，较大的 Kindle 文件建议先转为 EPUB。
- 不处理 DRM、KFX；扫描 PDF 没有文字层时不能全文检索或按文字高亮。
- PDF / 固定版式书籍保留原布局，字体调整只对可重排文字生效。
- 云同步、AI、OCR、朗读和手写批注不属于当前版本。
- Windows / WSL 编译通过不能替代真实 iOS 的排版、分享入口、触摸与动画验收；设备测试状态见 `docs/验证记录.md`。

完整第三方许可在应用“我的 → 关于 MioLib → 开源组件”与 `ThirdPartyNotices/ALL-LICENSES.txt` 中。

# MioLib 项目记忆

适用于 `D:\Projects\MioLib`。本记忆整理自本项目的修改和交付记录，版本与工具链以当前工作区为准。

## 协作约定

- 在对话中使用中文。编写代码时，每个逻辑段旁写清楚注释。
- 任务确需访问授权时，优先向用户申请 Codex 使用浏览器并进行操作的权限。沿用本次任务已有的授权。
- 开始前查看 `git status --short`，并用 `rg` 定位实际使用的入口。保留工作树已有修改，尤其是未提交的实现和测试。以用户最新确认的行为处理同一功能。

## 修改和验证

1. 在现有入口实现需求。SwiftUI、阅读器会话和网页界面在 `Sources/MioLib`，持久化、备份和 EPUB 转换在 `Packages/MioLibCore`，网页脚本在 `Sources/MioLib/Resources`。需要改变 Readium 的注释或导航处理时，核对 `Vendor/Readium` 里的实际代码，并将依赖改动记在 `Vendor/Readium/UPSTREAM.md`。
2. 验证用户实际走的路径。涉及书库、设置与缓存时，检查新旧记录、重开、备份恢复及失败中断。涉及阅读器时，按改动检查阅读位置、章节顺序与原有资源。针对现有测试漏掉的回归补充测试。
3. 按改动运行核心测试和网页脚本测试。涉及注释时关注 Readium 注释识别测试，以及离线 EPUB 中的引用和目标是否能对应。Windows／WSL 可以验证解析、持久化、归档与 iOS 编译。设备触摸、iOS WebKit 排版、相册保存和系统后台调度以实际设备结果为准。

### 本机验证命令

Windows 使用 PowerShell，WSL 发行版为 `Xtool-Ubuntu-24.04`，项目在 WSL 中映射为 `/mnt/d/Projects/MioLib`。工具链安装和设备操作见 [README](README.md#本机开发环境)。

```powershell
# 运行核心库测试。本机的 SQLite pkg-config 路径位于 WSL 用户目录。
wsl -d Xtool-Ubuntu-24.04 -- bash -lc 'cd /mnt/d/Projects/MioLib && PKG_CONFIG_PATH=/home/mako/.local/miolib-deps/usr/lib/x86_64-linux-gnu/pkgconfig swift test --package-path Packages/MioLibCore'

# 网页提取、分卷或图片脚本有改动时，先确认测试依赖已装在忽略的 output 目录。
if (!(Test-Path -LiteralPath 'output/web-reader-validation/node_modules/jsdom')) {
  npm --prefix output/web-reader-validation install --no-save jsdom@26.1.0
}

# 运行网页脚本回归。
node --test tools/test-web-article-extractor.cjs

# 检查改动中的空白问题，兼容工作树里的 CRLF。
git -c core.safecrlf=false -c core.whitespace=cr-at-eol diff --check -- Sources/MioLib Packages/MioLibCore Vendor/Readium Info.plist Package.swift tools README.md docs
```

核心测试与 Release 构建先后运行，避免争用 SwiftPM 的构建锁。编译或测试失败时先读本次日志，修复后重跑相关步骤。按版本或改动命名的日志放在 `output/`，结果记在 [验证记录](docs/验证记录.md)。

## 打包与交付

1. 发新版时更新 `Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。核对 README、相关说明和验证记录的版本，保留已有的版本化交付件。应用标识沿用 `com.miolib.reader`。
2. 构建 iOS arm64 Release，确认命令成功且 `xtool/MioLib.ipa` 是本次产物。默认交付未签名 IPA 和完整源码。用户需要在设备上安装时，按其指定的签名或侧载方式处理。
3. 用项目脚本生成版本化副本并检查包内容。脚本会核对实际 IPA 的版本、应用标识、权限声明与阅读资源，并写入 `output/delivery.json` 和对应的 SHA-256 文件。交付前还要核对 arm64 架构及源码包里的改动文件。签名凭据和用户数据留在本机。
4. 交付时给出两个文件的绝对路径链接，说明已通过的测试和仍待真机验证的交互。

```powershell
# 从工作区源码构建本次未签名 IPA。
wsl -d Xtool-Ubuntu-24.04 -- bash -lc 'cd /mnt/d/Projects/MioLib && xtool dev build --configuration release --ipa'

# 构建成功后，从项目根目录生成并校验交付件。
if ($LASTEXITCODE -eq 0) {
  python tools/package-release.py
}
```

交付文件名为 `output/MioLib-<版本>-unsigned.ipa` 和 `output/MioLib-<版本>-source.zip`。打包脚本入口见 [package-release.py](tools/package-release.py)。

## 已确认的回归基线

- 网页书导出时保存书目与来源。缓存可按整本或多选卷，确认后才发起下载。已有缓存记录的书直接打开，原网页与阅读模式的右上角三点菜单都可选卷。缓存管理支持删卷。至少两次失败并且满 30 秒仍未下载到本轮选择的章节时提示错误。 [网页阅读与收藏](docs/网页阅读与收藏.md)
- 阅读模式按书保存。打开和切换缓存副本时保留书目 ID、当前阅读位置与笔记关联。插图可从离线副本保存到相册。 [网页阅读与收藏](docs/网页阅读与收藏.md)
- 注释默认小窗预览，设置可切换为直接跳转。跳转后「取消跳转」回到原位置，「×」收起提示栏。网页书新缓存保留可提取的同页文字注释。 [阅读页面布局](docs/阅读页面布局.md#书内注释)
- 2026-11-19 的 `1.15.0`（build 24）已通过 iOS 构建和自动化测试。用户更正验收结果，「小窗预览后跳转」与「直接跳转」均出现异常。 [验证记录](docs/验证记录.md)
- `1.15.1`（build 25）重做了注释点击与页内定位的共用路径。保留两种方式的真机复测项，自动化结果见 [验证记录](docs/验证记录.md)。

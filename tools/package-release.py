"""按 Info.plist 的版本生成源码归档与 SHA-256 清单，保留之前版本。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import zipfile

# 版本名只接受三段数字，所有产物始终写在当前项目 output 目录内。
root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / 'Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise ValueError('Invalid release version')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ipa', type=Path, help='已冻结的未签名 IPA，省略时使用 xtool/MioLib.ipa')
args = parser.parse_args()
output = root / 'output'
output.mkdir(exist_ok=True)
ipa = output / f'MioLib-{version}-unsigned.ipa'
source = output / f'MioLib-{version}-source.zip'
original = (args.ipa or root / 'xtool/MioLib.ipa').resolve()
if original != ipa.resolve():
    shutil.copyfile(original, ipa)

# 验证实际包的版本与平台声明；未签名包必须保留原始应用标识。
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
    packed = plistlib.loads(archive.read('Payload/MioLib.app/Info.plist'))
    assert packed['CFBundleShortVersionString'] == version
    assert packed['CFBundleVersion'] == info['CFBundleVersion']
    assert packed['CFBundleIdentifier'] == 'com.miolib.reader'
    assert packed['UIFileSharingEnabled'] is True
    # 原生 WebKit 保存图片依赖系统相册权限说明，交付时检查最终包避免 TCC 终止应用。
    assert packed.get('NSPhotoLibraryAddUsageDescription', '').strip()
    assert packed.get('NSPhotoLibraryUsageDescription', '').strip()
    # 系统后台任务需要声明 processing 和与签名前包名匹配的任务标识。
    assert 'processing' in packed.get('UIBackgroundModes', [])
    assert f"{packed['CFBundleIdentifier']}.web-cache.*" in packed.get('BGTaskSchedulerPermittedIdentifiers', [])
    # 安装包中的文库目录解析脚本必须是本轮实现，避免使用只读取首章的旧资源。
    navigation = 'Sources/MioLib/Resources/WebChapterNavigation.js'
    assert archive.read('Payload/MioLib.app/MioLib_MioLib.bundle/WebChapterNavigation.js') == (root / navigation).read_bytes()
    # 阅读器图片菜单需要隔离的手势脚本，核对实际 IPA 中的资源。
    image_menu = 'Sources/MioLib/Resources/ReaderImageMenu.js'
    assert archive.read('Payload/MioLib.app/MioLib_MioLib.bundle/ReaderImageMenu.js') == (root / image_menu).read_bytes()
    # 同页注释必须由实际安装包的正文提取脚本生成。
    extractor = 'Sources/MioLib/Resources/WebArticleExtractor.js'
    assert archive.read('Payload/MioLib.app/MioLib_MioLib.bundle/WebArticleExtractor.js') == (root / extractor).read_bytes()
    # 注释点击必须走新版书页脚本，核对 Readium 实际打进 IPA 的资源。
    footnote_script = 'Assets/Static/scripts/readium-footnote-links.js'
    footnote_source = 'Vendor/Readium/Sources/Navigator/EPUB/' + footnote_script
    assert archive.read('Payload/MioLib.app/Readium_ReadiumNavigator.bundle/' + footnote_script) == (root / footnote_source).read_bytes()

# 排除本机缓存、安装日志、认证信息和构建产物，源码与固定依赖完整保存。
excluded = {'.git', '.build', '.swiftpm', '.bsp', '.xtool', 'xtool', 'output', '__pycache__'}
# 系统生成的缩略图和目录设置按 .gitignore 的约定留在本机。
excluded_files = {'.ds_store', 'thumbs.db', 'desktop.ini'}
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for directory, folders, files in os.walk(root):
        folders[:] = sorted(name for name in folders if name not in excluded)
        for name in sorted(files):
            path = Path(directory) / name
            if name.lower() not in excluded_files and path.suffix.lower() not in {'.pyc', '.ipa'}:
                archive.write(path, path.relative_to(root).as_posix())
with zipfile.ZipFile(source) as archive:
    assert archive.testzip() is None
    for name in ('Package.resolved', 'Sources/MioLib/CoverSelectionViews.swift',
                 'Sources/MioLib/BatchBookEditor.swift', 'docs/封面与批量编辑.md',
                 'Sources/MioLib/GlassStyle.swift', 'Sources/MioLib/ReaderContentsView.swift',
                 'Packages/MioLibCore/Tests/MioLibCoreTests/ReaderInterfaceTests.swift',
                 'docs/玻璃界面与阅读导航.md', 'Sources/MioLib/PersonalSpaceView.swift',
                 'Packages/MioLibCore/Tests/MioLibCoreTests/PersonalSpaceTests.swift',
                 'Assets/AppIconSource.png', 'docs/书架与阅读空间.md'):
        assert name in archive.namelist()
    # 新版设置卡片必须随源码交付，避免解压后缺失共享界面组件。
    assert 'Sources/MioLib/RoundedSettingsStyle.swift' in archive.namelist()
    assert 'Sources/MioLib/InterfaceTypography.swift' in archive.namelist()
    # 阅读布局、实际分页及相关说明必须与可自行导入的 IPA 一同归档。
    assert 'Sources/MioLib/ReaderPageChrome.swift' in archive.namelist()
    assert 'Sources/MioLib/Resources/ReaderLayout.css' in archive.namelist()
    assert 'docs/阅读页面布局.md' in archive.namelist()
    # 网页入口、浏览会话、收藏存储和备份测试必须随 1.8.0 源码归档。
    for name in ('Sources/MioLib/WebLibraryView.swift', 'Sources/MioLib/WebBrowserScreen.swift',
                 'Sources/MioLib/WebBrowserSession.swift',
                 'Packages/MioLibCore/Sources/MioLibCore/WebLibrary.swift',
                 'Packages/MioLibCore/Sources/MioLibCore/WebContentFilter.swift',
                 'Packages/MioLibCore/Tests/MioLibCoreTests/WebLibraryTests.swift',
                 'docs/网页阅读与收藏.md'):
        assert name in archive.namelist()
    # 网页书籍、正文提取脚本、离线转换、测试和许可必须与新版 IPA 一并交付。
    for name in ('Packages/MioLibCore/Sources/MioLibCore/WebBook.swift',
                 'Packages/MioLibCore/Sources/MioLibCore/WebArticle.swift',
                 'Packages/MioLibCore/Tests/MioLibCoreTests/WebBookTests.swift',
                 'Sources/MioLib/WebArticleCapture.swift',
                 'Sources/MioLib/Resources/Readability.js',
                 'Sources/MioLib/Resources/WebArticleExtractor.js',
                 'ThirdPartyNotices/Readability-LICENSE.md',
                 'ThirdPartyNotices/Readability-UPSTREAM.md',
                 'tools/test-web-article-extractor.cjs'):
        assert name in archive.namelist()
    # 网页切章的加载器、稳定章节缓存、合并器和回归测试必须与源码归档一起交付。
    for name in ('Sources/MioLib/WebReaderNavigation.swift',
                 'Sources/MioLib/WebBookCache.swift',
                 'Sources/MioLib/WebCacheBackgroundExecution.swift',
                 'Sources/MioLib/Resources/WebChapterNavigation.js',
                 'Packages/MioLibCore/Sources/MioLibCore/WebChapter.swift',
                 'Packages/MioLibCore/Sources/MioLibCore/WebChapterRepository.swift',
                 'Packages/MioLibCore/Sources/MioLibCore/WebCacheRetry.swift',
                 'Packages/MioLibCore/Sources/MioLibCore/WebBookAssembler.swift',
                 'Packages/MioLibCore/Tests/MioLibCoreTests/WebChapterTests.swift',
                 'Packages/MioLibCore/Tests/MioLibCoreTests/WebCacheRetryTests.swift'):
        assert name in archive.namelist()
    # 分卷持久化、设置入口和图片保存实现均随源码发布。
    for name in ('Packages/MioLibCore/Sources/MioLibCore/WebBookVolume.swift',
                 'Packages/MioLibCore/Sources/MioLibCore/WebVolumeRepository.swift',
                 'Packages/MioLibCore/Tests/MioLibCoreTests/WebVolumeTests.swift',
                 'Sources/MioLib/WebCacheSettingsView.swift',
                 'Sources/MioLib/ReaderImageMenu.swift', image_menu):
        assert name in archive.namelist()
    # 开书弹窗和导出入口一起归档，源码可复现先选卷再缓存的流程。
    assert 'Sources/MioLib/WebCacheSelectionView.swift' in archive.namelist()
    # 一并交付注释小窗、Readium 识别源码与解析测试。
    for name in ('Sources/MioLib/ReaderFootnote.swift',
                 footnote_source,
                 'Vendor/Readium/Sources/Navigator/EPUB/EPUBNoteReference.swift',
                 'Vendor/Readium/Tests/NavigatorTests/EPUB/EPUBNoteReferenceTests.swift'):
        assert name in archive.namelist()

# 摘要流式计算，旧版本条目保留，方便安装或传输后核对。
manifest_path = output / 'delivery.json'
manifest = json.loads(manifest_path.read_text(encoding='utf-8')) if manifest_path.exists() else {}
for path in (ipa, source):
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    manifest[path.name] = {'bytes': path.stat().st_size, 'sha256': digest}
    (output / (path.name + '.sha256')).write_text(f'{digest}  {path.name}\n', encoding='utf-8')
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print(json.dumps({path.name: manifest[path.name] for path in (ipa, source)}, indent=2))

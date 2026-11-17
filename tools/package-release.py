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

# 排除本机缓存、安装日志、认证信息和构建产物，源码与固定依赖完整保存。
excluded = {'.git', '.build', '.swiftpm', '.bsp', '.xtool', 'xtool', 'output', '__pycache__'}
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for directory, folders, files in os.walk(root):
        folders[:] = sorted(name for name in folders if name not in excluded)
        for name in sorted(files):
            path = Path(directory) / name
            if path.suffix.lower() not in {'.pyc', '.ipa'}:
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

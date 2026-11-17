"""生成可通过 Calibre 插件管理器安装的 MioLib USB 插件 ZIP。"""
from pathlib import Path
import zipfile

# 只打包明确列出的源码资源，避免混入缓存、开发日志或本机配置。
root = Path(__file__).resolve().parents[1]
directory = root / 'Integrations' / 'CalibreUSB'
target = root / 'output' / 'MioLib-Calibre-USB-1.0.0.zip'
names = ['__init__.py', 'plugin-import-name-miolib_usb.txt', 'ui.py', 'transfer.py', 'usb_backend.py', 'windows_pipe.py']
target.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in names:
        archive.write(directory / name, name)
    # 图标直接复用已有应用资产，不加入新的图片生成或运行时依赖。
    archive.write(root / 'Assets/AppIcon.png', 'icon.png')
with zipfile.ZipFile(target) as archive:
    assert archive.testzip() is None
print(target)

"""Calibre 书库快照导出与 USB 子进程控制；无 Qt 依赖，便于真实环境联调。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

FORMATS = ('EPUB', 'AZW3', 'MOBI', 'PDF', 'TXT')


# 使用 Calibre 的线程安全复制接口，不直接读写其书库内部路径，也不修改原书。
def prepare_books(api, ids, directory, preferred='AUTO', cancelled=lambda: False):
    items, errors = [], []
    for book_id in ids:
        if cancelled():
            break
        try:
            available = set(api.formats(book_id))
            candidates = FORMATS if preferred == 'AUTO' else (preferred,)
            selected = next((format_ for format_ in candidates if format_ in available), None)
            if selected is None:
                raise RuntimeError('没有所选的支持格式，请先在 Calibre 转换为 EPUB 等格式')
            metadata = api.get_metadata(book_id)
            path = Path(directory) / (uuid.uuid4().hex + '.' + selected.lower())
            api.copy_format_to(book_id, selected, str(path))
            if not 0 < path.stat().st_size <= 512 * 1024 * 1024:
                raise RuntimeError('文件为空或超过 512 MB')
            items.append({'calibre_id': book_id, 'path': path.as_posix(), 'format': selected.lower(),
                          'title': metadata.title or '未命名书籍', 'author': '、'.join(metadata.authors or [])})
        except Exception as error:
            errors.append({'calibre_id': book_id, 'error': str(error)})
    return items, errors


# Windows 路径全部使用正斜杠交给 WSL，避免互操作时反斜杠被当作转义。
def command(resources, manifest=None, distribution='Xtool-Ubuntu-24.04'):
    if os.name != 'nt':
        raise RuntimeError('此版本的 USB 插件支持 Windows；手机端仍支持原有 Mac Finder 传书')
    hidden = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
    backend = (Path(resources) / 'usb_backend.py').as_posix()
    mapped = subprocess.run(['wsl.exe', '-d', distribution, '--exec', 'wslpath', '-u', backend],
                            capture_output=True, timeout=30, creationflags=hidden)
    if mapped.returncode:
        raise RuntimeError('未找到 USB 传书环境，请按 MioLib 的 Calibre USB 安装说明准备 WSL')
    runner = Path(sys.executable).with_name('calibre-debug.exe')
    # --exec 直接传递参数，含空格、中文或符号的目录不会被 Linux shell 再解释。
    args = ['wsl.exe', '-d', distribution, '--exec', 'python3', mapped.stdout.decode('utf-8').strip(),
            '--runner', runner.as_posix(), '--pipe', (Path(resources) / 'windows_pipe.py').as_posix()]
    if manifest:
        args += ['--manifest', Path(manifest).as_posix()]
    return args


# 后端在独立进程逐本发送，GUI 只接收限频进度，不加载整本书到主线程内存。
def run_backend(resources, manifest=None, callback=lambda _: None, distribution='Xtool-Ubuntu-24.04'):
    process = subprocess.Popen(command(resources, manifest, distribution), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace',
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    final, message = None, None
    try:
        for line in process.stdout:
            try:
                value = json.loads(line)
            except (ValueError, TypeError):
                continue
            callback(value)
            if value.get('event') == 'complete':
                final = value
            if value.get('event') == 'error':
                message = value.get('message')
        result = process.wait(timeout=30)
        if result or message:
            raise RuntimeError(message or 'USB 连接失败，请检查手机解锁、数据线和 Apple 设备服务')
        return final
    finally:
        process.stdout.close()
        process.stderr.close()

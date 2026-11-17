import json
from pathlib import Path
import tempfile
import threading

from calibre.constants import config_dir
from calibre.gui2 import error_dialog
from calibre.gui2.actions import InterfaceAction
from qt.core import (QComboBox, QDialog, QHBoxLayout, QLabel, QPlainTextEdit, QProgressBar,
                     QPushButton, QThread, QVBoxLayout, pyqtSignal)
from calibre_plugins.miolib_usb.transfer import FORMATS, prepare_books, run_backend


# 工作线程只用线程安全书库 API，UI 与设备传输互不阻塞。
class Sender(QThread):
    changed = pyqtSignal(dict)
    done = pyqtSignal(dict)

    def __init__(self, api, ids, resources, preferred, parent):
        super().__init__(parent)
        self.api, self.ids, self.resources, self.preferred = api, ids, resources, preferred
        self.cancelled = threading.Event()
        self.cancel_path = None

    def stop(self):
        # 取消标记仅写进本次临时目录，后端会正常关闭文件并清理未提交传输。
        self.cancelled.set()
        if self.cancel_path:
            try:
                self.cancel_path.touch()
            except OSError:
                pass

    def run(self):
        # 先复制只读快照，再传书；退出工作线程时统一回收电脑临时副本。
        sent, errors, failure = set(), [], None
        try:
            with tempfile.TemporaryDirectory(prefix='miolib-calibre-usb-') as temporary:
                self.changed.emit({'event': 'preparing'})
                items, errors = prepare_books(self.api, self.ids, temporary, self.preferred, self.cancelled.is_set)
                manifest = Path(temporary) / 'books.json'
                manifest.write_text(json.dumps(items, ensure_ascii=False), encoding='utf-8')
                self.cancel_path = Path(str(manifest) + '.cancel')
                if self.cancelled.is_set():
                    self.cancel_path.touch()
                elif items:
                    # 成功记录用于仅重试失败或尚未发送的书籍，避免整批重复传输。
                    def report(value):
                        if value.get('event') == 'sent':
                            sent.add(value['calibre_id'])
                        self.changed.emit(value)
                    result = run_backend(self.resources, manifest, report)
                    errors += result.get('failures', []) if result else []
        except Exception as error:
            failure = str(error)
        finally:
            self.cancel_path = None
        self.done.emit({'sent': len(sent), 'errors': errors, 'message': failure,
                        'cancelled': self.cancelled.is_set(), 'retry_ids': [value for value in self.ids if value not in sent]})


# 选择格式后一次发送所选书籍；失败可直接重试，取消会等待当前原生调用正常退出。
class USBDialog(QDialog):
    def __init__(self, gui, ids, resources):
        super().__init__(gui)
        self.setWindowTitle('发送到 MioLib（USB）')
        self.resize(540, 360)
        self.api, self.ids, self.resources = gui.current_db.new_api, ids, resources
        self.worker = None
        layout = QVBoxLayout(self)
        text = QLabel(f'已选择 {len(ids)} 本书。请用数据线连接并解锁 iPhone，信任此电脑。\n发送完成后打开 MioLib，书籍将自动进入书架。')
        text.setWordWrap(True)
        layout.addWidget(text)
        self.format = QComboBox(self)
        self.format.addItem('自动选择（EPUB 优先）', 'AUTO')
        for format_ in FORMATS:
            self.format.addItem(format_, format_)
        layout.addWidget(self.format)
        self.status = QLabel('准备就绪；不需要启动内容服务器或连接 Wi-Fi。')
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        self.progress = QProgressBar(self)
        layout.addWidget(self.progress)
        self.details = QPlainTextEdit(self)
        self.details.setReadOnly(True)
        layout.addWidget(self.details)
        row = QHBoxLayout()
        self.send = QPushButton('通过 USB 发送', self)
        self.send.clicked.connect(self.start)
        self.cancel = QPushButton('关闭', self)
        self.cancel.clicked.connect(self.stop_or_close)
        row.addWidget(self.send)
        row.addWidget(self.cancel)
        layout.addLayout(row)

    def start(self):
        # 传输期间锁定格式与发送按钮，避免重复启动同一批任务。
        if not self.ids:
            return
        self.send.setEnabled(False)
        self.format.setEnabled(False)
        self.cancel.setText('停止发送')
        self.details.clear()
        self.worker = Sender(self.api, list(self.ids), self.resources, self.format.currentData(), self)
        self.worker.changed.connect(self.update_progress)
        self.worker.done.connect(self.completed)
        self.worker.start()

    # 进度文字保持在当前书籍，传输错误逐本列出，不使用弹窗打断整批发送。
    def update_progress(self, value):
        kind = value.get('event')
        if kind == 'preparing':
            self.status.setText('正在从 Calibre 准备书籍…')
        elif kind == 'connected':
            self.status.setText('已通过 USB 连接 MioLib')
        elif kind == 'book':
            self.status.setText(f"{value['index']}/{value['count']} · {value['title']}")
            self.progress.setValue(0)
        elif kind == 'progress':
            self.progress.setValue(int(100 * value['sent'] / max(1, value['total'])))
        elif kind == 'failed':
            self.details.appendPlainText(value.get('title', '') + '：' + value.get('error', ''))

    def completed(self, result):
        # 仅保留未成功的 Calibre ID，下一次点击只重试这些书籍。
        self.ids = result['retry_ids']
        self.status.setText(f"已发送 {result['sent']} 本。" + ('已停止，可重试剩余书籍。' if result['cancelled'] else '请打开手机上的 MioLib 自动入库。'))
        if result.get('message'):
            self.details.appendPlainText(result['message'])
        for error in result.get('errors', []):
            self.details.appendPlainText(str(error.get('title', error.get('calibre_id', ''))) + '：' + error['error'])
        self.send.setText('重试剩余书籍' if self.ids else '发送完成')
        self.send.setEnabled(bool(self.ids))
        self.format.setEnabled(True)
        self.cancel.setText('关闭')

    def stop_or_close(self):
        # 正在传输时先请求停止，空闲时才允许关闭面板。
        if self.worker and self.worker.isRunning():
            self.worker.stop()
            self.status.setText('正在停止，等待当前 USB 调用结束…')
        else:
            self.close()

    def closeEvent(self, event):
        # 关闭按钮和系统关窗遵守相同的取消流程，避免销毁仍运行的 Qt 线程。
        if self.worker and self.worker.isRunning():
            self.worker.stop()
            self.status.setText('正在停止，请稍候…')
            event.ignore()
        else:
            event.accept()


# Calibre 工具栏入口；运行资源只展开两个固定的辅助源码文件，不展开任意 ZIP 路径。
class MioLibUSBAction(InterfaceAction):
    name = 'MioLib USB'
    action_spec = ('发送到 MioLib（USB）', 'device.png', '将所选书籍通过数据线发送至 MioLib', None)

    def genesis(self):
        # Calibre 为插件注入 get_icons，复用项目图标并按工具栏尺寸缩放。
        self.qaction.setIcon(get_icons('icon.png', 'MioLib USB'))
        self.qaction.setIconText('MioLib USB')
        self.qaction.triggered.connect(self.show_sender)

    def resources(self):
        # 辅助源码仅在内容改变时覆盖，文件名由插件固定白名单提供。
        directory = Path(config_dir) / 'plugins' / 'MioLibUSB_runtime'
        directory.mkdir(parents=True, exist_ok=True)
        for name, data in self.interface_action_base_plugin.load_resources(['usb_backend.py', 'windows_pipe.py']).items():
            target = directory / name
            if not target.exists() or target.read_bytes() != data:
                temporary = target.with_suffix('.tmp')
                temporary.write_bytes(data)
                temporary.replace(target)
        return directory

    def show_sender(self):
        # 读取当前选择，不替用户挑选或发送其余书库内容。
        ids = self.gui.library_view.get_selected_ids()
        if not ids:
            error_dialog(self.gui, '尚未选择书籍', '请先在 Calibre 书库中选中一本或多本书籍。', show=True)
            return
        USBDialog(self.gui, ids, self.resources()).exec()

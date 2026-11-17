"""WSL 内的 USB 发送后端，依赖 libimobiledevice，不需要 Wi-Fi 或内容服务器。"""
import argparse
from contextlib import contextmanager
import ctypes as c
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import uuid


# 协作式取消让原生连接得到正常释放，不依赖强杀 WSL 或 Windows 驱动进程。
class TransferCancelled(Exception):
    pass


# 进度以 JSON 行输出，桌面线程据此刷新；不把协议二进制或其他 App 信息写入日志。
def event(kind, **values):
    print(json.dumps({'event': kind, **values}, ensure_ascii=False), flush=True)


# 每次传书建立独立、本用户可访问的 Unix socket，关闭后不留常驻服务。
@contextmanager
def usb_bridge(runner, helper):
    class Channel(socketserver.BaseRequestHandler):
        def handle(self):
            # Windows 的 Python 接受正斜杠路径，避免 WSL 互操作层吞掉反斜杠。
            child = subprocess.Popen([runner, '-e', helper.replace('\\', '/')], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=None if os.environ.get('MIOLIB_USB_DEBUG') else subprocess.DEVNULL, bufsize=0)
            selector = selectors.DefaultSelector()
            selector.register(self.request, selectors.EVENT_READ, 'phone')
            selector.register(child.stdout, selectors.EVENT_READ, 'windows')
            try:
                running = True
                while running:
                    for key, _ in selector.select(timeout=5):
                        if key.data == 'phone':
                            data = self.request.recv(65536)
                            if not data:
                                running = False
                                break
                            child.stdin.write(data)
                            child.stdin.flush()
                        else:
                            data = os.read(child.stdout.fileno(), 65536)
                            if not data:
                                running = False
                                break
                            self.request.sendall(data)
                    if child.poll() is not None:
                        break
            except (OSError, BrokenPipeError):
                pass
            finally:
                selector.close()
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=5)

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    with tempfile.TemporaryDirectory(prefix='miolib-usb-') as temporary:
        path = str(Path(temporary) / 'mux.sock')
        with Server(path, Channel) as server:
            os.chmod(path, 0o600)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            os.environ['USBMUXD_SOCKET_ADDRESS'] = 'UNIX:' + path
            try:
                yield path
            finally:
                server.shutdown()
                thread.join(timeout=5)


# 只选择 USB 连接的设备；即使手机同时开启 Wi-Fi 同步，也不会转用网络传书。
def usb_devices(path):
    def exact(stream, length):
        data = bytearray()
        while len(data) < length:
            chunk = stream.recv(length - len(data))
            if not chunk:
                raise RuntimeError('无法连接 Apple 设备服务，请打开 Apple Devices 或 iTunes')
            data.extend(chunk)
        return bytes(data)

    payload = plistlib.dumps({'MessageType': 'ListDevices', 'ClientVersionString': 'MioLib-USB',
                             'ProgName': 'MioLib USB', 'kLibUSBMuxVersion': 3})
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(20)
        stream.connect(path)
        stream.sendall(struct.pack('<IIII', len(payload) + 16, 1, 8, 1) + payload)
        length, _, _, _ = struct.unpack('<IIII', exact(stream, 16))
        if not 16 <= length <= 1024 * 1024:
            raise RuntimeError('Apple 设备服务返回异常')
        response = plistlib.loads(exact(stream, length - 16))
    return [item['Properties']['SerialNumber'] for item in response.get('DeviceList', [])
            if item.get('Properties', {}).get('ConnectionType') == 'USB']


# 显式声明公开 C 接口的类型，避免 64 位指针截断；所有连接都在 finally 中释放。
class Phone:
    def __init__(self, udid):
        library = ctypes.util.find_library('imobiledevice-1.0')
        if not library:
            raise RuntimeError('USB 后端缺少 libimobiledevice，请使用项目附带的安装说明准备环境')
        self.mobile = c.CDLL(library)
        self.plist = c.CDLL(ctypes.util.find_library('plist-2.0'))
        self.libc = c.CDLL(None)
        self.device, self.house, self.afc = c.c_void_p(), c.c_void_p(), c.c_void_p()
        self.cancelled = lambda: False
        p, out = c.c_void_p, c.POINTER(c.c_void_p)
        self.bind(self.mobile, 'idevice_new', [out, c.c_char_p])
        self.bind(self.mobile, 'idevice_free', [p])
        self.bind(self.mobile, 'instproxy_client_start_service', [p, out, c.c_char_p])
        self.bind(self.mobile, 'instproxy_browse', [p, p, out])
        self.bind(self.mobile, 'instproxy_client_free', [p])
        self.bind(self.mobile, 'house_arrest_client_start_service', [p, out, c.c_char_p])
        self.bind(self.mobile, 'house_arrest_send_command', [p, c.c_char_p, c.c_char_p])
        self.bind(self.mobile, 'house_arrest_get_result', [p, out])
        self.bind(self.mobile, 'house_arrest_client_free', [p])
        self.bind(self.mobile, 'afc_client_new_from_house_arrest_client', [p, out])
        self.bind(self.mobile, 'afc_client_free', [p])
        self.bind(self.mobile, 'afc_make_directory', [p, c.c_char_p])
        self.bind(self.mobile, 'afc_file_open', [p, c.c_char_p, c.c_int, c.POINTER(c.c_uint64)])
        self.bind(self.mobile, 'afc_file_write', [p, c.c_uint64, c.c_char_p, c.c_uint32, c.POINTER(c.c_uint32)])
        self.bind(self.mobile, 'afc_file_close', [p, c.c_uint64])
        self.bind(self.mobile, 'afc_rename_path', [p, c.c_char_p, c.c_char_p])
        self.bind(self.mobile, 'afc_remove_path', [p, c.c_char_p])
        self.bind(self.mobile, 'afc_get_file_info', [p, c.c_char_p, c.POINTER(c.POINTER(c.c_char_p))])
        self.bind(self.mobile, 'afc_dictionary_free', [c.POINTER(c.c_char_p)])
        self.bind(self.plist, 'plist_from_xml', [c.c_char_p, c.c_uint32, out], None)
        self.bind(self.plist, 'plist_to_xml', [p, out, c.POINTER(c.c_uint32)], None)
        self.bind(self.plist, 'plist_free', [p], None)
        self.bind(self.libc, 'free', [p], None)
        self.check(self.mobile.idevice_new(c.byref(self.device), udid.encode()), '连接 iPhone，请解锁并信任此电脑')

    @staticmethod
    def bind(library, name, args, result=c.c_int):
        function = getattr(library, name)
        function.argtypes, function.restype = args, result

    @staticmethod
    def check(code, operation):
        if code:
            raise RuntimeError(f'{operation}失败（设备错误 {code}）')

    # 浏览时只请求标识和文件共享属性，只返回 MioLib，不保存其他应用的信息。
    def find_app(self):
        client, options, result = c.c_void_p(), c.c_void_p(), c.c_void_p()
        try:
            self.check(self.mobile.instproxy_client_start_service(self.device, c.byref(client), b'MioLib-USB'), '检查 MioLib')
            encoded = plistlib.dumps({'ApplicationType': 'User', 'ReturnAttributes':
                                     ['CFBundleIdentifier', 'UIFileSharingEnabled']})
            self.plist.plist_from_xml(encoded, len(encoded), c.byref(options))
            self.check(self.mobile.instproxy_browse(client, options, c.byref(result)), '查询 MioLib')
            identifiers = [item.get('CFBundleIdentifier', '') for item in self.decode(result)]
            matches = [value for value in identifiers
                       if value == 'com.miolib.reader' or value.endswith('.com.miolib.reader')]
            if len(matches) > 1:
                raise RuntimeError('此手机存在多个 MioLib 版本，无法自动选择接收应用')
            return matches[0] if matches else None
        finally:
            if options:
                self.plist.plist_free(options)
            if result:
                self.plist.plist_free(result)
            if client:
                self.mobile.instproxy_client_free(client)

    def decode(self, node):
        # XML 缓冲区归 libplist 所有，转换成 Python 对象后立即释放。
        xml, size = c.c_void_p(), c.c_uint32()
        self.plist.plist_to_xml(node, c.byref(xml), c.byref(size))
        try:
            return plistlib.loads(c.string_at(xml, size.value))
        finally:
            self.libc.free(xml)

    # VendDocuments 将访问范围限制在 MioLib 的文件共享目录。
    def open_documents(self, bundle_id):
        self.check(self.mobile.house_arrest_client_start_service(self.device, c.byref(self.house), b'MioLib-USB'), '打开应用文件共享')
        self.check(self.mobile.house_arrest_send_command(self.house, b'VendDocuments', bundle_id.encode()), '访问 MioLib')
        result = c.c_void_p()
        self.check(self.mobile.house_arrest_get_result(self.house, c.byref(result)), '读取共享应答')
        try:
            response = self.decode(result)
            if response.get('Error'):
                raise RuntimeError('无法访问 MioLib，请解锁手机并确认已经安装 MioLib：' + response['Error'])
        finally:
            self.plist.plist_free(result)
        self.check(self.mobile.afc_client_new_from_house_arrest_client(self.house, c.byref(self.afc)), '创建 USB 文件通道')
        root = '/Documents' if self.info('/Documents', missing=True) is not None else ''
        self.root = root + '/.CalibreUSB'
        self.mkdir(self.root)

    def info(self, path, missing=False):
        # AFC 返回键值数组，由调用方释放；允许探测尚不存在的共享根目录。
        values = c.POINTER(c.c_char_p)()
        code = self.mobile.afc_get_file_info(self.afc, path.encode(), c.byref(values))
        if code == 8 and missing:
            return None
        self.check(code, '检查传输文件')
        try:
            result, index = {}, 0
            while values[index]:
                result[values[index].decode()] = values[index + 1].decode()
                index += 2
            return result
        finally:
            self.mobile.afc_dictionary_free(values)

    def mkdir(self, path):
        # 专用根目录可以已存在，但其他设备错误不能被忽略。
        code = self.mobile.afc_make_directory(self.afc, path.encode())
        if code not in (0, 16):
            self.check(code, '创建传输目录')

    # 逐块写入 .part，关闭并核对字节数后原子改名；清单必须最后才提交。
    def write(self, path, chunks, total, title):
        partial = (path + '.part').encode()
        handle, digest, count, last = c.c_uint64(), hashlib.sha256(), 0, 0.0
        self.check(self.mobile.afc_file_open(self.afc, partial, 3, c.byref(handle)), '创建 USB 文件')
        try:
            for chunk in chunks:
                if self.cancelled():
                    raise TransferCancelled()
                digest.update(chunk)
                offset = 0
                while offset < len(chunk):
                    written = c.c_uint32()
                    part = chunk[offset:]
                    self.check(self.mobile.afc_file_write(self.afc, handle, part, len(part), c.byref(written)), '发送书籍')
                    if not written.value:
                        raise RuntimeError('USB 传输没有进展，请重新连接手机')
                    offset += written.value
                count += len(chunk)
                if time.monotonic() - last >= 0.15 or count == total:
                    last = time.monotonic()
                    event('progress', title=title, sent=count, total=total)
        finally:
            self.check(self.mobile.afc_file_close(self.afc, handle), '关闭 USB 文件')
        if self.cancelled():
            raise TransferCancelled()
        if count != total or int(self.info(path + '.part')['st_size']) != total:
            raise RuntimeError('USB 传输文件不完整，未提交入库清单')
        self.check(self.mobile.afc_rename_path(self.afc, partial, path.encode()), '完成 USB 文件')
        return digest.hexdigest()

    def close(self):
        # 先释放借用连接的 AFC，再释放 House Arrest 及设备句柄。
        if self.afc:
            self.mobile.afc_client_free(self.afc)
        if self.house:
            self.mobile.house_arrest_client_free(self.house)
        if self.device:
            self.mobile.idevice_free(self.device)

    # 只清理此进程刚创建且尚未提交的 UUID 目录，绝不删除原书或已提交书籍。
    def discard(self, directory, filename):
        for name in ('transfer.json.part', filename + '.part', filename):
            self.mobile.afc_remove_path(self.afc, (directory + '/' + name).encode())
        self.mobile.afc_remove_path(self.afc, directory.encode())


# 手机上的路径和文件名由协议固定，电脑文件名及绝对路径不会写进手机清单。
def send_book(phone, item):
    source = Path(subprocess.check_output(['wslpath', '-u', item['path']], text=True).strip())
    format_ = item['format'].lower()
    if format_ not in ('epub', 'txt', 'pdf', 'mobi', 'azw3'):
        raise RuntimeError('不支持此书籍格式')
    stat = source.stat()
    if not source.is_file() or not 0 < stat.st_size <= 512 * 1024 * 1024:
        raise RuntimeError('书籍为空或超过 512 MB')
    identifier = str(uuid.uuid4())
    directory = phone.root + '/' + identifier
    filename = 'book.' + format_
    phone.mkdir(directory)
    committed = False
    try:
        with source.open('rb') as stream:
            digest = phone.write(directory + '/' + filename, iter(lambda: stream.read(128 * 1024), b''), stat.st_size, item['title'])
        after = source.stat()
        if (after.st_size, after.st_mtime_ns) != (stat.st_size, stat.st_mtime_ns):
            raise RuntimeError('电脑上的书籍在传输期间发生修改，请重试')
        manifest = {'version': 1, 'id': identifier, 'filename': filename, 'title': item['title'],
                    'author': item.get('author', ''), 'bytes': stat.st_size, 'sha256': digest}
        data = json.dumps(manifest, ensure_ascii=False).encode()
        phone.write(directory + '/transfer.json', [data], len(data), item['title'])
        committed = True
        return identifier
    finally:
        if not committed:
            phone.discard(directory, filename)


# 每次传输只接受一台已安装 MioLib 的 USB 设备，防止不小心发送到其他手机。
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner', required=True)
    parser.add_argument('--pipe', required=True)
    parser.add_argument('--manifest')
    args = parser.parse_args()
    runner = subprocess.check_output(['wslpath', '-u', args.runner], text=True).strip()
    phones, chosen = [], None
    with usb_bridge(runner, args.pipe) as path:
        try:
            for udid in usb_devices(path):
                phone = Phone(udid)
                phones.append(phone)
                app = phone.find_app()
                if app:
                    if chosen:
                        raise RuntimeError('检测到多台装有 MioLib 的手机，请只连接需要接收的一台')
                    chosen = (phone, app)
            if not chosen:
                raise RuntimeError('未找到 USB 连接的 MioLib。请连接并解锁 iPhone、信任电脑，确认已安装 MioLib')
            phone, app = chosen
            phone.open_documents(app)
            event('connected', name='MioLib')
            if not args.manifest:
                return
            local = subprocess.check_output(['wslpath', '-u', args.manifest], text=True).strip()
            phone.cancelled = lambda: Path(local + '.cancel').exists()
            items = json.loads(Path(local).read_text(encoding='utf-8'))
            sent, failed = [], []
            for index, item in enumerate(items):
                if phone.cancelled():
                    event('cancelled')
                    break
                event('book', index=index + 1, count=len(items), title=item['title'])
                try:
                    identifier = send_book(phone, item)
                    sent.append(identifier)
                    event('sent', title=item['title'], id=identifier, calibre_id=item.get('calibre_id'))
                except TransferCancelled:
                    event('cancelled')
                    break
                except Exception as error:
                    failed.append({'title': item.get('title', ''), 'calibre_id': item.get('calibre_id'), 'error': str(error)})
                    event('failed', **failed[-1])
            event('complete', sent=len(sent), failures=failed)
        finally:
            for phone in reversed(phones):
                phone.close()


# 顶层只输出明确错误，不泄露协议应答或完整安装应用列表。
if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        event('error', message=str(error))
        raise SystemExit(1)

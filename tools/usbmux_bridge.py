"""WSL 用户态 USBMux 桥接：复用 Windows Apple 驱动，避免管理员 USB 重绑定。"""
from pathlib import Path
import os
import selectors
import socketserver
import subprocess

# socket 只对当前 WSL 用户开放，不监听任何局域网 TCP 端口。
runtime = Path.home() / ".cache" / "MioLibUSB"
runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
socket_path = runtime / "usbmuxd.sock"
if socket_path.exists():
    socket_path.unlink()
helper = subprocess.check_output(["wslpath", "-w", str(Path(__file__).with_name("windows_usbmux_pipe.py"))], text=True).strip()
windows_python = "/mnt/d/python/python.exe"

# 每个设备通道独立转发，支持安装期间并行建立锁定、AFC 和启动服务通道。
class Bridge(socketserver.BaseRequestHandler):
    def handle(self):
        child = subprocess.Popen([windows_python, "-u", helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        selector = selectors.DefaultSelector()
        selector.register(self.request, selectors.EVENT_READ, "phone")
        selector.register(child.stdout, selectors.EVENT_READ, "windows")
        try:
            running = True
            while running:
                for event, _ in selector.select(timeout=10):
                    if event.data == "phone":
                        chunk = self.request.recv(65536)
                        if not chunk:
                            running = False
                            break
                        child.stdin.write(chunk)
                        child.stdin.flush()
                    else:
                        chunk = os.read(child.stdout.fileno(), 65536)
                        if not chunk:
                            running = False
                            break
                        self.request.sendall(chunk)
                if child.poll() is not None:
                    break
        except (OSError, BrokenPipeError):
            pass
        finally:
            selector.close()
            child.terminate()
            child.wait(timeout=5)

# 关闭桥接后清理自身 socket，Windows 文件共享连接始终由原有服务管理。
class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
with Server(str(socket_path), Bridge) as server:
    os.chmod(socket_path, 0o600)
    print(f"USBMUXD_SOCKET_ADDRESS=UNIX:{socket_path}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        socket_path.unlink(missing_ok=True)

"""仅连接本机 Apple Mobile Device 服务，为 WSL 转发 USB 二进制通道。"""
import os
import socket
import sys
import threading

# 保留原始二进制字节，不使用文本行缓冲或 Windows 换行转换。
if os.name == 'nt':
    import msvcrt
    msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
    msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
connection = socket.create_connection(('127.0.0.1', 27015), timeout=10)
connection.settimeout(None)


# 仅转发本地驱动的 stdin/stdout，不监听网络，也不接管或重绑 USB 驱动。
def forward_input():
    try:
        while data := sys.stdin.buffer.read1(65536):
            connection.sendall(data)
    except (OSError, ValueError):
        pass
    finally:
        try:
            connection.shutdown(socket.SHUT_WR)
        except OSError:
            pass


# 输入结束会关闭对应服务连接；后台线程不阻止辅助进程退出。
threading.Thread(target=forward_input, daemon=True).start()
try:
    while data := connection.recv(65536):
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
except (OSError, BrokenPipeError):
    pass
finally:
    connection.close()

"""通过标准输入输出连接 Windows 已有的 Apple Mobile Device 服务。"""
import os
import socket
import sys
import threading

# 协议全程使用二进制，避免 Windows 自动转换换行。
if os.name == "nt":
    import msvcrt
    msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
    msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)

# 每个 WSL socket 对应一个原生 Apple 服务连接，无须改变 USB 驱动绑定。
connection = socket.create_connection(("127.0.0.1", 27015), timeout=10)
connection.settimeout(None)
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

# 退出时让操作系统关闭 socket；后台输入线程不阻止进程结束。
threading.Thread(target=forward_input, daemon=True).start()
try:
    while data := connection.recv(65536):
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
except (OSError, BrokenPipeError):
    pass
finally:
    connection.close()

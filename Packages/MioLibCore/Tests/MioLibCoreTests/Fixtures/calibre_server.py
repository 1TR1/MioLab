"""仅监听回环地址的 OPDS 网络测试服务器，不访问实际 Calibre 书库。"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
from urllib.parse import urlsplit
from urllib.request import parse_http_list, parse_keqv_list

BOOK = "第一章 联通\n这是从 Calibre 下载的中文样书。\n第二章 继续\n导入完成后可以离线阅读。".encode()


# 使用真实 HTTP 挑战验证系统 Basic / Digest 处理，不在客户端注入测试专用逻辑。
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def authenticated(self, kind):
        header = self.headers.get("Authorization", "")
        if kind == "basic":
            return header == "Basic cmVhZGVyOnRlc3QtcGFzcw=="
        if not header.startswith("Digest "):
            return False
        fields = parse_keqv_list(parse_http_list(header[7:]))
        md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
        first = md5("reader:MioLibSmoke:test-pass")
        second = md5(f"GET:{fields.get('uri', '')}")
        expected = md5(f"{first}:miolibnonce:{fields.get('nc', '')}:{fields.get('cnonce', '')}:auth:{second}")
        return fields.get("username") == "reader" and fields.get("response") == expected

    def do_GET(self):
        path = urlsplit(self.path).path
        # 身份验证仅作用于带认证前缀的目录和下载，模拟 Calibre 的完整保护范围。
        kind = next((name for name in ("basic", "digest") if path.startswith("/" + name + "/")), None)
        if kind and not self.authenticated(kind):
            self.send_response(401)
            challenge = 'Basic realm="MioLibSmoke"' if kind == "basic" else 'Digest realm="MioLibSmoke", nonce="miolibnonce", qop="auth", algorithm=MD5'
            self.send_header("WWW-Authenticate", challenge)
            self.end_headers()
            return
        # 模拟分页、保留书库 ID 的中文搜索、无扩展名下载与跨域重定向。
        prefix = "/" + kind if kind else ""
        if path.endswith("/opds") or "/opds/search/" in path:
            body = f'''<feed xmlns="http://www.w3.org/2005/Atom"><title>测试书库</title>
              <link rel="search" type="application/atom+xml" href="{prefix}/opds/search/{{searchTerms}}?library_id=sample"/>
              <link rel="next" href="{prefix}/page2"/>
              <entry><id>urn:calibre:1</id><title>中文样书</title><author><name>示例作者</name></author>
                <link rel="http://opds-spec.org/acquisition" type="text/plain" href="{prefix}/get/txt/1"/>
              </entry></feed>'''.encode()
            content_type = "application/atom+xml"
        elif path.endswith("/page2"):
            body = b'<feed xmlns="http://www.w3.org/2005/Atom"><title>Page 2</title></feed>'
            content_type = "application/atom+xml"
        elif path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://localhost:1/private")
            self.end_headers()
            return
        elif path == "/huge":
            self.send_response(200)
            self.send_header("Content-Length", str(513 * 1024 * 1024))
            self.end_headers()
            return
        elif path == "/slow/get/txt/1":
            self.send_response(200)
            self.send_header("Content-Length", str(2 * 1024 * 1024))
            self.end_headers()
            try:
                for _ in range(512):
                    self.wfile.write(b"a" * 4096)
                    self.wfile.flush()
                    time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        elif "/get/txt/" in path:
            body, content_type = BOOK, "text/plain"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# 系统分配空闲端口，通过标准输出告知 XCTest；进程结束后自动释放端口。
if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(server.server_port, flush=True)
    server.serve_forever()

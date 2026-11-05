#!/usr/bin/env python3
"""把 Models/ 下的 GGUF 通过本机 HTTP 服务分发给 iPhone（App 内「模型」页填地址即可）。

用法：
    python3 scripts/serve_models.py            # 监听 0.0.0.0:8899
    python3 scripts/serve_models.py --port 9000

App 内填写示例：http://192.168.1.10:8899/qwen35-4b-Q4_K_M.gguf
服务支持 Range 请求，App 断点续传下载大文件不会从头开始。
"""
from __future__ import annotations

import argparse
import http.server
import os
import re
import socket
import socketserver
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "Models")
RANGE_RE = re.compile(r"bytes=(\d*)-(\d*)")


def local_ips() -> list[str]:
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("223.5.5.5", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
        addr = info[4][0]
        if not addr.startswith("127."):
            ips.add(addr)
    return sorted(ips)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=MODELS, **kwargs)

    def do_GET(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).lstrip("/")
        full = os.path.realpath(os.path.join(MODELS, path))
        if not full.startswith(os.path.realpath(MODELS) + os.sep):
            self.send_error(403)
            return
        if not os.path.isfile(full):
            super().do_GET()
            return
        size = os.path.getsize(full)
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng:
            m = RANGE_RE.match(rng.strip())
            if m:
                if m.group(1):
                    start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
        length = end - start + 1
        self.send_response(206 if rng else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if rng:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(full, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    args = ap.parse_args()
    print("模型目录:", MODELS)
    for f in sorted(os.listdir(MODELS)):
        if f.endswith(".gguf"):
            print("  - %-40s %8.1f MB" % (f, os.path.getsize(os.path.join(MODELS, f)) / 1024 / 1024))
    print("\n在 iPhone 的 App「模型」页填写（手机需与 Mac 同一 Wi-Fi）：")
    for ip in local_ips():
        print("  http://%s:%d/<上面的文件名>" % (ip, args.port))
    print("\n按 Ctrl+C 停止。\n")
    with Server(("0.0.0.0", args.port), Handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()

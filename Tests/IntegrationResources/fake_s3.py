#!/usr/bin/env python3
# 集成测试用的最小假 S3（path-style，只监听 127.0.0.1）：im-server 的 objstore 客户端和 SDK 的预签名 PUT、GET 都打到这里。
# 不校验签名（签名逻辑在 tianting-server 的 objstore 测试里验），只做 F-FILE-01 用到的操作：
# PUT（含 x-amz-copy-source 条件复制）、HEAD、GET（Range + If-Match、response-content-* 查询参数）、DELETE、ListObjectsV2。
# 用法：python3 -I fake_s3.py；第一行输出 "port N"。只用标准库。日志不打印请求（地址里有签名）。
import hashlib
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit
from xml.sax.saxutils import escape

objects = {}  # (bucket, key) -> (body, content_type, etag)
lock = threading.Lock()
stats = {'put_bytes': 0, 'puts': 0, 'gets': 0}


def split(path):
    parts = unquote(path).lstrip('/').split('/', 1)
    return parts[0], (parts[1] if len(parts) > 1 else '')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):  # 不打印：查询串里有签名
        pass

    def reply(self, status, body=b'', headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def error(self, status, code):
        self.reply(status, f'<Error><Code>{code}</Code></Error>'.encode(), {'Content-Type': 'application/xml'})

    def do_PUT(self):
        u = urlsplit(self.path)
        bucket, key = split(u.path)
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n) if n else b''
        src = self.headers.get('x-amz-copy-source')
        if u.path == '/__stats':
            return self.reply(200, repr(stats).encode())
        with lock:
            if src:
                sb, sk = split(src)
                cur = objects.get((sb, sk))
                if cur is None:
                    return self.error(404, 'NoSuchKey')
                want = self.headers.get('x-amz-copy-source-if-match')
                if want and want != cur[2]:
                    return self.error(412, 'PreconditionFailed')
                ctype = self.headers.get('Content-Type') or cur[1]
                etag = '"' + hashlib.md5(cur[0] + b'copy').hexdigest() + '"'
                objects[(bucket, key)] = (cur[0], ctype, etag)
                xml = f'<CopyObjectResult><ETag>{escape(etag)}</ETag></CopyObjectResult>'.encode()
                return self.reply(200, xml, {'Content-Type': 'application/xml'})
            etag = '"' + hashlib.md5(body).hexdigest() + '"'
            objects[(bucket, key)] = (body, self.headers.get('Content-Type') or 'application/octet-stream', etag)
            stats['put_bytes'] += len(body)
            stats['puts'] += 1
        self.reply(200, b'', {'ETag': etag})

    def do_HEAD(self):
        bucket, key = split(urlsplit(self.path).path)
        with lock:
            cur = objects.get((bucket, key))
        if cur is None:
            return self.reply(404)
        self.send_response(200)
        self.send_header('Content-Length', str(len(cur[0])))
        self.send_header('ETag', cur[2])
        self.send_header('Content-Type', cur[1])
        self.end_headers()

    def do_GET(self):
        u = urlsplit(self.path)
        q = parse_qs(u.query)
        bucket, key = split(u.path)
        if u.path == '/__stats':
            return self.reply(200, repr(stats).encode())
        if not key and 'list-type' in q:
            prefix = q.get('prefix', [''])[0]
            with lock:
                keys = sorted(k for (b, k) in objects if b == bucket and k.startswith(prefix))
            items = ''.join(f'<Contents><Key>{escape(k)}</Key></Contents>' for k in keys)
            xml = f'<ListBucketResult><IsTruncated>false</IsTruncated>{items}</ListBucketResult>'.encode()
            return self.reply(200, xml, {'Content-Type': 'application/xml'})
        with lock:
            cur = objects.get((bucket, key))
            stats['gets'] += 1
        if cur is None:
            return self.error(404, 'NoSuchKey')
        want = self.headers.get('If-Match')
        if want and want != cur[2]:
            return self.error(412, 'PreconditionFailed')
        body = cur[0]
        status = 200
        rng = self.headers.get('Range')
        if rng and rng.startswith('bytes='):
            a, _, b = rng[6:].partition('-')
            start = int(a or 0)
            end = min(int(b) if b else len(body) - 1, len(body) - 1)
            body = body[start:end + 1]
            status = 206
        headers = {'ETag': cur[2], 'Content-Type': q.get('response-content-type', [cur[1]])[0]}
        if 'response-content-disposition' in q:
            headers['Content-Disposition'] = q['response-content-disposition'][0]
        self.reply(status, body, headers)

    def do_DELETE(self):
        bucket, key = split(urlsplit(self.path).path)
        with lock:
            objects.pop((bucket, key), None)
        self.reply(204)


def main():
    srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    srv.daemon_threads = True
    print(f'port {srv.server_address[1]}', flush=True)
    # 父进程退出（stdin 关闭）时自己退出，不留下进程。
    threading.Thread(target=lambda: (sys.stdin.read(), srv.shutdown()), daemon=True).start()
    srv.serve_forever()


if __name__ == '__main__':
    main()

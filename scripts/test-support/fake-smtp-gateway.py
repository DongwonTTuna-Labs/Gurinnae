#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

output = os.environ["FAKE_SMTP_OUTPUT"]
port = int(os.environ["FAKE_SMTP_PORT"])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        message = json.loads(body)
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(message, ensure_ascii=False, sort_keys=True) + "\n")
        count = sum(1 for _ in open(output, encoding="utf-8"))
        response = json.dumps({"providerMessageId": f"fake-{count}"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_):
        return


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

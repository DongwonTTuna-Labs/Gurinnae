#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        message_id = request.get("providerMessageId")
        if self.path != "/communication/sms/poll" or not isinstance(message_id, str):
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(
            {
                "providerMessageId": message_id,
                "assertedState": "DELIVERED",
                "providerEvidenceDigest": "d" * 64,
            }
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer(("127.0.0.1", int(os.environ["FAKE_POLL_PORT"])), Handler).serve_forever()

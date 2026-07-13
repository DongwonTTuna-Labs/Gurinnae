#!/usr/bin/env python3
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ["FAKE_SOURCE_PORT"])
OUTPUT = os.environ["FAKE_SOURCE_OUTPUT"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("x-gurine-egress-caller") != "ingest-worker":
            self.send_error(403)
            return
        if not self.headers.get("x-gurine-source-id"):
            self.send_error(400)
            return
        target = self.headers.get("x-gurine-egress-target", "")
        parsed = urlparse(target)
        operation = parse_qs(parsed.query).get("operationId", [""])[0]
        if parsed.scheme != "https" or not operation:
            self.send_error(400)
            return
        with open(OUTPUT, "a", encoding="utf-8") as output:
            output.write(json.dumps({"operationId": operation, "target": target}, sort_keys=True) + "\n")
        if operation.endswith("-manifest"):
            body = json.dumps(
                {
                    "manifest_version": "1",
                    "publisher": "Runtime Official Publisher",
                    "generated_at": "2026-07-12T00:00:00Z",
                    "documents": [
                        {
                            "external_id": operation + "-document",
                            "title": "Runtime official document",
                            "url": "https://official.example.test/document/" + operation,
                            "published_at": "2026-07-11T00:00:00Z",
                            "content_type": "application/pdf",
                            "revision": "1",
                        }
                    ],
                },
                separators=(",", ":"),
            ).encode()
            content_type = "application/json"
        elif operation in ("alio-document", "audit-result-document"):
            body = b"%PDF-1.7\nRuntime official document\n%%EOF\n"
            content_type = "application/pdf"
        elif operation.startswith("contract-") or operation.startswith("notice-"):
            if operation.startswith("contract-"):
                item = {
                    "untyCntrctNo": "CN-" + operation,
                    "cntrctNm": "Runtime contract " + operation,
                    "cntrctInsttNm": "Runtime Agency",
                    "cntrctInsttCd": "AGENCY-001",
                    "corpNm": "Runtime Supplier " + operation,
                    "bizno": hashlib.sha256(operation.encode()).hexdigest()[:10],
                    "thtmCntrctAmt": "1000000",
                    "cntrctCnclsDate": "20260712",
                }
            else:
                item = {
                    "bidNtceNo": "NT-" + operation,
                    "bidNtceOrd": "00",
                    "bidNtceNm": "Runtime notice " + operation,
                    "ntceInsttNm": "Runtime Agency",
                }
            body = json.dumps(
                {
                    "response": {
                        "header": {"resultCode": "00", "resultMsg": "OK"},
                        "body": {"items": {"item": [item]}, "numOfRows": 1000, "pageNo": 1, "totalCount": 1},
                    }
                },
                separators=(",", ":"),
            ).encode()
            content_type = "application/json"
        elif operation == "dart-corp-code":
            body = b"PK\x03\x04runtime-corp-code-xml"
            content_type = "application/zip"
        elif operation.startswith("dart-"):
            body = json.dumps(
                {"status": "000", "message": "OK", "list": [{
                    "corp_code": hashlib.sha256(operation.encode()).hexdigest()[:8],
                    "corp_name": "Runtime DART " + operation,
                    "rcept_no": "R-" + operation,
                    "report_nm": "Runtime report",
                    "rcept_dt": "20260712",
                    "account_id": "revenue",
                    "account_nm": "Revenue",
                }]},
                separators=(",", ":"),
            ).encode()
            content_type = "application/json"
        else:
            body = json.dumps({"status": "OK", "records": []}, separators=(",", ":")).encode()
            content_type = "application/json"
        self.send_response(200)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        return


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

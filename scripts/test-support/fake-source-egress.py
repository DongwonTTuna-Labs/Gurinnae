#!/usr/bin/env python3
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ["FAKE_SOURCE_PORT"])
OUTPUT = os.environ["FAKE_SOURCE_OUTPUT"]
PPS_SANCTIONS_CSV = (
    "계약법구분,기관,법인등록번호,사업자등록번호,소관구분,"
    "시행규칙76조별표2,시행규칙76조별표2명,업체,제재근거법률,"
    "제재기간월수,제재기간일수,제재시작일자,제재입력일시,"
    "제재종료일자,조달업무영역,조문명,조항호,처분상태\n"
    "국가계약법,가상 조달기관,0000000000000,0000000000,중앙,"
    "1,가상 사유,가상 제재업체,가상 법률,1,0,20260801,"
    "202608010900,20260831,물품,가상 조문,가상 조항,유효\n"
).encode()
OFFICIAL_PDF = b"%PDF-1.7\nRuntime official document\n%%EOF\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("x-gurine-egress-caller") != "ingest-worker":
            self.send_error(403)
            return
        if not self.headers.get("x-gurine-source-id"):
            self.send_error(400)
            return
        if self.headers.get("x-gurine-source-fetch-request-sha256") != hashlib.sha256(b"").hexdigest():
            self.send_error(400)
            return
        target = self.headers.get("x-gurine-egress-target", "")
        parsed = urlparse(target)
        query = parse_qs(parsed.query)
        operation = query.get("operationId", [""])[0]
        if parsed.scheme != "https" or not operation:
            self.send_error(400)
            return
        if operation.startswith(("contract-", "notice-", "opening-", "award-")):
            expected_window = {
                "inqryDiv": ["1"],
                "inqryBgnDt": ["202607010000"],
                "inqryEndDt": ["202607122359"],
            }
            if any(query.get(key) != value for key, value in expected_window.items()):
                self.send_error(400)
                return
        if operation in ("dart-executive-status", "dart-major-shareholder-status"):
            if query.get("corp_code") != ["00990001"] or query.get("bsns_year") != ["2026"]:
                self.send_error(400)
                return
            if query.get("reprt_code") not in (["11011"], ["11014"]):
                self.send_error(400)
                return
        if operation == "dart-company" and query.get("corp_code") != ["00990001"]:
            self.send_error(400)
            return
        if operation == "dart-disclosures":
            expected_window = {"bgn_de": ["20260701"], "end_de": ["20260712"]}
            if any(query.get(key) != value for key, value in expected_window.items()):
                self.send_error(400)
                return
        if operation == "dart-financial-statements":
            expected_parameters = {
                "corp_code": ["00990001"],
                "bsns_year": ["2026"],
                "reprt_code": ["11011"],
                "fs_div": ["CFS"],
            }
            if any(query.get(key) != value for key, value in expected_parameters.items()):
                self.send_error(400)
                return
        with open(OUTPUT, "a", encoding="utf-8") as output:
            output.write(json.dumps({"operationId": operation, "target": target}, sort_keys=True) + "\n")
        if operation == "pps-sanctions-manifest":
            body = json.dumps(
                {
                    "manifest_version": "1",
                    "publisher": "Runtime PPS Official Report Fixture",
                    "generated_at": "2026-08-01T00:00:00Z",
                    "documents": [
                        {
                            "external_id": "pps-sanctions-runtime-csv",
                            "title": "Runtime sanctions CSV fixture",
                            "url": "https://fixture.invalid/pps-sanctions/sanctions.csv",
                            "published_at": "2026-08-01T00:00:00Z",
                            "content_type": "text/csv",
                            "revision": "fixture-only-1",
                            "sha256": hashlib.sha256(PPS_SANCTIONS_CSV).hexdigest(),
                        }
                    ],
                },
                separators=(",", ":"),
            ).encode()
            content_type = "application/json"
        elif operation.endswith("-manifest"):
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
                            "sha256": hashlib.sha256(OFFICIAL_PDF).hexdigest(),
                        }
                    ],
                },
                separators=(",", ":"),
            ).encode()
            content_type = "application/json"
        elif operation == "pps-sanctions-csv":
            body = PPS_SANCTIONS_CSV
            content_type = "text/csv"
        elif operation in ("alio-document", "audit-result-document"):
            body = OFFICIAL_PDF
            content_type = "application/pdf"
        elif operation.startswith("opening-") or operation.startswith("award-"):
            item = {
                "bidNtceNo": "NT-" + operation,
                "bidNtceOrd": "00",
                "bidClsfcNo": "00",
                "rbidNo": "000",
                "bidNtceNm": "Runtime bid result " + operation,
                "prtcptCnum": "3",
                "dminsttCd": "AGENCY-001",
                "dminsttNm": "Runtime Agency",
            }
            if operation.startswith("opening-"):
                item.update(
                    {
                        "opengDt": "202607121000",
                        "progrsDivCdNm": "개찰 완료",
                        "inptDt": "202607121005",
                        "opengRsltNtcCntnts": "Runtime raw opening notice",
                        "opengCorpInfo": "opaque runtime participant text",
                    }
                )
            else:
                item.update(
                    {
                        "bidwinnrNm": "Runtime Award Supplier",
                        "bidwinnrBizno": hashlib.sha256(operation.encode()).hexdigest()[:10],
                        "sucsfbidAmt": "1000000",
                        "sucsfbidRate": "87.745",
                        "rlOpengDt": "202607121000",
                        "fnlSucsfDate": "20260712",
                        "rgstDt": "202607121100",
                    }
                )
            body = json.dumps(
                {
                    "response": {
                        "header": {"resultCode": "00", "resultMsg": "OK"},
                        "body": {
                            "items": {"item": [item]},
                            "numOfRows": 1000,
                            "pageNo": 1,
                            "totalCount": 1,
                        },
                    }
                },
                separators=(",", ":"),
            ).encode()
            content_type = "application/json"
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
        elif operation in ("dart-executive-status", "dart-major-shareholder-status"):
            item = {
                "corp_code": hashlib.sha256(operation.encode()).hexdigest()[:8],
                "corp_name": "Runtime DART " + operation,
                "rcept_no": "R-" + operation,
                "nm": "Runtime disclosed person",
            }
            if operation == "dart-executive-status":
                item.update({"ofcps": "사외이사", "sexdstn": "비저장", "birth_ym": "비저장"})
            else:
                item.update({"relate": "비저장"})
            body = json.dumps(
                {"status": "000", "message": "OK", "list": [item]},
                separators=(",", ":"),
            ).encode()
            content_type = "application/json"
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

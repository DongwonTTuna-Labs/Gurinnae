from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath
from xml.etree import ElementTree as ET

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
EXPECTED = ROOT / "expected"
SCHEMA = json.loads((ROOT / "extraction-result.schema.json").read_text(encoding="utf-8"))
VALIDATOR = Draft202012Validator(SCHEMA)
PDFINFO_RE = re.compile(r"^(Pages|Page size|Encrypted):\s*(.+)$", re.MULTILINE)
OLE_MAGIC = bytes.fromhex("D0CF11E0A1B11AE1")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def normalize_text(value: str) -> str:
    value = unicodedata.normalize("NFC", value.replace("\r\n", "\n").replace("\r", "\n"))
    lines = []
    for line in value.split("\n"):
        line = re.sub(r"[\t\f\v ]+", " ", line).strip()
        if line:
            lines.append(line)
    return "\n".join(lines)


def stable_id(prefix: str, document_sha: str, locator_kind: str, locator_value: str, text: str = "") -> str:
    material = "\0".join([document_sha, locator_kind, locator_value, normalize_text(text)]).encode("utf-8")
    return f"{prefix}-{hashlib.sha256(material).hexdigest()[:20]}"


def locator(kind: str, value: str) -> dict:
    return {"kind": kind, "value": value}


def empty_result(path: Path, media_type: str, parser_id: str, parser_version: str, status: str, warnings: list[str], rejection: str | None = None) -> dict:
    return {
        "documentSha256": sha256_file(path),
        "mediaType": media_type,
        "parserId": parser_id,
        "parserVersion": parser_version,
        "status": status,
        "pages": [],
        "warnings": warnings,
        "rejectionCode": rejection,
    }


def run_tool(args: list[str], *, cwd: Path | None = None, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    command = list(args)
    if command and shutil.which(command[0]) is None:
        pinned_roots = [
            Path(os.environ["GURINNAE_PARSER_BIN"]) if os.environ.get("GURINNAE_PARSER_BIN") else None,
            Path("/opt/parser/bin"),
            Path.home() / ".codex/toolchains/gurinnae-parser-25.06.0-5.5.0/bin",
            Path.home() / ".codex/authority/gurine-v13-960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5/parser-tools/bin",
        ]
        for root in pinned_roots:
            if root is None:
                continue
            candidate = root / command[0]
            if candidate.is_file() and os.access(candidate, os.X_OK):
                command[0] = str(candidate)
                break
    environment = os.environ.copy()
    if not environment.get("TESSDATA_PREFIX"):
        for candidate in (
            Path("/opt/parser/share/tessdata"),
            Path.home() / ".codex/authority/gurine-v13-960687b445edee3/parser-tools/share/tessdata",
        ):
            if (candidate / "eng.traineddata").is_file():
                environment["TESSDATA_PREFIX"] = str(candidate.parent)
                break
    return subprocess.run(command, cwd=cwd, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)


def tool_version(command: list[str], pattern: str) -> str:
    proc = run_tool(command, timeout=10)
    output = (proc.stdout + "\n" + proc.stderr).strip()
    match = re.search(pattern, output)
    if proc.returncode != 0 or not match:
        raise RuntimeError(f"cannot resolve tool version: {' '.join(command)}: {output[:300]}")
    return match.group(1)


def safe_zip(path: Path) -> tuple[zipfile.ZipFile | None, str | None]:
    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        return None, "ZIP_INVALID"
    infos = archive.infolist()
    names: set[str] = set()
    total = 0
    if len(infos) > 10_000:
        archive.close(); return None, "ZIP_TOO_MANY_ENTRIES"
    for info in infos:
        name = info.filename.replace("\\", "/")
        parts = PurePosixPath(name).parts
        if not name or name.startswith("/") or re.match(r"^[A-Za-z]:", name) or ".." in parts:
            archive.close(); return None, "ZIP_PATH_TRAVERSAL"
        if name in names:
            archive.close(); return None, "ZIP_DUPLICATE_ENTRY"
        names.add(name)
        mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(mode):
            archive.close(); return None, "ZIP_SYMLINK_ENTRY"
        if info.flag_bits & 0x1:
            archive.close(); return None, "ENCRYPTED_DOCUMENT"
        total += info.file_size
        if total > 536_870_912:
            archive.close(); return None, "ZIP_UNCOMPRESSED_SIZE_LIMIT"
        if info.compress_size and info.file_size / max(info.compress_size, 1) > 100:
            archive.close(); return None, "ZIP_BOMB"
    return archive, None


def reject_external_relationships(archive: zipfile.ZipFile) -> str | None:
    for name in archive.namelist():
        if not name.endswith(".rels"):
            continue
        data = archive.read(name)
        upper = data.upper()
        if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
            return "XML_DTD_OR_ENTITY"
        try:
            root = ET.fromstring(data)
        except ET.ParseError:
            return "OOXML_RELATIONSHIP_INVALID"
        for element in root.iter():
            if element.attrib.get("TargetMode", "").lower() == "external":
                return "OOXML_EXTERNAL_RELATIONSHIP"
    return None


def validate_output(result: dict) -> None:
    errors = sorted(VALIDATOR.iter_errors(result), key=lambda error: list(error.absolute_path))
    if errors:
        detail = "; ".join(f"{'/'.join(map(str, e.absolute_path)) or '<root>'}: {e.message}" for e in errors[:8])
        raise AssertionError(f"extraction result schema failure: {detail}")


def csv_result(path: Path) -> dict:
    document_sha = sha256_file(path)
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = [[normalize_text(cell) for cell in row] for row in csv.reader(handle)]
    table_locator = "csv:rows=1-{};columns=1-{}".format(len(rows), max(map(len, rows), default=0))
    table_rows = []
    for row_index, row in enumerate(rows, 1):
        cells = []
        for column_index, text in enumerate(row, 1):
            value = f"row={row_index};column={column_index}"
            cells.append({"text": text, "row": row_index, "column": column_index, "locator": locator("CSV_ROW_COLUMN", value)})
        table_rows.append(cells)
    result = {
        "documentSha256": document_sha,
        "mediaType": "text/csv",
        "parserId": "csv",
        "parserVersion": "1.4.0-reference-v1",
        "status": "EXTRACTED",
        "pages": [{
            "index": 0, "width": None, "height": None, "blocks": [],
            "tables": [{"id": stable_id("tbl", document_sha, "CSV_ROW_COLUMN", table_locator), "locator": locator("CSV_ROW_COLUMN", table_locator), "rows": table_rows}],
        }],
        "warnings": [], "rejectionCode": None,
    }
    validate_output(result); return result


def xml_xpath_records(root: ET.Element) -> list[tuple[str, str]]:
    records: list[tuple[str, str]] = []
    def local(tag: str) -> str: return tag.rsplit("}", 1)[-1]
    def walk(node: ET.Element, path: str) -> None:
        children = list(node)
        counts: dict[str, int] = {}
        for child in children:
            tag = local(child.tag); counts[tag] = counts.get(tag, 0) + 1
            walk(child, f"{path}/{tag}[{counts[tag]}]")
        text = normalize_text(node.text or "")
        if text and not children:
            records.append((path, text))
    walk(root, f"/{local(root.tag)}[1]")
    return records


def xml_result(path: Path) -> dict:
    data = path.read_bytes(); upper = data.upper()
    if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
        return empty_result(path, "application/xml", "xml", "0.41.0-reference-v1", "REJECTED", [], "XML_DTD_OR_ENTITY")
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return empty_result(path, "application/xml", "xml", "0.41.0-reference-v1", "REJECTED", [], "XML_INVALID")
    document_sha = sha256_bytes(data)
    blocks = []
    for xpath, text in xml_xpath_records(root):
        blocks.append({"id": stable_id("blk", document_sha, "XML_XPATH", xpath, text), "kind": "PARAGRAPH", "text": text, "locator": locator("XML_XPATH", xpath), "confidence": None})
    result = {"documentSha256": document_sha, "mediaType": "application/xml", "parserId": "xml", "parserVersion": "0.41.0-reference-v1", "status": "EXTRACTED", "pages": [{"index": 0, "width": None, "height": None, "blocks": blocks, "tables": []}], "warnings": [], "rejectionCode": None}
    validate_output(result); return result


def xlsx_result(path: Path) -> dict:
    archive, rejection = safe_zip(path)
    if rejection: return empty_result(path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx", "0.35.0-reference-v1", "REJECTED", [], rejection)
    assert archive is not None
    try:
        rel_rejection = reject_external_relationships(archive)
        if rel_rejection: return empty_result(path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx", "0.35.0-reference-v1", "REJECTED", [], rel_rejection)
        ns = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main", "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships", "p": "http://schemas.openxmlformats.org/package/2006/relationships"}
        workbook = ET.fromstring(archive.read("xl/workbook.xml")); rels = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        relation_targets = {rel.attrib["Id"]: rel.attrib["Target"] for rel in rels}
        shared: list[str] = []
        if "xl/sharedStrings.xml" in archive.namelist():
            shared_root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
            for si in shared_root.findall("x:si", ns): shared.append(normalize_text("".join(t.text or "" for t in si.iterfind(".//x:t", ns))))
        document_sha = sha256_file(path); pages=[]
        for sheet_index, sheet in enumerate(workbook.findall(".//x:sheets/x:sheet", ns)):
            sheet_name=sheet.attrib["name"]; rid=sheet.attrib[f"{{{ns['r']}}}id"]; target=relation_targets[rid]
            target = target.lstrip("/")
            if not target.startswith("xl/"): target = "xl/" + target
            root=ET.fromstring(archive.read(target)); rows=[]
            for row in root.findall(".//x:sheetData/x:row", ns):
                cells=[]
                for cell in row.findall("x:c", ns):
                    ref=cell.attrib["r"]; typ=cell.attrib.get("t"); text=""
                    if typ=="inlineStr": text=normalize_text("".join(t.text or "" for t in cell.iterfind(".//x:t", ns)))
                    else:
                        value=cell.find("x:v", ns); raw=value.text if value is not None else ""
                        if typ=="s" and raw: text=shared[int(raw)]
                        else: text=normalize_text(raw or "")
                    match=re.match(r"([A-Z]+)([0-9]+)", ref); col_letters,row_num=match.groups() if match else ("A","0")
                    column=0
                    for ch in col_letters: column=column*26+(ord(ch)-64)
                    loc=f"sheet={sheet_name};cell={ref}"
                    cells.append({"text":text,"row":int(row_num),"column":column,"locator":locator("XLSX_CELL",loc)})
                rows.append(cells)
            tloc=f"sheet={sheet_name};range={root.find('.//x:dimension',ns).attrib.get('ref','') if root.find('.//x:dimension',ns) is not None else ''}"
            pages.append({"index":sheet_index,"width":None,"height":None,"blocks":[],"tables":[{"id":stable_id('tbl',document_sha,'XLSX_CELL',tloc),"locator":locator("XLSX_CELL",tloc),"rows":rows}]})
        result={"documentSha256":document_sha,"mediaType":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","parserId":"xlsx","parserVersion":"0.35.0-reference-v1","status":"EXTRACTED","pages":pages,"warnings":[],"rejectionCode":None}
        validate_output(result); return result
    finally: archive.close()


def docx_result(path: Path) -> dict:
    media="application/vnd.openxmlformats-officedocument.wordprocessingml.document"; archive,rejection=safe_zip(path)
    if rejection: return empty_result(path,media,"docx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],rejection)
    assert archive is not None
    try:
        rel=reject_external_relationships(archive)
        if rel: return empty_result(path,media,"docx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],rel)
        if "word/document.xml" not in archive.namelist(): return empty_result(path,media,"docx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],"DOCX_MAIN_DOCUMENT_MISSING")
        data=archive.read("word/document.xml"); upper=data.upper()
        if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper: return empty_result(path,media,"docx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],"XML_DTD_OR_ENTITY")
        root=ET.fromstring(data); ns={"w":"http://schemas.openxmlformats.org/wordprocessingml/2006/main"}; document_sha=sha256_file(path); blocks=[]
        for index,p in enumerate(root.findall(".//w:body/w:p",ns),1):
            text=normalize_text("".join(t.text or "" for t in p.iterfind(".//w:t",ns)))
            if not text: continue
            style=p.find("w:pPr/w:pStyle",ns); kind="HEADING" if style is not None and style.attrib.get(f"{{{ns['w']}}}val","").lower() in {"title","heading1","heading2"} else "PARAGRAPH"
            value=f"word/document.xml#/w:document/w:body/w:p[{index}]"
            blocks.append({"id":stable_id('blk',document_sha,'DOCX_PARAGRAPH',value,text),"kind":kind,"text":text,"locator":locator("DOCX_PARAGRAPH",value),"confidence":None})
        result={"documentSha256":document_sha,"mediaType":media,"parserId":"docx","parserVersion":"zip-8.6.0+quick-xml-0.41.0-reference-v1","status":"EXTRACTED","pages":[{"index":0,"width":None,"height":None,"blocks":blocks,"tables":[]}],"warnings":[],"rejectionCode":None}
        validate_output(result); return result
    finally: archive.close()


def hwpx_result(path: Path) -> dict:
    media="application/hwp+zip"; archive,rejection=safe_zip(path)
    if rejection: return empty_result(path,media,"hwpx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],rejection)
    assert archive is not None
    try:
        rel=reject_external_relationships(archive)
        if rel: return empty_result(path,media,"hwpx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],rel)
        document_sha=sha256_file(path); pages=[]; section_names=sorted(n for n in archive.namelist() if re.fullmatch(r"Contents/section[0-9]+\.xml",n))
        if not section_names: return empty_result(path,media,"hwpx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],"HWPX_SECTION_MISSING")
        for page_index,name in enumerate(section_names):
            data=archive.read(name); upper=data.upper()
            if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper: return empty_result(path,media,"hwpx","zip-8.6.0+quick-xml-0.41.0-reference-v1","REJECTED",[],"XML_DTD_OR_ENTITY")
            root=ET.fromstring(data); blocks=[]; p_index=0
            for element in root.iter():
                if element.tag.rsplit('}',1)[-1] != 'p': continue
                p_index+=1; text=normalize_text(''.join(element.itertext()))
                if not text: continue
                value=f"{name}#/section[1]/p[{p_index}]"
                blocks.append({"id":stable_id('blk',document_sha,'HWPX_XPATH',value,text),"kind":"PARAGRAPH","text":text,"locator":locator("HWPX_XPATH",value),"confidence":None})
            pages.append({"index":page_index,"width":None,"height":None,"blocks":blocks,"tables":[]})
        result={"documentSha256":document_sha,"mediaType":media,"parserId":"hwpx","parserVersion":"zip-8.6.0+quick-xml-0.41.0-reference-v1","status":"EXTRACTED","pages":pages,"warnings":[],"rejectionCode":None}
        validate_output(result); return result
    finally: archive.close()


def pdf_metadata(path: Path) -> tuple[int,float,float,bool]:
    proc=run_tool(["pdfinfo",str(path)],timeout=20)
    if proc.returncode != 0: raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
    pages_match=re.search(r"^Pages:\s+(\d+)",proc.stdout,re.MULTILINE); size_match=re.search(r"^Page size:\s+([0-9.]+) x ([0-9.]+) pts",proc.stdout,re.MULTILINE); encrypted_match=re.search(r"^Encrypted:\s+(\w+)",proc.stdout,re.MULTILINE)
    if not pages_match or not size_match: raise RuntimeError("pdfinfo metadata incomplete")
    return int(pages_match.group(1)),float(size_match.group(1)),float(size_match.group(2)),bool(encrypted_match and encrypted_match.group(1).lower()!="no")


def pdf_result(path: Path, versions: dict[str,str]) -> dict:
    data=path.read_bytes(); media="application/pdf"
    if not data.startswith(b"%PDF") or not data.rstrip().endswith(b"%%EOF"):
        return empty_result(path,media,"pdf","pdf-reference-v1","REJECTED",[],"PDF_TRUNCATED_OR_INVALID")
    try: pages,width,height,encrypted=pdf_metadata(path)
    except Exception: return empty_result(path,media,"pdf","pdf-reference-v1","REJECTED",[],"PDF_INVALID")
    if encrypted: return empty_result(path,media,"pdf","pdf-reference-v1","REJECTED",[],"ENCRYPTED_DOCUMENT")
    if pages>1000: return empty_result(path,media,"pdf","pdf-reference-v1","REJECTED",[],"TOO_MANY_PAGES")
    proc=run_tool(["pdftotext","-layout",str(path),"-"],timeout=60)
    if proc.returncode!=0: return empty_result(path,media,"pdf-digital",f"pdftotext-{versions['pdftotext']}","FAILED",["PDF_TEXT_EXTRACTION_FAILED"],"PDF_TEXT_EXTRACTION_FAILED")
    page_texts=proc.stdout.split("\f")[:pages]; normalized=[normalize_text(x) for x in page_texts]
    empty_count=sum(1 for x in normalized if not x); chars=sum(len(x) for x in normalized); needs_ocr=chars/max(pages,1)<20 or empty_count/max(pages,1)>0.8
    document_sha=sha256_bytes(data)
    if not needs_ocr:
        result_pages=[]
        for index,text in enumerate(normalized):
            blocks=[]
            if text:
                value=f"page={index+1};bbox=0,0,{width:.3f},{height:.3f};unit=pt"
                blocks.append({"id":stable_id('blk',document_sha,'PAGE_BBOX',value,text),"kind":"PARAGRAPH","text":text,"locator":locator("PAGE_BBOX",value),"confidence":None})
            result_pages.append({"index":index,"width":width,"height":height,"blocks":blocks,"tables":[]})
        result={"documentSha256":document_sha,"mediaType":media,"parserId":"pdf-digital","parserVersion":f"pdftotext-{versions['pdftotext']}","status":"EXTRACTED","pages":result_pages,"warnings":[],"rejectionCode":None}; validate_output(result); return result
    # OCR every page into TSV, preserving per-line pixel bounding boxes.
    result_pages=[]
    with tempfile.TemporaryDirectory(prefix="gurine-parser-") as temp:
        temp_path=Path(temp); prefix=temp_path/'page'
        render=run_tool(["pdftoppm","-png","-r","300",str(path),str(prefix)],timeout=60)
        if render.returncode!=0: return empty_result(path,media,"pdf-ocr",f"pdftoppm-{versions['pdftoppm']}+tesseract-{versions['tesseract']}","FAILED",["PDF_RENDER_FAILED"],"PDF_RENDER_FAILED")
        images=sorted(temp_path.glob('page-*.png'))
        if len(images)!=pages: return empty_result(path,media,"pdf-ocr",f"pdftoppm-{versions['pdftoppm']}+tesseract-{versions['tesseract']}","FAILED",["PDF_PAGE_COUNT_MISMATCH"],"PDF_PAGE_COUNT_MISMATCH")
        for index,image in enumerate(images):
            ocr=run_tool(["tesseract",str(image),"stdout","-l","kor+eng","--psm","6","tsv"],timeout=60)
            if ocr.returncode!=0: return empty_result(path,media,"pdf-ocr",f"pdftoppm-{versions['pdftoppm']}+tesseract-{versions['tesseract']}","FAILED",["OCR_FAILED"],"OCR_FAILED")
            lines: dict[tuple[int,int,int],list[dict]]={}
            reader=csv.DictReader(ocr.stdout.splitlines(),delimiter='\t')
            for row in reader:
                if row.get('level')!='5' or not normalize_text(row.get('text','')): continue
                key=(int(row['block_num']),int(row['par_num']),int(row['line_num']))
                lines.setdefault(key,[]).append(row)
            blocks=[]
            for line_no,key in enumerate(sorted(lines),1):
                words=lines[key]; text=normalize_text(' '.join(w['text'] for w in words)); left=min(int(w['left']) for w in words); top=min(int(w['top']) for w in words); right=max(int(w['left'])+int(w['width']) for w in words); bottom=max(int(w['top'])+int(w['height']) for w in words); confs=[float(w['conf']) for w in words if float(w['conf'])>=0]; confidence=round(sum(confs)/len(confs)/100,6) if confs else None
                value=f"page={index+1};bbox={left},{top},{right-left},{bottom-top};unit=px;dpi=300;line={line_no}"
                blocks.append({"id":stable_id('blk',document_sha,'PAGE_BBOX',value,text),"kind":"OCR_TEXT","text":text,"locator":locator("PAGE_BBOX",value),"confidence":confidence})
            result_pages.append({"index":index,"width":width,"height":height,"blocks":blocks,"tables":[]})
    result={"documentSha256":document_sha,"mediaType":media,"parserId":"pdf-ocr","parserVersion":f"pdftoppm-{versions['pdftoppm']}+tesseract-{versions['tesseract']}-kor+eng","status":"EXTRACTED","pages":result_pages,"warnings":["OCR_FALLBACK_USED","OCR_LANGUAGE_KOR_ENG"],"rejectionCode":None}; validate_output(result); return result


def extract(path: Path, versions: dict[str,str]) -> dict:
    data=path.read_bytes(); suffix=path.suffix.lower()
    if suffix=='.hwp' or data.startswith(OLE_MAGIC): return empty_result(path,"application/x-hwp","legacy-hwp","unsupported","REJECTED",[],"BINARY_HWP_UNSUPPORTED_REQUIRES_TRUSTED_CONVERSION")
    if suffix=='.csv': return csv_result(path)
    if suffix=='.xml': return xml_result(path)
    if suffix=='.xlsx': return xlsx_result(path)
    if suffix=='.docx': return docx_result(path)
    if suffix=='.hwpx': return hwpx_result(path)
    if suffix=='.pdf': return pdf_result(path,versions)
    return empty_result(path,"application/octet-stream","unknown","unknown","REJECTED",[],"UNSUPPORTED_MEDIA_TYPE")


def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument('--write-golden',action='store_true')
    parser.add_argument('--json-output',type=Path)
    args=parser.parse_args()
    versions={
      'pdftotext':tool_version(['pdftotext','-v'],r'pdftotext version ([0-9.]+)'),
      'pdftoppm':tool_version(['pdftoppm','-v'],r'pdftoppm version ([0-9.]+)'),
      'tesseract':tool_version(['tesseract','--version'],r'tesseract ([0-9.]+)'),
    }
    manifest=yaml.safe_load((ROOT/'fixture-manifest.yaml').read_text(encoding='utf-8'))
    cases=[]; golden_count=0
    for item in manifest['fixtures']:
        path=FIXTURES/item['file']; actual_sha=sha256_file(path)
        if actual_sha!=item['sha256']: raise AssertionError(f"{item['file']}: sha256 mismatch {actual_sha} != {item['sha256']}")
        result=extract(path,versions); validate_output(result)
        if result['status']!=item['expected']: raise AssertionError(f"{item['file']}: {result['status']} != {item['expected']}")
        if item.get('rejectionCode')!=result.get('rejectionCode'): raise AssertionError(f"{item['file']}: rejection {result.get('rejectionCode')} != {item.get('rejectionCode')}")
        expected_file=item.get('expectedOutput')
        if expected_file:
            golden_path=EXPECTED/expected_file; golden_count+=1
            if args.write_golden: golden_path.write_text(json.dumps(result,ensure_ascii=False,sort_keys=True,indent=2)+'\n',encoding='utf-8')
            expected=json.loads(golden_path.read_text(encoding='utf-8'))
            if result!=expected: raise AssertionError(f"{item['file']}: extraction differs from {expected_file}")
        cases.append({'file':item['file'],'status':result['status'],'rejectionCode':result.get('rejectionCode'),'golden':expected_file,'result':'PASS'})
    payload={'specificationVersion':'13.0.0','result':'PASS','caseCount':len(cases),'goldenCount':golden_count,'toolVersions':versions,'cases':cases}
    if args.json_output:
        args.json_output.write_text(
            json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + '\n',
            encoding='utf-8',
        )
    print(json.dumps(payload,ensure_ascii=False,sort_keys=True,indent=2)); return 0

if __name__=='__main__': raise SystemExit(main())

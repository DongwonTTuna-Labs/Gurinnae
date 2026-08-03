#!/usr/bin/env python3
from pathlib import Path
import hashlib,sys
root=Path(__file__).resolve().parents[1]; manifest=root/'MANIFEST.sha256'; digest=hashlib.sha256(); count=0
for line in manifest.read_text(encoding='utf-8').splitlines():
 expected,rel=line.split('  ',1); data=(root/rel).read_bytes(); actual=hashlib.sha256(data).hexdigest()
 if actual!=expected: raise SystemExit(f'MANIFEST mismatch before tree digest: {rel}')
 rb=rel.encode(); digest.update(len(rb).to_bytes(4,'big')); digest.update(rb); digest.update(bytes.fromhex(actual)); count+=1
print(f'{digest.hexdigest()} {count}')

from __future__ import annotations
import re
from pathlib import Path
from .models import Validation


IGNORED={'.venv','venv','node_modules','target','.git','.pytest_cache'}
def _ignored(path:Path,root:Path)->bool: return any(part in IGNORED for part in path.relative_to(root).parts)
def validate(root: Path, result: Validation) -> None:
    symlinks = [path for path in root.rglob('*') if path.is_symlink()]
    result.require(not symlinks, f'symlinks are forbidden: {[str(path) for path in symlinks[:5]]}')
    patterns = [
        re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
        re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
        re.compile(r'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
    ]
    hits = []
    for path in root.rglob('*'):
        if _ignored(path,root) or not path.is_file() or path.suffix.lower() not in {'.md', '.yaml', '.yml', '.json', '.jsonl', '.txt', '.env', '.py', '.js', '.ts', '.sql'}:
            continue
        text = path.read_text(encoding='utf-8', errors='replace')
        if any(pattern.search(text) for pattern in patterns):
            hits.append(path.relative_to(root).as_posix())
    result.require(not hits, f'probable secret material found: {hits[:5]}')
    result.stats.update({'symlinks': len(symlinks), 'secret_pattern_hits': len(hits)})

from __future__ import annotations
import tomllib
from pathlib import Path
from .loaders import load_json, load_yaml, loads_json
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    counts={'yaml':0,'json':0,'jsonl':0,'toml':0}
    for path in sorted(root.rglob('*')):
        if not path.is_file(): continue
        try:
            suffix=path.suffix.lower()
            if suffix in {'.yaml','.yml'}: load_yaml(path); counts['yaml']+=1
            elif suffix=='.json': load_json(path); counts['json']+=1
            elif suffix=='.jsonl':
                for line in path.read_text(encoding='utf-8').splitlines():
                    if line.strip(): loads_json(line)
                counts['jsonl']+=1
            elif suffix=='.toml': tomllib.loads(path.read_text(encoding='utf-8')); counts['toml']+=1
        except Exception as exc: result.error(f'{path.relative_to(root)} parse failed: {exc}')
    result.stats.update({f'parsed_{key}':value for key,value in counts.items()})

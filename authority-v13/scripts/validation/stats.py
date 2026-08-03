from __future__ import annotations
from pathlib import Path
from .models import Validation


def validate(root: Path, result: Validation) -> None:
    ignored={'.venv','venv','node_modules','target','.git','.pytest_cache'}
    files = [path for path in root.rglob('*') if path.is_file() and path.relative_to(root).as_posix() not in {'MANIFEST.md','MANIFEST.sha256'} and not any(part in ignored for part in path.relative_to(root).parts)]
    markdown = [path for path in files if path.suffix.lower() == '.md']
    characters = sum(len(path.read_text(encoding='utf-8', errors='replace')) for path in markdown)
    result.stats.update({'files_before_manifest_refresh': len(files), 'markdown_files': len(markdown), 'markdown_characters': characters, 'approximate_a4_pages': round(characters / 2000, 1)})

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.architecture import _bun_workspace_members, _cargo_workspace_members


class ArchitectureSourceTopologyTests(unittest.TestCase):
    def test_reads_actual_cargo_workspace_members(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Cargo.toml').write_text(
                '[workspace]\nmembers = ["crates/a", "services/b"]\n',
                encoding='utf-8',
            )

            self.assertEqual(
                _cargo_workspace_members(root),
                ['crates/a', 'services/b'],
            )

    def test_expands_only_bun_directories_with_package_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'package.json').write_text(
                json.dumps({'workspaces': ['apps/*', 'packages/*']}),
                encoding='utf-8',
            )
            for relative in ('apps/web', 'packages/ui'):
                path = root / relative
                path.mkdir(parents=True)
                (path / 'package.json').write_text('{}\n', encoding='utf-8')
            (root / 'apps/not-a-workspace').mkdir(parents=True)

            self.assertEqual(
                _bun_workspace_members(root),
                ['apps/web', 'packages/ui'],
            )

    def test_rejects_workspace_pattern_that_escapes_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'package.json').write_text(
                json.dumps({'workspaces': ['../outside']}),
                encoding='utf-8',
            )

            with self.assertRaisesRegex(ValueError, 'unsafe Bun workspace pattern'):
                _bun_workspace_members(root)


if __name__ == '__main__':
    unittest.main()

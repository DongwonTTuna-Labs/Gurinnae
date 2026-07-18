#!/usr/bin/env python3
from __future__ import annotations
import sys
sys.dont_write_bytecode = True
import argparse
import json
import os
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from validation import acceptance, agents, api, architecture, assertions, assurance, cryptography, parsers, connectors, database, design, detection, evidence, fixtures, parsing, quality, root, security, semantics, states, stats, traceability, ui, submission
from validation.loaders import duplicate_key_canaries
from validation.models import Validation

ROOT = Path(__file__).resolve().parents[1]
VERSION = '13.0.0'
VALIDATORS = {
    'parsing': lambda r: parsing.validate(ROOT, r),
    'root': lambda r: root.validate(ROOT, r, VERSION),
    'ui': lambda r: ui.validate(ROOT, r),
    'api': lambda r: api.validate(ROOT, r),
    'assertions': lambda r: assertions.validate(ROOT, r),
    'assurance': lambda r: assurance.validate(ROOT, r),
    'cryptography': lambda r: cryptography.validate(ROOT, r),
    'parsers': lambda r: parsers.validate(ROOT, r),
    'semantics': lambda r: semantics.validate(ROOT, r),
    'states': lambda r: states.validate(ROOT, r),
    'database': lambda r: database.validate(ROOT, r),
    'design': lambda r: design.validate(ROOT, r),
    'architecture': lambda r: architecture.validate(ROOT, r),
    'traceability': lambda r: traceability.validate(ROOT, r),
    'agents': lambda r: agents.validate(ROOT, r),
    'connectors': lambda r: connectors.validate(ROOT, r),
    'detection': lambda r: detection.validate(ROOT, r),
    'evidence': lambda r: evidence.validate(ROOT, r),
    'quality': lambda r: quality.validate(ROOT, r),
    'fixtures': lambda r: fixtures.validate(ROOT, r),
    'acceptance': lambda r: acceptance.validate(ROOT, r),
    'security': lambda r: security.validate(ROOT, r),
    'submission': lambda r: submission.validate(ROOT, r),
    'stats': lambda r: stats.validate(ROOT, r),
}

def _run_isolated_sections(strict: bool, exclude_evidence: bool = False) -> Validation:
    aggregate = Validation()
    sections = [
        section for section in VALIDATORS
        if not (exclude_evidence and section == 'evidence')
    ]

    def run_section(section: str, temp_root: Path) -> tuple[str, int, str, Path]:
        output_path = temp_root / f'{section}.json'
        command = [
            sys.executable, '-B', str(Path(__file__).resolve()),
            '--section', section, '--json-output', str(output_path),
        ]
        if strict:
            command.append('--strict')
        environment = dict(os.environ)
        environment['PYTHONDONTWRITEBYTECODE'] = '1'
        process = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=900,
        )
        return section, process.returncode, process.stdout, output_path

    # Sections are independent, read-only validators. Running a bounded set in
    # parallel keeps the two clean-environment proof runs practical while each
    # section remains isolated in its own interpreter and evidence file.
    with tempfile.TemporaryDirectory(prefix='gurine-authority-validation-') as temporary:
        temp_root = Path(temporary)
        results: dict[str, tuple[int, str, Path]] = {}
        with ThreadPoolExecutor(max_workers=2, thread_name_prefix='authority') as executor:
            futures = {executor.submit(run_section, section, temp_root): section for section in sections}
            for future in as_completed(futures):
                section = futures[future]
                try:
                    completed_section, returncode, stdout, output_path = future.result()
                    results[completed_section] = (returncode, stdout, output_path)
                except Exception as exc:
                    results[section] = (-1, f'{type(exc).__name__}: {exc}', temp_root / f'{section}.json')

        # Aggregate in authority order so stdout and evidence hashes are stable.
        for section in sections:
            returncode, stdout, output_path = results[section]
            if not output_path.is_file():
                aggregate.error(
                    f"validator section {section!r} produced no JSON evidence "
                    f"(exit={returncode}): {stdout[-2000:]}"
                )
                continue
            payload = json.loads(output_path.read_text(encoding='utf-8'))
            aggregate.stats.update(payload.get('stats', {}))
            aggregate.warnings.extend(
                f'[{section}] {warning}' for warning in payload.get('warnings', [])
            )
            aggregate.errors.extend(
                f'[{section}] {error}' for error in payload.get('errors', [])
            )
            if returncode != 0 and not payload.get('errors'):
                aggregate.error(
                    f"validator section {section!r} exited {returncode} "
                    f"without a reported validation error: {stdout[-2000:]}"
                )
    return aggregate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--strict', action='store_true')
    parser.add_argument('--section', choices=sorted(VALIDATORS))
    parser.add_argument('--json-output', type=Path)
    parser.add_argument('--exclude-evidence', action='store_true', help='Run every authority section except self-referential clean-environment evidence')
    args = parser.parse_args()

    if args.section is None:
        result = _run_isolated_sections(args.strict, args.exclude_evidence)
        sections = [name for name in VALIDATORS if not (args.exclude_evidence and name == 'evidence')]
    else:
        if args.exclude_evidence:
            parser.error('--exclude-evidence cannot be combined with --section')
        result = Validation()
        try:
            duplicate_key_canaries()
            result.stats['duplicate_key_canaries'] = 'PASS'
        except Exception as exc:
            result.error(f'duplicate-key canary failed: {exc}')
        sections = [args.section]
        try:
            VALIDATORS[args.section](result)
        except Exception as exc:
            result.error(
                f"validator section {args.section!r} crashed: "
                f"{type(exc).__name__}: {exc}"
            )

    status = 'PASS' if not result.errors and not (args.strict and result.warnings) else 'FAIL'
    payload = {
        'specification_version': VERSION,
        'sections': sections,
        'stats': dict(sorted(result.stats.items())),
        'warnings': result.warnings,
        'errors': result.errors,
        'result': status,
    }
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + '\n',
            encoding='utf-8',
        )
    print(f'specification_version: {VERSION}')
    for key, value in payload['stats'].items():
        print(f'{key}: {value}')
    print(f'warnings: {len(result.warnings)}')
    for warning in result.warnings:
        print(f'WARNING: {warning}')
    print(f'errors: {len(result.errors)}')
    for error in result.errors:
        print(f'ERROR: {error}')
    print(f'RESULT: {status}')
    return 0 if status == 'PASS' else 1

if __name__ == '__main__':
    exit_code = main()
    # The authority validator combines pglast and OpenAPI native-backed
    # validators.  On some supported CPython builds their interpreter-finalizer
    # order can stall after all checks and evidence writes are complete.  This
    # CLI owns no asynchronous/background work, so flush explicitly and exit
    # with the already-computed deterministic status.
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(exit_code)

from __future__ import annotations
from pathlib import Path
import hashlib
import sys
from .loaders import load_json, load_yaml
from .models import Validation


def validate(root: Path, result: Validation) -> None:
    python_evidence = load_yaml(root / 'verification/python-clean-environments.yaml')
    result.require(python_evidence.get('specification_version') == '13.0.0', 'clean Python evidence version mismatch')
    result.require(python_evidence.get('status') == 'PASS', 'clean Python environment evidence is not PASS')
    result.require(python_evidence.get('result') == 'PASS', 'clean Python environment result is not PASS')
    result.require(python_evidence.get('dependency_graph_identical') is True, 'clean Python dependency graphs differ')
    result.require(python_evidence.get('validator_output_identical') is True, 'clean Python validator outputs differ')
    result.require(python_evidence.get('python', {}).get('implementation') == 'CPython', 'clean Python implementation mismatch')
    result.require(python_evidence.get('python', {}).get('version') == '3.13.5', 'clean Python version mismatch')
    result.require(python_evidence.get('validation_command') == 'PYTHONDONTWRITEBYTECODE=1 python -B scripts/validate_final_spec.py --strict --exclude-evidence', 'clean Python validation command differs')

    def sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    requirements = root / 'requirements-spec.txt'
    result.require(
        python_evidence.get('requirements_lock_sha256') == sha256(requirements),
        'requirements lock hash evidence is stale',
    )
    environments = python_evidence.get('environments', [])
    result.require(len(environments) == 2, 'two independent clean Python environments are required')
    freeze_hashes = {item.get('freeze_sha256') for item in environments}
    validator_hashes = {item.get('validator_sha256') for item in environments}
    result.require(len(freeze_hashes) == 1 and None not in freeze_hashes, 'clean Python freeze hashes differ or are missing')
    result.require(len(validator_hashes) == 1 and None not in validator_hashes, 'clean validator output hashes differ or are missing')
    for item in environments:
        for field, hash_field in [
            ('freeze_file', 'freeze_sha256'),
            ('install_log', 'install_log_sha256'),
            ('validator_log', 'validator_sha256'),
        ]:
            path = root / item[field]
            result.require(path.is_file(), f"clean Python evidence file missing: {item[field]}")
            if path.is_file():
                expected_hash = item.get(hash_field)
                result.require(
                    isinstance(expected_hash, str) and len(expected_hash) == 64 and 'provisional' not in expected_hash,
                    f"clean Python evidence hash is not final: {hash_field}",
                )
                result.require(sha256(path) == expected_hash, f"clean Python evidence hash differs: {item[field]}")
        validator_log = root / item['validator_log']
        if validator_log.is_file():
            text = validator_log.read_text(encoding='utf-8', errors='replace')
            result.require(text.rstrip().endswith('RESULT: PASS'), f"clean validator log did not PASS: {item['validator_log']}")

    codegen = load_json(root / 'verification/codegen-compatibility.json')
    result.require(codegen.get('result') == 'PASS', 'code generation evidence is not PASS')
    result.require(codegen.get('strict_typescript_compile') == 'PASS', 'generated clients did not pass strict TypeScript compile')
    result.require(codegen.get('deterministic_regeneration') == 'PASS', 'generated clients are not deterministic')
    expected_operations = {'public': 41, 'submission': 34, 'control': 131, 'identity-internal': 9}
    result.require(set(codegen.get('contracts', {})) == set(expected_operations), 'code generation evidence does not cover four clients')
    for name, operation_count in expected_operations.items():
        item = codegen['contracts'][name]
        result.require(item.get('operations') == operation_count, f'{name}: codegen operation count differs')
        result.require(item.get('generation') == 'PASS', f'{name}: code generation did not pass')
        result.require(item.get('second_generation_diff') == '0 bytes', f'{name}: regeneration diff is not empty')
        result.require(bool(item.get('tree_sha256')), f'{name}: generated tree hash missing')

    parser = load_json(root / 'verification/sql-openapi-parser.json')
    result.require(parser.get('result') == 'PASS', 'SQL/OpenAPI parser evidence is not PASS')
    result.require(parser['postgresql'].get('migrations') == 24 and parser['postgresql'].get('errors') == 0, 'SQL parser evidence differs')
    result.require(parser['openapi'].get('documents') == 5 and parser['openapi'].get('errors') == 0, 'OpenAPI validator evidence differs')

    parser_reference = load_json(root / 'verification/parser-reference.json')
    result.require(parser_reference.get('result') == 'PASS' and parser_reference.get('caseCount') == 15 and parser_reference.get('goldenCount') == 15, 'parser reference evidence differs')
    crypto_reference = load_json(root / 'verification/cryptography-reference.json')
    result.require(crypto_reference.get('result') == 'PASS', 'cryptography reference evidence is not PASS')
    result.require(crypto_reference.get('stats') == {'cryptographic_envelope_vectors': 5, 'cryptographic_negative_cases': 8}, 'cryptography reference evidence differs')

    renders = load_json(root / 'verification/final-reference/render-results.json')
    result.require(len(renders) == 10, f'expected 10 visual reference renders, found {len(renders)}')
    result.require(all(not item.get('page_errors') for item in renders), 'visual reference render contains page errors')
    for item in renders:
        result.require((root / item['file']).is_file(), f"visual render missing: {item['file']}")

    result.stats.update({
        'clean_python_environments': len(environments),
        'generated_clients_verified': len(expected_operations),
        'openapi_documents_verified': parser['openapi']['documents'],
        'sql_migrations_parsed': parser['postgresql']['migrations'],
        'visual_reference_renders': len(renders),
        'parser_reference_cases': parser_reference['caseCount'],
        'cryptography_reference_vectors': crypto_reference['stats']['cryptographic_envelope_vectors'],
    })

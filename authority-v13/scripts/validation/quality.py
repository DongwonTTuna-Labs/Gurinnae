from __future__ import annotations
from pathlib import Path
from .loaders import load_yaml
from .models import Validation

def validate(root: Path, result: Validation) -> None:
    contract=load_yaml(root/'specs/engineering/code-quality-contract.yaml'); agents=(root/'AGENTS.md').read_text(encoding='utf-8')
    result.require(contract['specification_version']=='13.0.0','code quality version mismatch'); result.require(contract['status']=='FINAL','code quality status must be FINAL')
    for marker in ['#![forbid(unsafe_code)]','unsafe_code = "forbid"','Rustful','Svelteful','SOLID','YAGNI','Clean Code']: result.require(marker in agents,f'AGENTS missing {marker}')
    for marker in ['{@html}','server module scope','valibot@1.1.0','exactOptionalPropertyTypes']: result.require(marker in agents,f'AGENTS missing {marker}')
    rust=contract['rust']; result.require(rust['first_party_unsafe_code']=='forbidden','first-party unsafe must be forbidden')
    forbidden=set(rust['production_forbidden'])|set(rust.get('forbidden_tokens_in_first_party',[])); result.require({'unwrap(','expect(','panic!(','todo!(','unimplemented!(','unreachable!('}<=forbidden,'panic/placeholder control flow not fully forbidden')
    result.require(rust['file_limits']['hard_lines']==600 and rust['function_limits']['hard_logical_lines']==70,'Rust size limits mismatch')
    result.require(contract['sveltekit']['runtime_validator']=='valibot@1.1.0','runtime validator must be Valibot 1.1.0')
    for module in sorted((root/'scripts/validation').glob('*.py')):
        lines=len(module.read_text(encoding='utf-8').splitlines()); result.require(lines<=400,f'{module.name}: validator module exceeds 400 lines')

    cargo=(root/'specs/dependencies/cargo-bom.toml').read_text(encoding='utf-8')
    for dependency in ['openidconnect = "=4.0.1"','chacha20poly1305 = "=0.11.0"','object_store = "=0.14.0"','lettre = "=0.11.22"','opentelemetry = "=0.32.0"','calamine = "=0.35.0"','quick-xml = "=0.41.0"','zip = "=8.6.0"','csv = "=1.4.0"','lopdf = "=0.43.0"','pdf-extract = "=0.10.0"','clamd-client = "=0.1.2"']:
        result.require(dependency in cargo,f'critical direct dependency missing: {dependency}')
    result.stats['code_quality_contract']='FINAL'

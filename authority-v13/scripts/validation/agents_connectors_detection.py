from __future__ import annotations
import json
from pathlib import Path
from .loaders import load_json, load_yaml
from .models import Validation


def validate(root: Path, result: Validation) -> None:
    agents = load_yaml(root / 'specs/agents/agent-catalog.yaml')
    tools = load_yaml(root / 'specs/agents/tool-catalog.yaml')
    connectors = load_yaml(root / 'specs/connectors/connector-catalog.yaml')
    detection = load_yaml(root / 'specs/detection/rule-evaluation-catalog.yaml')
    result.require(len(agents['agents']) == 5, f'expected 5 agents, found {len(agents["agents"])}')
    result.require(len(tools['tools']) == 9, f'expected 9 agent tools, found {len(tools["tools"])}')
    for agent in agents['agents']:
        directory = root / 'specs/agents' / agent['id']
        for name in ['prompt.md', 'input.schema.json', 'output.schema.json', 'evals.yaml']:
            result.require((directory / name).is_file(), f"agent {agent['id']}: missing {name}")
        prompt = (directory / 'prompt.md').read_text(encoding='utf-8').lower()
        for keyword in ['evidence', 'abstain', 'publish', 'state']:
            result.require(keyword in prompt, f"agent {agent['id']}: prompt missing policy keyword {keyword}")
        evals = load_yaml(directory / 'evals.yaml')['cases']
        result.require(len(evals) == 10, f"agent {agent['id']}: insufficient eval cases")
    result.require(len(connectors['connectors']) == 6, f'expected 6 connectors, found {len(connectors["connectors"])}')
    result.require(connectors['total_operations'] == 44, f'expected 44 connector operations, found {connectors["total_operations"]}')
    for connector in connectors['connectors']:
        directory = root / connector['directory']
        for name in ['connector.yaml', 'operations.yaml', 'field-mapping.yaml', 'error-policy.yaml']:
            result.require((directory / name).is_file(), f"connector {connector['id']}: missing {name}")
        for kind in ['success', 'empty', 'quota', 'error', 'change', 'delete']:
            fixture = load_json(directory / 'fixtures' / f'{kind}.json')
            expected_origin='synthetic-structural-not-live-evidence' if connector['source_kind'] in {'OFFICIAL_REST_API','OFFICIAL_REST_AND_ZIP_XML_API'} else 'synthetic-manifest-contract-not-live-evidence'
            result.require(fixture['fixture_origin'] == expected_origin, f"connector {connector['id']}: fixture origin mislabeled")
    result.require(len(detection['rules']) == 10, f'expected 10 detection rules, found {len(detection["rules"])}')
    case_count = 0
    for rule in detection['rules']:
        path = root / 'specs/detection/evals' / f"{rule['id'].lower()}.jsonl"
        cases = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
        kinds = {kind: sum(1 for case in cases if case['kind'] == kind) for kind in ['positive', 'false_positive', 'missing_data']}
        result.require(kinds == {'positive': 10, 'false_positive': 15, 'missing_data': 5}, f"rule {rule['id']}: wrong eval distribution {kinds}")
        case_count += len(cases)
    result.require(case_count == 300, f'expected 300 rule evaluation cases, found {case_count}')
    result.stats.update({'agents': len(agents['agents']), 'agent_tools': len(tools['tools']), 'connectors': len(connectors['connectors']), 'connector_operations': connectors['total_operations'], 'detection_rules': len(detection['rules']), 'rule_evaluation_cases': case_count})

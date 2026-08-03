from __future__ import annotations
import json
from pathlib import Path
from typing import Any
import yaml


class DuplicateKeyError(ValueError):
    pass


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False) -> dict[Any, Any]:
    loader.flatten_mapping(node)
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            mark = key_node.start_mark
            raise DuplicateKeyError(f"duplicate YAML key {key!r} at line {mark.line + 1}, column {mark.column + 1}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_mapping,
)


def load_yaml(path: Path) -> Any:
    try:
        return yaml.load(path.read_text(encoding='utf-8'), Loader=UniqueKeyLoader)
    except Exception as exc:
        raise ValueError(f"{path}: {exc}") from exc


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def loads_json(text: str) -> Any:
    return json.loads(text, object_pairs_hook=_unique_json_object)


def load_json(path: Path) -> Any:
    try:
        return loads_json(path.read_text(encoding='utf-8'))
    except Exception as exc:
        raise ValueError(f"{path}: {exc}") from exc


def duplicate_key_canaries() -> None:
    yaml_failed = False
    try:
        yaml.load('a: 1\na: 2\n', Loader=UniqueKeyLoader)
    except DuplicateKeyError:
        yaml_failed = True
    if not yaml_failed:
        raise AssertionError('duplicate YAML key canary was accepted')

    json_failed = False
    try:
        loads_json('{"a":1,"a":2}')
    except DuplicateKeyError:
        json_failed = True
    if not json_failed:
        raise AssertionError('duplicate JSON key canary was accepted')

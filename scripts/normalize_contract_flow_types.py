#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path


def _matching_brace(line: str, opening: int) -> int | None:
    depth = 0
    quote: str | None = None
    escaped = False
    for index in range(opening, len(line)):
        char = line[index]
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote == '"':
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char in {"'", '"'}:
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def _split_pairs(content: str) -> list[str]:
    pairs: list[str] = []
    start = 0
    square_depth = 0
    curly_depth = 0
    quote: str | None = None
    escaped = False
    for index, char in enumerate(content):
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote == '"':
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char in {"'", '"'}:
            quote = char
        elif char == "[":
            square_depth += 1
        elif char == "]":
            square_depth -= 1
        elif char == "{":
            curly_depth += 1
        elif char == "}":
            curly_depth -= 1
        elif char == "," and square_depth == 0 and curly_depth == 0:
            pairs.append(content[start:index].strip())
            start = index + 1
    pairs.append(content[start:].strip())
    return pairs


def quote_flow_values(line: str) -> str:
    markers = ("fields: {", "optional: {")
    marker = next((value for value in markers if value in line), None)
    if marker is None:
        return line
    opening = line.index(marker) + len(marker) - 1
    end = _matching_brace(line, opening)
    if end is None:
        return line
    start = opening + 1
    content = line[start:end]
    pairs: list[str] = []
    for raw in _split_pairs(content):
        if ": " not in raw:
            pairs.append(raw)
            continue
        key, value = raw.split(": ", 1)
        if value.startswith(("'", '"', "{", "[")):
            pairs.append(raw)
        else:
            pairs.append(f"{key}: '{value.replace(chr(39), chr(39) * 2)}'")
    return f"{line[:start]}{', '.join(pairs)}{line[end:]}"


def main() -> None:
    target = Path("specs/product/addendum-operation-contracts.yaml")
    lines = target.read_text(encoding="utf-8").splitlines(keepends=True)
    target.write_text("".join(quote_flow_values(line) for line in lines), encoding="utf-8")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate deterministic primary-response evidence and Rust operation registries."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from materialize_application import (
    biome_format,
    operation_catalog,
    operation_response_samples,
    operation_sample_evidence,
    operation_spec_sources,
)

ROOT = Path(__file__).resolve().parents[1]
RUST_MODULES = {
    "public_api",
    "submission_api",
    "control_api",
    "identity_provider",
    "identity_service_internal",
}


def generated_outputs() -> tuple[dict[Path, str], int]:
    samples = operation_response_samples()
    sources = operation_spec_sources(operation_catalog(), samples)
    if set(sources) != RUST_MODULES:
        missing = sorted(RUST_MODULES - set(sources))
        extras = sorted(set(sources) - RUST_MODULES)
        raise ValueError(f"unexpected Rust operation modules: missing={missing}, extras={extras}")

    sample_path = ROOT / "verification/generated-operation-samples.json"
    outputs = {
        sample_path: biome_format(
            sample_path.relative_to(ROOT),
            json.dumps(operation_sample_evidence(samples), ensure_ascii=False, indent=2),
        )
    }
    outputs.update(
        {
            ROOT / f"crates/api-contracts/src/{module}.rs": source
            for module, source in sources.items()
        }
    )
    return outputs, len(samples)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs, sample_count = generated_outputs()

    stale = [
        path
        for path, expected in outputs.items()
        if not path.exists() or path.read_text(encoding="utf-8") != expected
    ]
    if args.check:
        if stale:
            for path in stale:
                print(f"stale generated primary-response artifact: {path.relative_to(ROOT)}")
            return 1
        print(
            f"generated primary-response artifacts: PASS "
            f"operations={sample_count} files={len(outputs)}"
        )
        return 0

    for path in stale:
        path.write_text(outputs[path], encoding="utf-8")
    print(
        f"generated primary-response artifacts: updated={len(stale)} "
        f"operations={sample_count} files={len(outputs)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

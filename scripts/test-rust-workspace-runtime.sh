#!/usr/bin/env bash
set -euo pipefail

# Run the complete Rust workspace test matrix against a real PostgreSQL 18.4
# owner boundary. The Dockerfile intentionally performs only compile/no-run
# checks; this gate supplies the runtime dependency instead of weakening the
# generated acceptance tests or turning their fail-closed probes into skips.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-rust-workspace-${BASHPID}-${RANDOM}"
database="gurine_rust_workspace_test"
port=""
ready=0
stable_ready=0

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "${observation_path:-}" "${edge_contracts_path:-}"
}
trap cleanup EXIT

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1::5432 \
  postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null

for _ in $(seq 1 60); do
  port="$(docker port "$container" 5432/tcp 2>/dev/null | sed -n '1s/.*://p')"
  if [[ -n "$port" ]] && docker exec "$container" pg_isready -U postgres -d "$database" >/dev/null 2>&1; then
    if [[ "$stable_ready" == 1 ]]; then
      ready=1
      break
    fi
    stable_ready=1
  else
    stable_ready=0
  fi
  sleep 1
done
[[ -n "$port" && "$ready" == 1 ]] || { echo "workspace postgres was not ready" >&2; exit 1; }

mapfile -t migrations < <(printf '%s\n' "$root"/db/migrations/*.sql | LC_ALL=C sort)
bash "$root"/scripts/apply-test-migrations-with-r6e-roles.sh "$container" "$database" "${migrations[@]}"

database_url="postgres://postgres:postgres@127.0.0.1:${port}/${database}"
observation_path="/tmp/gurine-acceptance-observation-${BASHPID}"
: >"$observation_path"
# The full workspace test binary includes generated acceptance tests.  Give
# those tests a closed, phase-correct runtime edge map so their real assertions
# execute against the database; the authoritative external runner later
# replaces these synthetic runtime bindings with the sealed authority edges.
edge_contracts="$(python3 - "$root" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = {}
pattern = re.compile(
    r"observed_(precondition|action|assert(?:_eq|_ne|_matches)?)!\s*\((.*?)\);",
    re.DOTALL,
)
for path in [*root.glob("tests/integration/acceptance/*.rs"), root / "crates/test-support/src/acceptance_observation.rs"]:
    text = path.read_text(encoding="utf-8")
    for match in pattern.finditer(text):
        kind, body = match.groups()
        instance = re.search(r'"(GI-[^"]+)"', body)
        if not instance:
            continue
        instance_id = instance.group(1)
        binding = {
            "observation_layer_edge_id": f"RUNTIME-{instance_id}-OBS",
            "observation_layer_edge_sha256": "b" * 64,
        }
        if kind.startswith("assert"):
            binding.update(
                {
                    "oracle_layer_edge_id": f"RUNTIME-{instance_id}-ORACLE",
                    "oracle_layer_edge_sha256": "c" * 64,
                }
            )
        rows[instance_id] = binding
if not rows:
    raise SystemExit("no generated acceptance observation instances found")
print(json.dumps({"rust-1.97.0-domain-application": rows}, sort_keys=True, separators=(",", ":")))
PY
)"
edge_contracts_path="/tmp/gurine-acceptance-edge-contracts-${BASHPID}.json"
printf '%s' "$edge_contracts" >"$edge_contracts_path"
cd "$root"
DATABASE_URL="$database_url" \
GURINNAE_DATABASE_URL="$database_url" \
TEST_DATABASE_URL="$database_url" \
GURINNAE_ACCEPTANCE_RUNTIME_LAYERS_JSON='["rust-1.97.0-domain-application"]' \
GURINNAE_ACCEPTANCE_OBSERVATION_PATH="$observation_path" \
GURINNAE_ACCEPTANCE_EDGE_CONTRACTS_JSON="@${edge_contracts_path}" \
    cargo test --locked --workspace --all-targets --exclude gurine-document-extractor

# The document extractor's golden fixtures invoke the authority-pinned
# Poppler/Tesseract binaries.  They are intentionally validated in the pinned
# parser-tools test image because those host binaries are not guaranteed to be
# installed; this still runs the complete package test target, not a fixture or
# compile-only substitute.
docker run --rm \
  -v "$root:/workspace" \
  -w /workspace \
  gurine-document-extractor-test@sha256:dd7556308a08e952c74d1681e0d5f73a4e2a05ceb6951da7ab4cca28378e7249 \
  bash -c 'CARGO_TARGET_DIR=/tmp/gurine-document-extractor-target cargo test --locked -p gurine-document-extractor --lib'

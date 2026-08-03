#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d -t gurine-egress-channels-XXXXXX)"
upstream_pid=""
gateway_pid=""

cleanup() {
  status=$?
  trap - EXIT
  for pid in "$gateway_pid" "$upstream_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ $status -ne 0 ]]; then
    for log in "$temp"/*.log; do
      [[ -f "$log" ]] && tail -n 160 "$log" >&2
    done
  fi
  rm -rf "$temp"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-egress-gateway

free_port() {
  local port
  while true; do
    port="$(shuf -i 30000-45000 -n 1)"
    if ! ss -ltn "sport = :$port" | tail -n +2 | grep -q .; then
      printf '%s' "$port"
      return
    fi
  done
}
upstream_port="$(free_port)"
gateway_port="$(free_port)"

EGRESS_UPSTREAM_PORT="$upstream_port" EGRESS_EXPECTED_DATA_KEY=runtime-data-key \
EGRESS_EXPECTED_OPENAI_KEY=runtime-openai-key \
  bun run tests/integration/egress-upstream.ts >"$temp/upstream.log" 2>&1 &
upstream_pid=$!

GURINE_ENV=test \
HTTP_BIND="127.0.0.1:$gateway_port" \
OIDC_ISSUER_HOST=localhost \
ALIO_HOST=localhost \
AI_PROVIDER_HOSTS=localhost \
CHALLENGE_PROVIDER_HOSTS=localhost \
DATA_GO_KR_SERVICE_KEY=runtime-data-key \
OPEN_DART_API_KEY=runtime-dart-key \
OPENAI_API_KEY=runtime-openai-key \
OBJECT_STORE_ADAPTER=filesystem \
OBJECT_STORE_FILESYSTEM_ROOT="$temp/objects" \
  target/debug/gurine-egress-gateway >"$temp/gateway.log" 2>&1 &
gateway_pid=$!

for endpoint in "http://127.0.0.1:$upstream_port/source" "http://127.0.0.1:$gateway_port/health/ready"; do
  for _ in $(seq 1 60); do
    if curl --fail --silent --show-error "$endpoint" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  curl --fail --silent --show-error "$endpoint" >/dev/null
done

EGRESS_TEST_BASE_URL="http://127.0.0.1:$gateway_port" \
EGRESS_TEST_UPSTREAM_URL="http://localhost:$upstream_port" \
  bun run tests/integration/egress-channels.ts

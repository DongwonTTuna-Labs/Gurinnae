#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
violations="$(mktemp -t gurine-runtime-quality-XXXXXX)"
trap 'rm -f "$violations"' EXIT

# Keep the executable production scan independent from the Rust compiler.  A
# test-only panic is allowed by the test contract, but a runtime panic or
# unchecked unwrap/expect is a release blocker.
while IFS= read -r -d '' source; do
  [[ "$source" == */test-support/* || "$source" == */tests/* || "$source" == */build.rs ]] && continue
  awk 'BEGIN { test_module = 0 } /^[[:space:]]*#[[:space:]]*\[[[:space:]]*cfg[[:space:]]*\([[:space:]]*test[[:space:]]*\)[[:space:]]*\][[:space:]]*$/ { test_module = 1 } !test_module { print }' "$source" \
    | grep -nE '\.unwrap[[:space:]]*\(|\.expect[[:space:]]*\(|\b(panic|todo|unimplemented|unreachable)![[:space:]]*\(' \
    | sed "s#^#$source:#" >>"$violations" || true
done < <(find "$root/crates" "$root/services" -type f -name '*.rs' -print0 | sort -z)

if [[ -s "$violations" ]]; then
  printf 'production Rust forbidden-token scan failed:\n' >&2
  cat "$violations" >&2
  exit 1
fi
printf 'production Rust forbidden-token scan: PASS\n'

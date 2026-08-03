#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

services=(
  migrator public-api control-api identity-api billing-gateway submission-api ingest-worker
  analysis-worker projection-worker notification-worker workflow-worker
  document-extractor scheduler egress-gateway oidc-test-provider
  public-web review-console response-portal
)

[[ "${#services[@]}" -eq 18 ]]
docker compose --file compose.yaml build "${services[@]}"

config_json="$(docker compose --file compose.yaml config --format json)"
project_name="$(jq -er '.name' <<<"$config_json")"
for service in "${services[@]}"; do
  image="$(jq -er --arg service "$service" --arg project "$project_name" \
    '.services[$service].image // ($project + "-" + $service)' <<<"$config_json")"
  [[ -n "$image" ]] || { printf 'missing image for %s\n' "$service" >&2; exit 1; }
  docker image inspect "$image" >/dev/null
done

printf '18 first-party production images: PASS\n'

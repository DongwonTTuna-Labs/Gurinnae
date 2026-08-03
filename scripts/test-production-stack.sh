#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="gurine-verify-$BASHPID"
compose=(docker compose --project-name "$project" --profile test --env-file "$root/.env.example" --file "$root/compose.test.yaml")

cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    "${compose[@]}" ps --all >&2 || true
    "${compose[@]}" exec -T postgres psql -U gurine_dev -d gurine -c \
      "TABLE ops.jobs; TABLE ops.job_attempts; TABLE ops.inbox; TABLE ops.email_deliveries; SELECT id,event_type,published_at FROM ops.outbox ORDER BY occurred_at DESC LIMIT 20;" >&2 || true
    "${compose[@]}" logs --no-color --tail 200 >&2 || true
  fi
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cd "$root"

if env -i PATH="$PATH" GURINE_ENV=production bash infra/scripts/production-preflight.sh >/dev/null 2>&1; then
  printf 'production preflight accepted missing inputs\n' >&2
  exit 1
fi

key="MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="
env -i PATH="$PATH" \
  GURINE_ENV=production POSTGRES_DB=gurine POSTGRES_USER=gurine POSTGRES_PASSWORD=strong-test-value \
  MIGRATOR_DATABASE_URL=postgresql://migrator:secret@postgres/gurine \
  PUBLIC_DATABASE_URL=postgresql://public:secret@postgres/gurine \
  CONTROL_DATABASE_URL=postgresql://control:secret@postgres/gurine \
  IDENTITY_DATABASE_URL=postgresql://identity:secret@postgres/gurine \
  SUBMISSION_DATABASE_URL=postgresql://submission:secret@postgres/gurine \
  INGEST_DATABASE_URL=postgresql://ingest:secret@postgres/gurine \
  ANALYSIS_DATABASE_URL=postgresql://analysis:secret@postgres/gurine \
  PROJECTOR_DATABASE_URL=postgresql://projector:secret@postgres/gurine \
  NOTIFICATION_DATABASE_URL=postgresql://notification:secret@postgres/gurine \
  WORKFLOW_DATABASE_URL=postgresql://workflow:secret@postgres/gurine \
  DOCUMENT_EXTRACTOR_DATABASE_URL=postgresql://extractor:secret@postgres/gurine \
  SCHEDULER_DATABASE_URL=postgresql://scheduler:secret@postgres/gurine \
  EGRESS_DATABASE_URL=postgresql://gurine_egress_gateway:secret@postgres/gurine \
  PUBLIC_API_INTERNAL_URL=http://public-api:8080 CONTROL_API_INTERNAL_URL=http://control-api:8081 \
  IDENTITY_API_INTERNAL_URL=http://identity-api:8083 SUBMISSION_API_INTERNAL_URL=http://submission-api:8082 \
  PUBLIC_BASE_URL=https://public.gurine.test REVIEW_BASE_URL=https://review.gurine.test \
  RESPONSE_BASE_URL=https://respond.gurine.test OIDC_EGRESS_URL=http://egress-gateway:8090/oidc \
  OIDC_ISSUER_URL=https://identity.gurine.test OIDC_CLIENT_ID=gurine-review OIDC_CLIENT_SECRET=strong-client-secret \
  OIDC_REDIRECT_URI=https://review.gurine.test/auth/callback \
  OIDC_STEP_UP_REDIRECT_URI=https://review.gurine.test/auth/step-up/callback OIDC_SCOPES='openid profile email' \
  EMAIL_ADAPTER=file EMAIL_FILE_OUTBOX=/var/lib/gurine-mail OBJECT_STORE_ADAPTER=filesystem \
  OBJECT_STORE_FILESYSTEM_ROOT=/var/lib/gurine-objects AI_ENABLED=false \
  SOURCE_KONEPS_CONTRACTS_ENABLED=false SOURCE_KONEPS_NOTICES_ENABLED=false SOURCE_OPEN_DART_ENABLED=false \
  SOURCE_LOCAL_FINANCE_ENABLED=false SOURCE_ALIO_ENABLED=false SOURCE_AUDIT_RESULTS_ENABLED=false \
  AUDIT_CHAIN_HMAC_KEY="$key" FIELD_ENCRYPTION_KEY_CURRENT="$key" TOKEN_HMAC_KEY="$key" \
  IDENTITY_SERVICE_HMAC_KEY_CURRENT="$key" IDENTITY_ASSERTION_HMAC_KEY_CURRENT="$key" \
  PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT="$key" RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT="$key" \
  SESSION_COOKIE_KEY_CURRENT="$key" SUBMISSION_COOKIE_KEY_CURRENT="$key" BOT_CHALLENGE_SECRET_KEY="$key" \
  BOT_CHALLENGE_SITE_KEY=turnstile-production-test-site-key \
  bash infra/scripts/production-preflight.sh >/dev/null

"${compose[@]}" up --detach --wait --wait-timeout 300
[[ "$("${compose[@]}" config --services | wc -l)" -eq 20 ]]

application_services=(
  migrator public-api control-api identity-api submission-api ingest-worker analysis-worker
  projection-worker notification-worker workflow-worker document-extractor scheduler egress-gateway
  oidc-test-provider public-web review-console response-portal
)

for service in "${application_services[@]}"; do
  container_id="$("${compose[@]}" ps --all --quiet "$service")"
  [[ -n "$container_id" ]] || { printf 'container missing: %s\n' "$service" >&2; exit 1; }
  user="$(docker inspect --format '{{.Config.User}}' "$container_id")"
  [[ "$user" != "" && "$user" != "0" && "$user" != "root" ]] || {
    printf 'root container forbidden: %s\n' "$service" >&2
    exit 1
  }
done

for service in public-api control-api identity-api submission-api ingest-worker analysis-worker \
  projection-worker notification-worker workflow-worker document-extractor scheduler egress-gateway \
  public-web review-console response-portal; do
  container_id="$("${compose[@]}" ps --quiet "$service")"
  [[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container_id")" == "true" ]]
done

for service in "${application_services[@]}"; do
  container_id="$("${compose[@]}" ps --all --quiet "$service")"
  security_opts="$(docker inspect --format '{{join .HostConfig.SecurityOpt ","}}' "$container_id")"
  cap_drop="$(docker inspect --format '{{join .HostConfig.CapDrop ","}}' "$container_id")"
  [[ ",$security_opts," == *,no-new-privileges:true,* ]]
  [[ ",$cap_drop," == *,ALL,* ]]
  [[ "$(docker inspect --format '{{.HostConfig.PidsLimit}}' "$container_id")" == "256" ]]
  [[ "$(docker inspect --format '{{.HostConfig.Init}}' "$container_id")" == "true" ]]
done

data_network="${project}_data"
internal_network="${project}_internal"
[[ "$(docker network inspect --format '{{.Internal}}' "$data_network")" == "true" ]]
[[ "$(docker network inspect --format '{{.Internal}}' "$internal_network")" == "true" ]]

marker="verify-$BASHPID"
"${compose[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U gurine_dev -d gurine -c \
  "INSERT INTO ops.kill_switches(code,scope,state,reason,version) VALUES('$marker',jsonb_build_object('marker','$marker'),'INACTIVE','restart persistence',1);" >/dev/null
"${compose[@]}" exec -T submission-api sh -c "printf '%s' '$marker' > /var/lib/gurine-objects/restart-marker"

invite_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
"${compose[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U gurine_dev -d gurine -c \
  "INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES('$invite_id','verify-$invite_id','verify-$invite_id@gurine.test','Runtime Verify','INVITED'); SELECT ops.enqueue_outbox('user','$invite_id',1,'notification.user_invitation_requested.v1',jsonb_build_object('actor_id','$invite_id','occurred_at',clock_timestamp(),'operation_id','inviteUser','request_id',gen_random_uuid()::text),clock_timestamp());" >/dev/null

for _ in $(seq 1 60); do
  if "${compose[@]}" exec -T notification-worker sh -c 'find /var/lib/gurine-mail -type f -name "*.json" -print -quit | grep -q .' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
mail_file="$("${compose[@]}" exec -T notification-worker sh -c 'find /var/lib/gurine-mail -type f -name "*.json" -print -quit')"
[[ -n "$mail_file" ]]

"${compose[@]}" up --detach --force-recreate --wait --wait-timeout 300 \
  public-api control-api identity-api submission-api ingest-worker analysis-worker projection-worker \
  notification-worker workflow-worker document-extractor scheduler egress-gateway public-web review-console response-portal

"${compose[@]}" exec -T postgres psql -At -U gurine_dev -d gurine -c \
  "SELECT count(*) FROM ops.kill_switches WHERE scope->>'marker'='$marker';" | grep -qx '1'
"${compose[@]}" exec -T submission-api sh -c "test \"\$(cat /var/lib/gurine-objects/restart-marker)\" = '$marker'"
"${compose[@]}" exec -T notification-worker sh -c "test -f '$mail_file'"

for service in public-api control-api identity-api submission-api; do
  container_id="$("${compose[@]}" ps --quiet "$service")"
  "${compose[@]}" kill --signal SIGTERM "$service" >/dev/null
  for _ in $(seq 1 60); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == "false" ]]; then
      break
    fi
    sleep 0.5
  done
  [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == "false" ]]
  "${compose[@]}" up --detach --no-deps --wait --wait-timeout 120 "$service" >/dev/null
done

printf '20-service non-root/read-only/no-new-privileges/cap-drop/network/restart/volume/SIGTERM production stack: PASS\n'

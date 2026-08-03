# 14. 출시와 사고 대응

## 1. Release stages

### R0 Spec and synthetic demo

No real allegations. Public only methodology/demo with obvious synthetic labels.

### R1 Private data pilot

Live official data ingestion, internal only. Identity/parser/rule verification.

### R2 Limited public beta

Small curated publications, invite feedback, legal/editorial review every case.

### R3 General public

Stable source, console, correction, on-call, legal budget, external review.

### R4 API/institutional products

After independence controls and data licenses.

## 2. Go/no-go gate

No-go if any:

- unresolved publication bypass
- source/license status not approved
- no correction/takedown channel
- no legal counsel process
- no backup restore drill
- identity false merge in locked tests
- prompt injection red-team failure
- private/public DB role separation unverified
- cost/kill switch untested
- public policy/privacy/terms missing

## 3. Release checklist

### Product/editorial

- user can see source, calculation, limitation, response, correction
- labels do not imply guilt
- empty/stale/error states
- mobile/accessibility

### Engineering

- build/test/scan/SBOM
- migrations and rollback
- cache purge/ETag
- observability and alerts
- feature/kill switches

### Data

- source reconciliation
- parser sample review
- identity verification
- rule backtest
- public payload PII/license scan

### Operations

- on-call/duty schedule
- runbooks
- status page
- response inbox
- incident comms templates

## 4. Incident categories

### Editorial factual error

wrong number/context/source.

### Identity error

wrong agency/supplier/person. Always critical.

### Privacy/security exposure

private contact, response, credentials, account compromise.

### Publication policy bypass

unapproved content or hash mismatch.

### Source integrity/drift

parser misread or upstream corruption.

### Availability/cost

outage, rate storm, model spend.

### Legal/safety

court order, credible harm, whistleblower/national security.

## 5. First response priorities

1. Protect people and stop ongoing harm.
2. Preserve evidence/audit.
3. Contain affected path.
4. Establish facts and scope.
5. Correct public record transparently.
6. Notify legally/operationally required parties.
7. Restore safely.
8. Root cause and prevention.

Do not delete logs, silently edit publication, blame AI, or wait for perfect certainty before temporary protection.

## 6. Editorial incident playbook

### Trigger

credible report of wrong identity, material number, missing response, misleading headline.

### Actions

- create incident and link publication
- freeze notifications/syndication
- add review banner or temporarily restrict body for critical harm
- snapshot current revision and source
- assign editor + engineer + legal as needed
- verify claim-evidence graph and upstream source
- contact affected party
- choose no-change/correction/retraction
- publish reason and timestamps
- notify subscribers/partners for material/critical
- root-cause taxonomy and tests

## 7. Security incident playbook

- revoke/rotate credentials
- pause affected services/source/model/publication
- isolate compromised accounts/workloads
- preserve forensic logs
- assess PII and legal notification
- patch/rebuild from trusted artifacts
- restore and monitor
- post-incident report appropriate to public risk

No compromised host artifact reuse without verification.

## 8. Source drift incident

- pause connector checkpoint
- retain raw affected batches
- compare schema fingerprints/samples
- patch parser with tests
- replay raw in staging
- determine affected normalized records/signals/cases/publications
- revalidate and correct if needed
- resume with monitored canary

## 9. Model incident

Examples: fabricated refs, prohibited language, data leak, cost spike.

- disable agent/model tier
- core deterministic pipeline continues
- identify prompt/model versions and affected suggestions
- review any human-accepted/public content
- run locked eval
- update prompt/tool/validator, new version
- shadow before resume

## 10. Communication

Public update should state:

- what happened, known scope
- what is being protected/corrected
- what users should do
- exact timestamps
- what is not yet known
- next update or resolution

Avoid speculative attribution. Legal constraints may limit detail, but correction fact should not be hidden.

## 11. Post-incident review

Within 5 business days for SEV0/1 target:

- timeline
- detection and response
- root cause and contributing factors
- affected data/publications
- policy/process/tool failures
- remediation owners/dates
- new tests/metrics
- public report decision

“No one noticed” is not a mitigating factor.

## 12. Tabletop scenarios

Before R2:

1. wrong supplier exact-name collision
2. bundle price mistaken for unit price
3. malicious response attachment
4. editor account compromise
5. source API schema drift
6. model follows prompt injection
7. correction request during viral spread
8. military procurement page reveals sensitive aggregation
9. source license changes
10. cloud bill/model cost runaway

Each exercise records decision times, missing controls, runbook changes.

## v3 기술·제품 출시 순서

1. exact toolchain/lock/image provenance 확인
2. backup/PITR health 확인
3. one-shot SQLx migration
4. public/control/submission API와 worker canary
5. generated contract hash와 deployed build 매칭
6. Bun SSR canary
7. role/grant negative probes
8. publication command synthetic smoke
9. public projection/cache verification
10. 단계적 rollout

긴급 정지는 source connector, model gateway, publication command, public serving을 별도 kill switch로 제어한다. API startup에서 migration하거나 DB를 수동 수정해 복구하지 않는다. Rollback은 prior image digest와 compatible schema를 사용하고 destructive reverse migration보다 forward fix를 우선한다.

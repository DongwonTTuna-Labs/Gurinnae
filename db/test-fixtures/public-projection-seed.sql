BEGIN;

INSERT INTO public.agencies(
  id,name,agency_type,jurisdiction,coverage,descriptive_metrics,case_counts,updated_at
) VALUES (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','통합테스트 조달청','CENTRAL','KR',
  '{"dateRange":{"label":"2026"},"sourceIds":["koneps"],"recordCount":1,"knownGaps":[],"freshness":{"asOf":"2026-07-12T00:00:00Z","status":"CURRENT"}}',
  '[{"id":"contracts","label":"계약 수","value":"1","period":{"label":"2026"},"coverageNote":"공개 projection"}]',
  '{"total":1,"publication":{"neverPublished":0,"publishedAnomaly":1,"publishedExplained":0,"officiallyConfirmed":0,"corrected":0,"retracted":0,"temporarilyRestricted":0},"investigation":{"signalDetected":0,"triage":0,"investigating":0,"awaitingResponse":0,"editorialReview":0,"legalReview":0,"readyToPublish":0,"closed":1},"resolution":{"none":1,"dataError":0,"duplicate":0,"explained":0,"insufficientEvidence":0,"referredConfidential":0,"archived":0}}',
  '2026-07-12T00:00:00Z'
);

INSERT INTO public.suppliers(
  id,name,business_status,coverage,descriptive_metrics,case_counts,identity_warnings,updated_at
) VALUES (
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','통합테스트 공급사','ACTIVE',
  '{"dateRange":{"label":"2026"},"sourceIds":["koneps"],"recordCount":1,"knownGaps":[],"freshness":{"asOf":"2026-07-12T00:00:00Z","status":"CURRENT"}}',
  '[{"id":"contracts","label":"계약 수","value":"1","period":{"label":"2026"},"coverageNote":"공개 projection"}]',
  '{"total":1,"publication":{"neverPublished":0,"publishedAnomaly":1,"publishedExplained":0,"officiallyConfirmed":0,"corrected":0,"retracted":0,"temporarilyRestricted":0},"investigation":{"signalDetected":0,"triage":0,"investigating":0,"awaitingResponse":0,"editorialReview":0,"legalReview":0,"readyToPublish":0,"closed":1},"resolution":{"none":1,"dataError":0,"duplicate":0,"explained":0,"insufficientEvidence":0,"referredConfidential":0,"archived":0}}',
  '[]','2026-07-12T00:00:00Z'
);

INSERT INTO public.contracts(
  id,contract_number,title,agency_id,supplier_id,status,signed_at,amount,detail,updated_at
) VALUES (
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc','CT-2026-001','통합테스트 공개 계약',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'ACTIVE','2026-01-02','{"amount":"110000","currency":"KRW"}',
  '{"contractMethod":"OPEN_BID","currency":"KRW","originalAmount":{"amount":"100000","currency":"KRW"},"currentAmount":{"amount":"110000","currency":"KRW"},"lineItems":[],"changes":[{"id":"change-1","sequence":1,"changedAt":"2026-02-01","sourceDocumentId":"source-doc-1"}],"sourceDocuments":[],"normalizationWarnings":[],"relatedCases":[]}',
  '2026-07-12T00:00:00Z'
);

INSERT INTO public.cases(
  id,slug,title,public_state,latest_revision,summary,published_at,updated_at,source_freshness
) VALUES (
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd','integration-case','통합테스트 공개 사례',
  'PUBLISHED_ANOMALY',1,'비교군 대비 가격 차이를 근거와 한계와 함께 공개합니다.',
  '2026-07-12T00:00:00Z','2026-07-12T00:00:00Z',
  '{"asOf":"2026-07-12T00:00:00Z","status":"CURRENT"}'
);

INSERT INTO public.case_revisions(
  case_id,revision,state,payload,payload_sha256,published_at
) VALUES (
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',1,'PUBLISHED_ANOMALY',
  '{
    "agencyId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "supplierId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "ruleId":"unit-price-ratio",
    "confirmedFacts":[],"criticalUnknowns":[],"partyResponses":[],"signals":[],
    "counterEvidence":[],"claims":[],"evidence":[],"timeline":[],"corrections":[],"limitations":[],
    "content":{"case":{"slug":"integration-case","title":"통합테스트 공개 사례","publicState":"PUBLISHED_ANOMALY","summary":"비교군 대비 가격 차이","revision":1,"updatedAt":"2026-07-12T00:00:00Z","href":"/cases/integration-case"},"confirmedFacts":[],"criticalUnknowns":[],"partyResponses":[],"signals":[],"counterEvidence":[],"claims":[],"evidence":[],"timeline":[],"corrections":[],"freshness":{"asOf":"2026-07-12T00:00:00Z","status":"CURRENT"},"limitations":[]},
    "reproducibility":{"caseSlug":"integration-case","ruleId":"unit-price-ratio","ruleVersion":"1.0.0","inputDigest":"1111111111111111111111111111111111111111111111111111111111111111","resultDigest":"2222222222222222222222222222222222222222222222222222222222222222","formula":"target / median(cohort)","roundingPolicy":"HALF_EVEN_4DP","target":{"id":"target-1","agencyName":"통합테스트 조달청","observedAt":"2026-01-02","unit":"EA","unitPrice":{"amount":"110000","currency":"KRW"},"bundleSummary":[],"compatibility":"COMPARABLE"},"includedCohort":[],"excludedCohort":[],"result":{"benchmarkType":"MEDIAN","benchmarkValue":{"amount":"100000","currency":"KRW"},"targetValue":{"amount":"110000","currency":"KRW"},"ratio":"1.1000","includedCount":1,"excludedCount":0,"formula":"target / median(cohort)","roundingPolicy":"HALF_EVEN_4DP"},"limitations":[]}
  }',
  '3333333333333333333333333333333333333333333333333333333333333333',
  '2026-07-12T00:00:00Z'
);

INSERT INTO public.corrections(id,case_id,source_revision,target_revision,summary,reason,published_at)
VALUES('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','dddddddd-dddd-4ddd-8ddd-dddddddddddd',1,2,'표기 정정','원자료 표기 확인','2026-07-12T01:00:00Z');

INSERT INTO public.source_status(source_id,display_name,status,last_success_at,expected_frequency,lag_seconds,affected_scope,public_message,updated_at)
VALUES('koneps','나라장터','CURRENT','2026-07-12T00:00:00Z','1 day',0,'{"scope":"contracts"}',NULL,'2026-07-12T00:00:00Z');

INSERT INTO public.rules(rule_id,name,active_version,public_description,requirements,exclusions,limitations,updated_at)
VALUES('unit-price-ratio','단가 비율','1.0.0','동일 단위 비교군의 중앙값 대비 비율','["unitPrice","unit"]','[]','[]','2026-07-12T00:00:00Z');

INSERT INTO public.datasets(id,title,description,format,coverage,license,download_url,updated_at)
VALUES('published-cases','공개 사례','공개 revision 고정 사례 데이터','JSONL','{"dateRange":{"label":"2026"},"sourceIds":["koneps"],"recordCount":1,"knownGaps":[],"freshness":{"asOf":"2026-07-12T00:00:00Z","status":"CURRENT"}}','CC-BY-4.0','/datasets/published-cases.jsonl','2026-07-12T00:00:00Z');

INSERT INTO public.transparency_reports(id,period_start,period_end,title,summary,report,published_at)
VALUES('ffffffff-ffff-4fff-8fff-ffffffffffff','2026-01-01','2026-06-30','2026 상반기 투명성 보고','공개 및 정정 처리 현황','{"publishedCases":1,"corrections":1}','2026-07-12T00:00:00Z');

COMMIT;

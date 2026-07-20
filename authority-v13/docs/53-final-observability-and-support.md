# 53. 최종 관측성·지원

관측 대상:

- source freshness/schema drift
- fetch/parse/normalize failure
- job queue age/retry/DLQ
- API latency/error
- SSR latency
- publication command
- audit chain
- email/object storage/OIDC
- provider cost
- backup age/restore result

PII, response text, raw token, attachment name은 telemetry에 넣지 않는다.
운영 화면은 metric gap 자체도 incident로 표시한다.

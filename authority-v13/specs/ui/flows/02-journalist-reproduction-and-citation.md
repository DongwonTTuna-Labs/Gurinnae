# Flow 02 — 기자의 재현과 인용

```mermaid
flowchart LR
  A[PUB-004 사건 최신본] --> B[Claim citation]
  B --> C[Evidence locator]
  C --> D[PUB-006 재현]
  D --> E[Rule version / cohort / input digest]
  E --> F[JSON·CSV 다운로드]
  A --> G[PUB-005 특정 revision]
  G --> H[고정 URL·publication timestamp]
  A --> I[PUB-018 정정 feed]
  I --> J[기사 업데이트]
```

## 계약

- citation에는 case slug, revision, claim/evidence ID, 공개 시각이 포함된다.
- snapshot download는 checksum과 license를 가진다.
- 최신본과 특정 revision URL을 구분한다.
- 과거 URL에 correction/retraction notice가 유지된다.

# 50. Final Data Contract

원본부터 publication까지 연결은 끊기지 않는다.

`SourceFetch → SourceDocument → NormalizedEntity → RuleRun → Signal → Case → Evidence → Claim → ReviewSnapshot → PublicationRevision`

각 단계는:

- stable ID
- version
- created/updated time
- actor/process
- provenance
- content hash
- schema/rule/parser version
- audit event

를 갖는다.

공개 projection은 private aggregate를 직접 serialize하지 않으며,
publication revision에서 승인된 필드만 복사한다.

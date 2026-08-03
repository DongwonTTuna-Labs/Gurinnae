# 공식 연구 출처와 기준일

## 1. 기준

- 조사일: 2026-07-10 (Asia/Tokyo/Seoul calendar context)
- 아래 URL은 명세 작성 시 확인한 공식 정부·공공기관 또는 OpenAI 공식 자료다.
- API 필드·quota·법령 effective version은 connector activation/실제 publication 시 다시 확인한다.
- 이 문서는 source catalog이지 법률 의견이 아니다.

## 2. 조달·재정·공시

- 조달청 나라장터 계약정보서비스: https://www.data.go.kr/data/15129427/openapi.do
- 조달청 나라장터 입찰공고정보서비스: https://www.data.go.kr/data/15129394/openapi.do
- 조달청 나라장터 낙찰정보서비스: https://www.data.go.kr/data/15129397/openapi.do
- 조달청 나라장터 계약과정통합공개서비스: https://www.data.go.kr/data/15129459/openapi.do
- 조달청 나라장터 조달요청서비스: https://www.data.go.kr/data/15129468/openapi.do
- 조달청 나라장터 발주계획현황서비스: https://www.data.go.kr/data/15129462/openapi.do
- 조달청 나라장터 공공데이터개방표준서비스: https://www.data.go.kr/data/15058815/openapi.do
- 나라장터: https://www.g2b.go.kr/
- 지방재정365 우리 지자체 재정공시: https://www.data.go.kr/data/15138709/openapi.do
- 지방재정365 지방보조금: https://www.data.go.kr/data/15138713/openapi.do
- 지방재정365 지역통합재정통계: https://www.data.go.kr/data/15138717/openapi.do
- ALIO: https://www.alio.go.kr/
- 감사원 감사결과: https://www.bai.go.kr/bai/result/branch/list
- 정보공개포털: https://www.open.go.kr/

## 3. 업체 식별·공시

- 국세청 사업자등록정보 진위확인 및 상태조회: https://www.data.go.kr/data/15081808/openapi.do
- 금융감독원 Open DART: https://opendart.fss.or.kr/
- Open DART 공시정보 개발가이드: https://opendart.fss.or.kr/guide/main.do?apiGrpCd=DS001
- 공정거래위원회 통신판매사업자 등록상세 예시: https://www.data.go.kr/data/15126315/openapi.do

## 4. 법령·정책

- 국가법령정보센터: https://www.law.go.kr/
- 개인정보 보호법: https://www.law.go.kr/LSW/lsInfoP.do?lsiSeq=248613
- 공공기관의 정보공개에 관한 법률: https://www.law.go.kr/LSW/lsInfoP.do?lsiSeq=251019
- 정보공개법 제9조 비공개 대상 정보 관련 페이지: https://www.law.go.kr/lsLinkCommonInfo.do?ancYnChk=&chrClsCd=010202&lsJoLnkSeq=1020997629
- 공공데이터의 제공 및 이용 활성화에 관한 법률: https://www.law.go.kr/LSW//lsSideInfoP.do?docCls=jo&joBrNo=00&joNo=0001&lsiSeq=251023&urlMode=lsScJoRltInfoR
- 지방자치단체를 당사자로 하는 계약에 관한 법률: https://www.law.go.kr/LSW/lsInfoP.do?ancYnChk=0&efYd=20240217&lsiSeq=253973
- 지방계약법 시행령 수의계약 관련: https://law.go.kr/LSW/lumLsLinkPop.do?lspttninfSeq=81848
- 형법상 명예훼손 관련 조문·판례 검색: https://www.law.go.kr/
- 개인정보 포털: https://www.privacy.go.kr/
- 국민권익위원회 신고방법: https://www.acrc.go.kr/menu.es?mid=a10202010100
- 공익신고자 보호 안내: https://www.acrc.go.kr/menu.es?mid=a10101040200

## 5. Codex 운영 참고 — OpenAI 공식

- Codex best practices: https://developers.openai.com/codex/learn/best-practices
- Long-running work: https://developers.openai.com/codex/long-running-work
- Difficult problem iteration: https://developers.openai.com/codex/use-cases/iterate-on-difficult-problems
- Codex customization/AGENTS: https://developers.openai.com/codex/concepts/customization
- Codex subagents: https://developers.openai.com/codex/subagents

## 6. 재검증 주기

- API catalog/quota/schema: connector 활성화 전 + 분기별
- source terms/license: 분기별 또는 변경 감지
- 법령/판례: 실제 publication 및 반기별 policy review
- model provider terms/pricing: monthly or before change
- Codex workflow docs: major tool upgrade 전에


## 7. v2 기술 기준 공식 출처

기준일은 2026-07-11이다. 최종 구현의 clean bootstrap에서 package registry와 compatibility를 다시 실행 검증하되 core decision은 승인된 ADR 없이 변경하지 않는다.

- Rust 1.97.0 release: https://blog.rust-lang.org/2026/07/09/Rust-1.97.0/
- Actix Web crate: https://crates.io/crates/actix-web
- Actix Web documentation: https://actix.rs/docs/
- SQLx crate: https://crates.io/crates/sqlx
- SQLx compile-time query/offline documentation: https://docs.rs/sqlx/latest/sqlx/macro.query.html
- Utoipa crate: https://crates.io/crates/utoipa
- utoipa-actix-web crate: https://crates.io/crates/utoipa-actix-web
- PostgreSQL 18.4 release documentation: https://www.postgresql.org/docs/release/18.4/
- PostgreSQL official container image: https://hub.docker.com/_/postgres
- Bun 1.3.14 release: https://bun.sh/blog/bun-v1.3.14
- Bun SvelteKit guide: https://bun.sh/guides/ecosystem/sveltekit
- Svelte package: https://www.npmjs.com/package/svelte
- SvelteKit package: https://www.npmjs.com/package/@sveltejs/kit
- svelte-adapter-bun package: https://www.npmjs.com/package/svelte-adapter-bun
- Biome package: https://www.npmjs.com/package/@biomejs/biome
- Hey API OpenAPI TypeScript package: https://www.npmjs.com/package/@hey-api/openapi-ts
- Hey API Fetch client documentation: https://heyapi.dev/openapi-ts/clients/fetch
- OpenAPI 3.1 specification: https://spec.openapis.org/oas/v3.1.0
- JSON Schema 2020-12: https://json-schema.org/draft/2020-12

### Version evidence rule

문서의 버전 숫자는 `specs/architecture/technology-baseline.yaml`과 일치해야 한다. Clean bootstrap은 실제 registry에서 exact versions, deprecation, compatible peer ranges를 확인하고 결과를 `implementation-evidence/dependency-compatibility.md`에 기록한다. Release는 lockfile과 image digest를 권위로 사용한다.

## 8. v2.1 container and toolchain corrections

- PostgreSQL official image documentation for the version-18 `PGDATA` and `VOLUME` change: https://github.com/docker-library/docs/blob/master/postgres/README.md
- SQLx 0.9.0 changelog/repository: https://github.com/launchbadge/sqlx/tree/v0.9.0
- SQLx CLI 0.9.0 registry entry: https://crates.io/crates/sqlx-cli/0.9.0
- `svelte-adapter-bun` 1.0.1 release and package metadata: https://github.com/kwchang0831/svelte-adapter-bun/releases/tag/v1.0.1

The package treats registry metadata as an input, not proof of compatibility. Clean installation, compilation, runtime smoke, and immutable release evidence remain mandatory.

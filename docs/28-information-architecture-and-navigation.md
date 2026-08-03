# 28. 정보구조와 내비게이션

## 1. 목적

구린네의 정보구조는 데이터베이스 테이블을 그대로 메뉴로 노출하지 않는다. 사용자가 수행하려는 판단과 작업을 중심으로 세 개의 제품 surface를 분리하고, 동일 객체를 여러 맥락에서 일관되게 연결한다.

## 2. 제품 surface

| Surface | 사용자 | 목적 | 인증 | 쓰기 |
|---|---|---|---|---|
| Public Web | 시민, 기자, 연구자 | 공개 기록 탐색·이해·재현 | 읽기는 불필요 | 구독·정정요청은 Submission API를 통한 제한적 제출 |
| Review Console | 조사자, 편집자, 운영자 | 신호·사건·근거·승인·운영 | 조직 OIDC + MFA/RBAC | 역할별 command |
| Response Portal | 기관·업체 소명 담당자 | 특정 요청에 대한 답변·첨부·제출 | 만료 가능한 요청 token + 추가 검증 | 해당 요청 범위 안에서만 제출 |

세 surface는 서로 링크할 수 있지만 세션, API client, CSP, telemetry와 배포 origin은 분리한다.

## 3. 공개 웹 사이트맵

```text
/
├── search
├── cases
│   └── {caseSlug}
│       ├── revisions/{revision}
│       └── reproduce
├── agencies
│   └── {agencySlug}
├── suppliers
│   └── {supplierSlug}
├── contracts
│   └── {contractId}
├── methodology
│   └── rules/{ruleId}
├── coverage
├── sources
│   └── {sourceId}
├── corrections
│   └── {correctionId}
├── data
├── api
├── subscribe
├── subscription/manage
├── correction-request
├── about
├── about/funding
├── about/governance
├── editorial-policy
├── accessibility
├── privacy
├── terms
└── contact
```

### 3.1 공개 글로벌 내비게이션

데스크톱 1차 항목:

1. 사례
2. 계약
3. 기관·업체
4. 방법론
5. 데이터 범위
6. 정정
7. 검색

보조 항목:

- 구독
- 소개
- 운영·후원
- API/다운로드

모바일에서는 햄버거 안에 모든 항목을 숨기기보다 상단에 검색과 사례 진입점을 유지한다. 메뉴를 열었을 때 현재 위치와 닫기 버튼이 명확해야 한다.

### 3.2 공개 footer

- 서비스 정의와 “이상 징후는 위법 확정이 아님” 고지
- 방법론·편집 정책·정정·coverage
- 개인정보·약관·접근성
- funding·governance
- 연락처
- source freshness 요약
- 현재 specification/publication policy version

## 4. 내부 콘솔 사이트맵

```text
/internal
├── dashboard
├── my-work
├── search
├── notifications
├── signals
│   └── {signalId}
├── cases
│   └── {caseId}
│       ├── overview
│       ├── signals
│       ├── evidence
│       ├── evidence/{evidenceId}
│       ├── claims
│       ├── hypotheses
│       ├── responses
│       ├── agent-runs
│       ├── agent-runs/{runId}
│       ├── timeline
│       ├── review
│       ├── preview
│       ├── corrections
│       └── audit
├── review
│   └── {snapshotId}
├── corrections
│   └── {correctionId}
├── sources
│   └── {sourceId}
│       ├── runs
│       ├── runs/{runId}
│       ├── schema-drift
│       └── backfill
├── rules
│   └── {ruleId}/versions/{version}
│       ├── evaluation
│       └── activation
├── operations
│   ├── jobs
│   ├── jobs/{jobId}
│   ├── budgets
│   ├── providers
│   └── kill-switches
├── audit
├── admin/users
│   └── {userId}
├── admin/roles
└── account
```

### 4.1 내부 글로벌 내비게이션

역할별로 보이는 항목이 다르다. 접근 권한이 없는 메뉴를 단순히 숨기는 것만으로 보안을 구현하지 않으며 서버 authorization이 최종 기준이다.

공통:

- 대시보드
- 내 작업
- 검색
- 알림
- 계정

조사 그룹:

- 신호
- 사건
- 검토
- 정정

데이터 그룹:

- 출처
- 탐지 규칙

운영 그룹:

- 작업 큐
- 비용
- 공급자 상태
- kill switch
- 감사 로그
- 사용자·역할

좌측 내비게이션은 넓은 화면에서 고정될 수 있으나, 사건 workspace 안의 로컬 task rail과 구분한다.

## 5. 소명 포털 사이트맵

```text
/respond/{token}
├── overview
├── answer
├── attachments
├── review
├── receipt
├── extension
└── unavailable
```

응답자는 포털 안에서 다른 사건, 다른 기관, 내부 상태를 탐색할 수 없다. token이 허용하는 단일 요청만 볼 수 있다.

## 6. 핵심 객체와 canonical URL

| 객체 | 공개 canonical | 내부 canonical | 설명 |
|---|---|---|---|
| Investigation Case | `/cases/{caseSlug}` | `/internal/cases/{caseId}/overview` | 공개 revision과 내부 aggregate를 구분 |
| Publication Revision | `/cases/{caseSlug}/revisions/{revision}` | `/internal/cases/{caseId}/preview?revision=` | 공개된 snapshot은 불변 |
| Contract | `/contracts/{contractId}` | 사건 또는 검색에서 contextual link | source identifier와 내부 UUID 분리 |
| Agency | `/agencies/{agencySlug}` | 내부 검색 result | 공식 명칭 변경 이력 보존 |
| Supplier | `/suppliers/{supplierSlug}` | 내부 entity resolution tool | 모호한 identity는 공개 merge 금지 |
| Signal | 공개 URL 없음 | `/internal/signals/{signalId}` | signal은 조사 전 내부 자료 |
| Evidence | case detail drawer + stable fragment | `/internal/cases/{caseId}/evidence/{evidenceId}` | 공개 locator와 내부 원본 권한 분리 |
| Correction | `/corrections/{correctionId}` | `/internal/corrections/{correctionId}` | 정정 자체가 1급 record |
| Source | `/sources/{sourceId}` | `/internal/sources/{sourceId}` | 공개 coverage와 운영 configuration 분리 |

## 7. URL과 상태 규칙

- 공개 filter는 URL query에 직렬화되어 공유·복원 가능해야 한다.
- 잘못된 enum 또는 날짜 범위는 조용히 무시하지 않고 사용자에게 수정 방법을 제시한다.
- 내부 tab 이동은 draft 저장 여부와 충돌하지 않아야 한다.
- 공개 slug가 변경되면 영구 redirect와 이전 slug audit를 보존한다.
- 철회된 사건의 URL은 404로 사라지지 않고 철회 notice와 revision 이력을 제공한다.
- 접근권한이 없는 내부 객체는 존재 여부를 불필요하게 누출하지 않는다.
- response token은 referrer, analytics, client error log에 남기지 않는다.
- page number보다 cursor pagination을 기본으로 하며 canonical URL에는 안정적인 filter만 포함한다.

## 8. Breadcrumb 규칙

공개:

```text
홈 > 사례 > 사건 제목
홈 > 기관 > 기관명
홈 > 방법론 > 규칙명
```

내부:

```text
사건 > 사건 제목 > 근거 > 근거 식별자
출처 > 출처명 > 실행 기록 > 실행 ID
규칙 > 규칙명 > 버전 > 평가
```

breadcrumb는 브라우저 뒤로가기 대체물이 아니다. 현재 페이지는 링크로 만들지 않는다.

## 9. 검색 정보구조

### 9.1 공개 통합 검색

검색 대상:

- 공개 사건
- 계약
- 기관
- 업체
- 방법론
- 정정
- 공개 source

결과는 객체 종류별로 분리하거나 사용자가 선택할 수 있어야 한다. 서로 다른 점수를 하나의 “위험도”로 합산하지 않는다.

결과 카드 필수 항목:

- 객체 유형
- 제목 또는 공식 명칭
- 핵심 문맥
- 날짜
- 현재 상태
- freshness/coverage 경고
- 검색어가 일치한 필드

### 9.2 내부 검색

추가 대상:

- 미공개 사건
- signal
- evidence locator
- response request
- job/run
- audit event

권한 필터는 검색 인덱스와 결과 조회 양쪽에서 적용한다.

## 10. 필터와 정렬

필터 패턴은 화면마다 새로 만들지 않는다.

- 선택된 필터는 chip으로 표시하고 개별 제거 가능하다.
- 전체 초기화가 있다.
- 결과 수가 갱신됨을 스크린리더에 알린다.
- 날짜는 절대 날짜와 명확한 timezone을 사용한다.
- “위험순”, “구린순”, “화제순”은 금지한다.
- amount 정렬은 통화·부가세·단위 비교 가능성 안내와 함께 제공한다.
- 내부 queue priority는 공개되지 않으며 이유 code가 있어야 한다.

## 11. 페이지 간 연결 원칙

- 사건에서 계약·기관·업체·규칙·source로 이동할 수 있다.
- 계약에서 관련 공개 사건으로 이동할 수 있으나, 관련 없는 내부 signal 수는 공개하지 않는다.
- 기관·업체 페이지는 사건 수를 맥락 없이 강조하지 않는다. coverage와 총 관측 계약 수를 함께 표시한다.
- 정정 notice는 관련 사건의 모든 revision에서 발견 가능해야 한다.
- 내부 workspace의 공개 preview는 현재 승인 대상 snapshot만 렌더링한다.
- 소명 포털 영수증은 내부 case state를 과도하게 공개하지 않는다.

## 12. 빈 상태와 오류 상태의 IA

빈 상태는 “아무것도 없다”가 아니라 다음을 구분한다.

- 실제 0건
- 아직 수집하지 않은 범위
- filter 결과 0건
- 권한 때문에 보이지 않는 결과
- source 장애로 계산할 수 없는 결과
- indexing 지연
- 합성 환경

오류 페이지는 사용자가 다음 행동을 할 수 있어야 한다.

- 재시도
- filter 수정
- 상위 목록으로 이동
- freshness/incident 확인
- 지원 연락
- draft 보존 여부 확인

## 13. SEO와 검색엔진 노출

index 허용:

- 공개 사건 최신 revision
- 계약·기관·업체 공개 페이지
- 방법론·coverage·source·정정·정책

noindex:

- filter가 과도하게 조합된 검색 결과
- subscription 관리 token
- correction form receipt
- response portal 전체
- 내부 콘솔 전체
- 사건의 법률 임시 제한 preview
- 합성 demo 환경

structured data는 사실과 상태를 과장하지 않는 범위에서 사용하며, `Article`만을 무조건 적용하지 않는다.

## 14. IA 변경 절차

새 화면 또는 메뉴를 추가하려면 다음을 갱신한다.

1. `screen-catalog.yaml`
2. `navigation.yaml`
3. `screen-data-contracts.yaml`
4. 역할·권한
5. analytics event
6. 해당 journey
7. redirect와 canonical 정책
8. screen release matrix

한 화면을 추가하면서 별도의 navigation concept를 임의로 만들지 않는다.

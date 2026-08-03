const FIXTURE_AS_OF = "2026-07-29T09:00:00Z";

function publicUuid(namespace: string, ordinal: number) {
  return `${namespace}-0000-4000-8000-${String(ordinal).padStart(12, "0")}`;
}

function caseStateCounts(ordinal: number) {
  const total = 11 + ordinal;
  return {
    total,
    publication: {
      neverPublished: 0,
      publishedAnomaly: 3,
      publishedExplained: 3,
      officiallyConfirmed: total - 8,
      corrected: 2,
      retracted: 0,
      temporarilyRestricted: 0,
    },
    investigation: {
      signalDetected: 0,
      triage: 0,
      investigating: 0,
      awaitingResponse: 0,
      editorialReview: 0,
      legalReview: 0,
      readyToPublish: 0,
      closed: total,
    },
    resolution: {
      none: 3,
      dataError: 1,
      duplicate: 0,
      explained: total - 6,
      insufficientEvidence: 2,
      referredConfidential: 0,
      archived: 0,
    },
  };
}

function coverageModel(ordinal: number) {
  return {
    dateRange: {
      from: "2025-01-01",
      to: "2026-07-29",
      label: "2025년 이후 공개자료",
    },
    sourceIds: ["public-contract-ledger"],
    recordCount: 138 + ordinal * 17,
    knownGaps: [],
    freshness: {
      asOf: FIXTURE_AS_OF,
      lastSuccessfulFetchAt: "2026-07-29T08:30:00Z",
      expectedFrequencySeconds: 86400,
      lagSeconds: 1800,
      status: "CURRENT",
    },
  };
}

const agencySeeds = [
  [
    "nurisaem-environment",
    "누리샘시 생활환경국(가상)",
    "지방자치단체",
    "누리샘시",
  ],
  [
    "haedeunmaru-culture",
    "해든마루군 교육문화과(가상)",
    "지방자치단체",
    "해든마루군",
  ],
  [
    "dabomnuri-transit",
    "다봄누리시 교통시설단(가상)",
    "공공시설 운영기관",
    "다봄누리시",
  ],
  [
    "ongyeolhae-welfare",
    "온결해군 복지지원과(가상)",
    "지방자치단체",
    "온결해군",
  ],
  [
    "saeronbyeol-digital",
    "새론별시 정보행정실(가상)",
    "지방자치단체",
    "새론별시",
  ],
  ["bareunsup-safety", "바른숲군 재난안전과(가상)", "지방자치단체", "바른숲군"],
  [
    "pureungyeol-park",
    "푸른결시 공원관리단(가상)",
    "공공시설 운영기관",
    "푸른결시",
  ],
  [
    "hanulnuri-health",
    "한울누리군 보건지원과(가상)",
    "지방자치단체",
    "한울누리군",
  ],
] as const;

export const publicAgencyRows = agencySeeds.map(
  ([slug, name, agencyType, jurisdiction], index) => ({
    id: publicUuid("11000000", index + 1),
    name,
    agencyType,
    jurisdiction,
    caseCounts: caseStateCounts(index + 1),
    coverage: coverageModel(index + 1),
    href: `/agencies/${slug}`,
  }),
);

const supplierSeeds = [
  ["dasomgyeol-it", "다솜결정보기술 주식회사(가상)"],
  ["haesolbit-facility", "해솔빛시설관리 유한회사(가상)"],
  ["saebomgil-mobility", "새봄길모빌리티 주식회사(가상)"],
  ["pureunmaru-landscape", "푸른마루조경 주식회사(가상)"],
  ["gaongyeol-safety", "가온결안전진단 주식회사(가상)"],
  ["nurisaem-content", "누리샘교육콘텐츠 주식회사(가상)"],
  ["onsaebyeok-logistics", "온새벽보건물류 주식회사(가상)"],
  ["malgeundeul-energy", "맑은들에너지서비스 주식회사(가상)"],
] as const;

export const publicSupplierRows = supplierSeeds.map(([slug, name], index) => ({
  id: publicUuid("22000000", index + 1),
  name,
  businessStatus: "영업 중",
  caseCounts: caseStateCounts(index + 2),
  coverage: coverageModel(index + 2),
  identityWarnings: [],
  href: `/suppliers/${slug}`,
}));

const contractSeeds = [
  [
    "가상-2026-환경-017",
    "공공청사 냉난방 설비 정기점검 용역",
    "2026-01-19",
    "48600000",
    "ACTIVE",
  ],
  [
    "가상-2026-문화-008",
    "생활체육관 LED 조명 교체 공사",
    "2026-02-03",
    "126750000",
    "COMPLETED",
  ],
  [
    "가상-2026-교통-021",
    "마을버스 승강장 안전시설 보강",
    "2026-02-27",
    "184320000",
    "ACTIVE",
  ],
  [
    "가상-2026-복지-014",
    "복지회관 급식실 환기설비 개선",
    "2026-03-11",
    "89500000",
    "COMPLETED",
  ],
  [
    "가상-2026-정보-032",
    "공공 와이파이 통합관제 유지보수",
    "2026-04-02",
    "72000000",
    "ACTIVE",
  ],
  [
    "가상-2026-안전-006",
    "재난문자 발송 플랫폼 운영 지원",
    "2026-04-24",
    "58800000",
    "AWARDED",
  ],
  [
    "가상-2026-공원-025",
    "도심공원 수목 관리 및 병해충 방제",
    "2026-05-15",
    "93500000",
    "ACTIVE",
  ],
  [
    "가상-2026-보건-019",
    "보건소 검체 운송 냉장차량 임차",
    "2026-06-08",
    "67200000",
    "AWARDED",
  ],
] as const;

function entityReference(
  rows: readonly { id: string; name: string; href: string }[],
  index: number,
  entityType: "AGENCY" | "SUPPLIER",
) {
  const row = rows[index];
  if (!row) throw new Error(`public ${entityType} fixture ${index} is missing`);
  return { id: row.id, name: row.name, entityType, href: row.href };
}

export const publicContractRows = contractSeeds.map(
  ([contractNumber, title, signedAt, amount, status], index) => ({
    id: publicUuid("33000000", index + 1),
    contractNumber,
    title,
    agency: entityReference(publicAgencyRows, index, "AGENCY"),
    supplier: entityReference(publicSupplierRows, index, "SUPPLIER"),
    status,
    signedAt,
    amount: { amount, currency: "KRW" },
    href: `/contracts/${publicUuid("33000000", index + 1)}`,
  }),
);

const caseSeeds = [
  [
    "civic-building-hvac-review",
    "청사 냉난방 설비 계약 단가 비교",
    "PUBLISHED_ANOMALY",
    "동일 규격 유지관리 계약의 공개 단가 차이와 포함 범위를 함께 확인합니다.",
    3,
    "2026-07-29T08:20:00Z",
    "RECEIVED",
    null,
  ],
  [
    "sports-center-lighting-explained",
    "체육관 조명 교체 계약 범위 확인",
    "PUBLISHED_EXPLAINED",
    "설치 수량과 폐기물 처리 비용을 확인해 초기 단가 차이의 사유를 보완했습니다.",
    2,
    "2026-07-28T15:10:00Z",
    "RECEIVED",
    null,
  ],
  [
    "bus-stop-safety-review",
    "승강장 안전시설 계약 물량 비교",
    "OFFICIALLY_CONFIRMED",
    "계약서와 준공 내역에 기재된 안전시설 물량을 공개 원문 기준으로 대조했습니다.",
    4,
    "2026-07-27T10:40:00Z",
    "RECEIVED",
    null,
  ],
  [
    "welfare-kitchen-ventilation-correction",
    "복지회관 환기설비 계약 금액 정정",
    "CORRECTED",
    "부가가치세 포함 여부를 바로잡고 원문 금액과 공개 요약을 일치시켰습니다.",
    5,
    "2026-07-26T13:30:00Z",
    "RECEIVED",
    "PUBLISHED",
  ],
  [
    "public-wifi-maintenance-review",
    "공공 와이파이 유지보수 계약 기간 검토",
    "PUBLISHED_ANOMALY",
    "계약 기간과 월별 유지보수 범위를 분리해 비교할 필요가 있음을 기록했습니다.",
    2,
    "2026-07-25T09:15:00Z",
    "AWAITING_RESPONSE",
    null,
  ],
  [
    "emergency-message-platform-explained",
    "재난문자 플랫폼 계약 변경 사유",
    "PUBLISHED_EXPLAINED",
    "운영 시간 확대와 추가 연계 범위가 계약 변경에 미친 영향을 정리했습니다.",
    3,
    "2026-07-24T16:45:00Z",
    "RECEIVED",
    null,
  ],
  [
    "park-tree-care-review",
    "공원 수목 관리 계약 산출내역 비교",
    "PUBLISHED_ANOMALY",
    "수종별 작업 횟수와 방제 범위가 공개 산출내역마다 다른 점을 확인했습니다.",
    2,
    "2026-07-23T11:05:00Z",
    "NOT_REQUESTED",
    null,
  ],
  [
    "health-sample-transport-confirmed",
    "검체 운송 차량 임차 계약 확인",
    "OFFICIALLY_CONFIRMED",
    "냉장 운송 조건과 운행 횟수를 계약서 및 과업지시서에서 함께 확인했습니다.",
    3,
    "2026-07-22T14:25:00Z",
    "RECEIVED",
    null,
  ],
] as const;

/**
 * Publication dates intentionally differ from update dates so export-filter
 * tests catch the production contract regressing from published_at to
 * updated_at.
 */
export const publicCasePublishedAtBySlug = Object.freeze({
  "civic-building-hvac-review": "2026-07-12T10:00:00Z",
  "sports-center-lighting-explained": "2026-07-14T10:00:00Z",
  "bus-stop-safety-review": "2026-07-16T10:00:00Z",
  "welfare-kitchen-ventilation-correction": "2026-07-18T10:00:00Z",
  "public-wifi-maintenance-review": "2026-07-20T10:00:00Z",
  "emergency-message-platform-explained": "2026-07-22T10:00:00Z",
  "park-tree-care-review": "2026-07-24T10:00:00Z",
  "health-sample-transport-confirmed": "2026-07-26T10:00:00Z",
} satisfies Record<string, string>);

export const publicCaseRows = caseSeeds.map(
  ([
    slug,
    title,
    publicState,
    summary,
    revision,
    updatedAt,
    responseStatus,
    correctionStatus,
  ]) => ({
    slug,
    title,
    publicState,
    summary,
    revision,
    updatedAt,
    responseStatus,
    correctionStatus,
    href: `/cases/${slug}`,
  }),
);

const correctionSeeds = [
  [
    3,
    4,
    "계약 기간 표기 정정",
    "종료일을 원문 계약서 기준으로 바로잡았습니다.",
    "2026-07-29T07:40:00Z",
  ],
  [
    2,
    3,
    "부가가치세 포함 여부 보완",
    "총액의 부가가치세 포함 여부를 명시했습니다.",
    "2026-07-28T12:20:00Z",
  ],
  [
    4,
    5,
    "공급 수량 오기 수정",
    "산출내역서의 공급 수량과 일치하도록 수정했습니다.",
    "2026-07-27T09:10:00Z",
  ],
  [
    1,
    2,
    "기관 명칭 변경 반영",
    "공개 원문에 기재된 계약 당시 명칭으로 정리했습니다.",
    "2026-07-26T15:35:00Z",
  ],
  [
    5,
    6,
    "계약 변경일 추가",
    "변경계약 체결일이 누락되어 공개 이력에 추가했습니다.",
    "2026-07-25T08:55:00Z",
  ],
  [
    2,
    3,
    "원화 금액 자리수 정정",
    "전표 확인 결과 잘못 옮겨 적은 금액 자리수를 바로잡았습니다.",
    "2026-07-24T14:05:00Z",
  ],
  [
    3,
    4,
    "응답 상태 갱신",
    "당사자 회신 수신일을 확인해 응답 상태를 갱신했습니다.",
    "2026-07-23T10:45:00Z",
  ],
  [
    1,
    2,
    "출처 문서 위치 보완",
    "검증에 사용한 원문 문서의 쪽 번호를 추가했습니다.",
    "2026-07-22T16:15:00Z",
  ],
] as const;

export const publicCorrectionRows = correctionSeeds.map(
  ([sourceRevision, targetRevision, summary, reason, publishedAt], index) => ({
    id: publicUuid("44000000", index + 1),
    sourceRevision,
    targetRevision,
    summary,
    reason,
    publishedAt,
    href: `/corrections/${publicUuid("44000000", index + 1)}`,
  }),
);

export const publicSearchRows = [
  ...publicCaseRows.map((row) => ({
    resultType: "CASE",
    id: row.slug,
    title: row.title,
    subtitle: "공개 사례",
    status: row.publicState,
    summary: row.summary,
    updatedAt: row.updatedAt,
    href: row.href,
  })),
  {
    resultType: "RULE",
    id: "contract-unit-price-comparison",
    title: "계약 단가 비교 규칙",
    subtitle: "공개 탐지 규칙",
    status: "ACTIVE",
    summary:
      "동일 규격 계약의 단가와 포함 범위를 비교해 추가 검토가 필요한 차이를 표시합니다.",
    updatedAt: "2026-07-29T07:50:00Z",
    href: "/methodology/rules/contract-unit-price-comparison",
  },
  {
    resultType: "DATASET",
    id: "public-contract-ledger",
    title: "공개 계약 대장 데이터셋",
    subtitle: "공개 데이터셋",
    status: "CURRENT",
    summary:
      "공개 계약의 기관·업체·계약일·금액과 자료 기준일을 함께 정리한 데이터셋입니다.",
    updatedAt: "2026-07-29T08:30:00Z",
    href: "/data",
  },
];

export { FIXTURE_AS_OF };

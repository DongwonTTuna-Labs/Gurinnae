export const OPERATIONAL_INTERPRETATION_NOTICE =
  "이 상태는 자료의 수집·공개·검토 상태이며 위법성이나 부패 여부에 대한 판단이 아닙니다.";

export const PUBLIC_SEARCH_AWAITING_QUERY_DESCRIPTION =
  "검색어를 입력하면 공개 사례·기관·업체·계약·규칙·데이터셋·출처를 함께 찾을 수 있습니다.";

const PUBLICATION_NOTICES: Readonly<Record<string, string>> = {
  PUBLISHED_ANOMALY:
    "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. 현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
  PUBLISHED_EXPLAINED:
    "처음 탐지된 차이는 추가 자료에서 확인된 구성·서비스·조건의 차이로 설명됩니다. 탐지와 검증 과정을 함께 공개합니다.",
  OFFICIALLY_CONFIRMED:
    "가상 공개기관의 공식 확인서·2026.07.16에서 계약 물량과 이행 조건이 확인됐습니다. 구린네의 자체 판단이 아니라 해당 공식 결과를 요약합니다.",
  CORRECTED:
    "이 페이지는 2026.07.26에 정정됐습니다. 부가가치세 포함 여부 오기와 공개 금액에 미친 영향을 아래 정정 기록에서 확인할 수 있습니다.",
  RETRACTED:
    "핵심 근거의 오류로 이 게시물을 철회했습니다. 원래 주장은 더 이상 유효하지 않습니다. 오류 원인과 후속 조치를 공개합니다.",
  TEMPORARILY_RESTRICTED:
    "법적 사유, 권리 보호 또는 안전을 위해 공개를 일시 제한했습니다. 이 제한은 위법성이나 부패 여부에 대한 판단이 아닙니다.",
};

export function publicNonConclusion(publicState: string): string {
  const notice = PUBLICATION_NOTICES[publicState];
  if (!notice)
    throw new Error(`공개 mock 비확정 고지 상태 누락: ${publicState}`);
  return notice;
}

export function publicSeo(
  title: string,
  canonicalUrl: string,
  notices: readonly string[],
) {
  const description = [...new Set(notices.map((notice) => notice.trim()))]
    .filter(Boolean)
    .join(" · ");
  if (!description) throw new Error(`공개 mock SEO 고지 누락: ${canonicalUrl}`);
  return {
    title: `${title} · 구린네`,
    description,
    openGraphDescription: description,
    canonicalUrl,
    robots: "index,follow",
  };
}

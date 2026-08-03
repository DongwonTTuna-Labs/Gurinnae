import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const component = readFileSync(
  new URL("./components/sections/PrivacyRequestStatus.svelte", import.meta.url),
  "utf8",
);
const legalSection = readFileSync(
  new URL("./components/sections/LegalContentSection.svelte", import.meta.url),
  "utf8",
);

describe("privacy request status presentation", () => {
  it("renders only the closed Korean status ledger inside PUB-031 rights", () => {
    expect(legalSection).toContain('section.id === "rights"');
    expect(legalSection).toContain("runtime.privacyRequestStatus");
    expect(component).toContain('aria-label="개인정보 요청 처리 상태"');
    for (const label of [
      "요청 유형",
      "처리 상태",
      "신원 확인",
      "처리 기한",
      "다음 단계",
      "기준 시각",
    ])
      expect(component).toContain(`<dt>${label}</dt>`);
  });

  it("keeps request IDs, receipt digests and raw tokens outside the component", () => {
    for (const forbidden of [
      "privacyRequestId",
      "decisionReceiptId",
      "receiptSha256",
      "scopeDigest",
      "opaqueSessionToken",
      "receiptToken",
    ])
      expect(component).not.toContain(forbidden);
    expect(component).toContain("신원 확인 후 산정");
    expect(component).toContain(
      "개인정보 요청 상태를 지금 확인할 수 없습니다.",
    );
  });
});

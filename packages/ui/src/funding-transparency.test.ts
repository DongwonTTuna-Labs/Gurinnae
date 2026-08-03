import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  fundingDisclosureStatusLabel,
  fundingTimestampLabel,
} from "./funding-transparency";

const fundingSection = readFileSync(
  new URL(
    "./components/sections/PublicFundingTransparencySection.svelte",
    import.meta.url,
  ),
  "utf8",
);

describe("funding transparency presentation", () => {
  it("maps every closed status to a Korean public label", () => {
    expect(fundingDisclosureStatusLabel("AVAILABLE")).toBe("공개됨");
    expect(fundingDisclosureStatusLabel("UNKNOWN")).toBe("확인 불가");
    expect(fundingDisclosureStatusLabel("UNAVAILABLE")).toBe("공개 자료 없음");
  });

  it("presents a validated timestamp without exposing raw ISO text", () => {
    const label = fundingTimestampLabel("2026-08-02T12:00:00Z");

    expect(label).toBe("2026.08.02 12:00 UTC");
    expect(label).not.toContain("T12:00:00Z");
    expect(fundingTimestampLabel("not-a-timestamp")).toBe("확인 불가");
  });

  it("does not expose internal projection or revision terms in static copy", () => {
    expect(fundingSection).not.toMatch(
      /projection|revision|transparency report/iu,
    );
    expect(fundingSection).toContain("승인 공개 개정별 투명성 보고서");
    expect(fundingSection).toContain("공개 재원 자료를 검증할 수 없어");
    expect(fundingSection).toContain('class="report-record-list"');
    expect(fundingSection).toContain("min-width: 44px");
    expect(fundingSection).toContain("min-height: 44px");
  });
});

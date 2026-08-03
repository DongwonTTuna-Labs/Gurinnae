import { describe, expect, it } from "vitest";
import { screen } from "./screen";

describe("PUB-035 public copy", () => {
  it("keeps authority and cadence meaning without exposing runtime tokens", () => {
    const copy = screen.sections.map((section) => section.purpose).join("\n");

    expect(screen.sections[0]?.purpose).toBe(
      "테스트 전용 제안만 제공하며 운영 기준이 없으면 후원을 접수하지 않습니다.",
    );
    expect(copy).toContain("일회·정기 후원");
    expect(copy).toContain("접수 대기 영수증");
    expect(copy).not.toMatch(
      /TEST_FIXTURE|NO_PRODUCTION_AUTHORITY|UNAVAILABLE|ONE_TIME|RECURRING|TOSS_PAYMENTS|KAKAO_PAY|STRIPE|QUEUED/u,
    );
  });

  it("preserves the exact donation independence notice", () => {
    const independence = screen.sections.find(
      (section) => section.id === "independence",
    );

    expect(independence?.purpose).toBe(
      "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
    );
  });
});

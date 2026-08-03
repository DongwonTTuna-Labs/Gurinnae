import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const component = readFileSync(
  new URL("./components/sections/LegalContentSection.svelte", import.meta.url),
  "utf8",
);

describe("legal-document retention schedule presentation", () => {
  it("renders the typed projection as one compact accessible ledger table", () => {
    expect(component).toContain("projection?.retentionSchedules");
    expect(component).toContain(
      'screen.id === "PUB-032" && section.id === "data"',
    );
    expect(component).toContain("aria-label={retentionScheduleLabel}");
    expect(component).toContain("이용약관 기록 유형별 보존 일정");
    expect(component).toContain("<table>");
    for (const heading of [
      "기록 유형",
      "처리 목적",
      "법적 근거",
      "기산점",
      "활성 보존",
      "백업 보존",
      "종료 처리",
      "효력 발생",
      "검토 만료",
    ])
      expect(component).toContain(`<th scope="col">${heading}</th>`);
    expect(component).not.toContain("runtime.data");
    expect(component).not.toContain("scheduleDigest");
  });

  it("fails closed instead of rendering policy copy without its schedule", () => {
    expect(component).toContain("retentionTableMissing");
    expect(component).toContain('class="inline-state conflict" role="alert"');
    expect(component).toContain(
      "승인된 보존 일정을 확인할 수 없어 개인정보 처리방침 표시를 보류했습니다.",
    );
    expect(component).toContain(
      "승인된 보존 일정이 없어 이용약관을 공개할 수 없습니다.",
    );
  });
});

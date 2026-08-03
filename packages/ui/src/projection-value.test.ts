import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  presentProjectionValue,
  projectionScalarText,
} from "./projection-value";
import {
  authoritySectionStatus,
  safeProjectionValue,
} from "./screen-projection-values";

describe("projection value presentation", () => {
  it("formats enum, ISO date, money, duration and UUID values", () => {
    expect(projectionScalarText("status", "PUBLISHED")).toBe("게시됨");
    expect(projectionScalarText("createdAt", "2026-07-30T14:05:00Z")).toBe(
      "2026.07.30",
    );
    expect(projectionScalarText("totalAmountKrw", 125_000_000)).toBe(
      "₩125,000,000 · 약 1.25억 원",
    );
    expect(projectionScalarText("ttlSeconds", 5_490)).toBe("1시간 31분");
    expect(
      presentProjectionValue("caseId", "123e4567-e89b-12d3-a456-426614174000"),
    ).toMatchObject({
      valueKind: "uuid",
      text: "123e4567…",
      title: "123e4567-e89b-12d3-a456-426614174000",
      copyText: "123e4567-e89b-12d3-a456-426614174000",
    });
  });

  it("adds relative time only with an explicit deterministic reference", () => {
    expect(
      presentProjectionValue("expiresAt", "2026-07-31T00:00:00Z", {
        relativeTo: new Date("2026-07-30T00:00:00Z"),
      }),
    ).toMatchObject({ text: "2026.07.31", secondary: "1일 후" });
  });

  it("does not guess that generic limits and counters are money", () => {
    expect(projectionScalarText("rateLimit", 1_000)).toBe("1,000");
    expect(projectionScalarText("pageLimit", 1_000)).toBe("1,000");
    expect(projectionScalarText("itemCount", 1_000)).toBe("1,000");
    expect(projectionScalarText("budgetVersion", 1_000)).toBe("1,000");
  });

  it("keeps objects and arrays as bounded typed structures", () => {
    const value = safeProjectionValue(
      {
        status: "READY",
        token: "must-not-render",
        items: ["첫째", null, "둘째", "셋째", "넷째", "다섯째"],
      },
      "record",
    );
    expect(value).toMatchObject({ kind: "record", omittedCount: 0 });
    if (!value || typeof value !== "object" || value.kind !== "record")
      throw new Error("record projection expected");
    expect(value.entries.map((entry) => entry.name)).toEqual([
      "status",
      "items",
    ]);
    expect(
      value.entries.find((entry) => entry.name === "items")?.value,
    ).toMatchObject({ kind: "list", omittedCount: 2 });
    expect(JSON.stringify(value)).not.toContain("must-not-render");
    expect(safeProjectionValue([])).toBeNull();
    expect(safeProjectionValue({ token: "redacted" })).toBeNull();
  });

  it("keeps a public status and its legal notice before bounded truncation", () => {
    const value = safeProjectionValue({
      slug: "case-1",
      title: "공개 사건",
      summary: "사건 요약",
      revision: 3,
      updatedAt: "2026-07-30T00:00:00Z",
      href: "/cases/case-1",
      publicState: "PUBLISHED_ANOMALY",
      nonConclusion:
        "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.",
    });
    if (!value || typeof value !== "object" || value.kind !== "record")
      throw new Error("record projection expected");
    expect(value.entries.map((entry) => entry.name).slice(0, 2)).toEqual([
      "publicState",
      "nonConclusion",
    ]);
  });

  it("keeps the complete home-correction row beside its legal notice", () => {
    const value = safeProjectionValue({
      id: "correction-1",
      sourceRevision: 1,
      targetRevision: 2,
      summary: "계약 기간 표기 정정",
      reason: "종료일을 원문 계약서 기준으로 바로잡았습니다.",
      publicState: "CORRECTED",
      nonConclusion: "정정 시각과 영향을 아래 기록에서 확인할 수 있습니다.",
      publishedAt: "2026-07-30T00:00:00Z",
      href: "/corrections/correction-1",
    });
    if (!value || typeof value !== "object" || value.kind !== "record")
      throw new Error("record projection expected");
    expect(value.entries.map((entry) => entry.name)).toEqual([
      "publicState",
      "nonConclusion",
      "summary",
      "reason",
      "id",
      "publishedAt",
    ]);
  });

  it("selects one authority status by explicit priority", () => {
    expect(
      authoritySectionStatus({
        projectionPresent: true,
        projectionState: "UNKNOWN",
        runtimeState: "empty",
        declaredFieldCount: 2,
        knownFieldCount: 0,
      }),
    ).toMatchObject({ tone: "stale", suppressValues: true });
  });

  it("does not keep hidden per-field unknown chrome in OperationData", () => {
    const source = readFileSync(
      new URL("./components/OperationData.svelte", import.meta.url),
      "utf8",
    );
    expect(source).not.toContain("unknown-fields");
    expect(source).not.toContain(":has(");
    expect(source).not.toContain("서버 권위");
  });
});

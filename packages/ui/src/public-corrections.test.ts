import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildHomeCorrections } from "./public-corrections";
import type { ScreenSectionProjection } from "./screen-projection";

describe("closed home corrections", () => {
  it("binds summary, reason, public status and notice in one row", () => {
    expect(buildHomeCorrections(projection())).toEqual([
      {
        key: "/corrections/correction-1",
        summary: "계약 금액 표기 정정",
        reason: "부가가치세 포함 여부 수정",
        status: "정정됨",
        publishedAt: "2026.07.29",
        notice: {
          kind: "NON_CONCLUSION",
          label: "비확정 고지",
          text: "정정 사실과 영향을 아래 기록에서 확인할 수 있습니다.",
        },
        href: "/corrections/correction-1",
      },
    ]);
  });

  it("renders each mapped correction as a dated projection record", () => {
    const source = readFileSync(
      new URL(
        "./components/sections/PublicCorrections.svelte",
        import.meta.url,
      ),
      "utf8",
    );
    expect(source).toContain('<li class="projection-record">');
    expect(source).toContain("게시일 {item.publishedAt}");
  });

  it("fails closed when a public correction omits its notice", () => {
    const value = projection();
    const itemsField = value.fields[0];
    if (!itemsField) throw new Error("정정 검증 기준 필드 누락");
    const items = itemsField.value;
    if (items === null || typeof items !== "object" || items.kind !== "list")
      throw new Error("정정 검증 기준 목록 누락");
    const first = items.items[0];
    if (
      first === undefined ||
      typeof first !== "object" ||
      first.kind !== "record"
    )
      throw new Error("정정 검증 기준 행 누락");
    expect(() =>
      buildHomeCorrections({
        ...value,
        fields: [
          {
            ...itemsField,
            name: "items",
            label: "정정 목록",
            known: true,
            source: "listCorrections.$.items",
            value: {
              kind: "list",
              items: [
                {
                  ...first,
                  entries: first.entries.filter(
                    (entry) => entry.name !== "nonConclusion",
                  ),
                },
              ],
              omittedCount: 0,
            },
          },
        ],
      }),
    ).toThrow("비확정 고지 계약 누락");
  });
});

function projection(): ScreenSectionProjection {
  return {
    screenId: "PUB-001",
    sectionId: "corrections",
    region: "state",
    component: "PublicCorrections",
    fields: [
      {
        name: "items",
        label: "정정 목록",
        known: true,
        source: "listCorrections.$.items",
        value: {
          kind: "list",
          items: [
            {
              kind: "record",
              entries: Object.entries({
                id: "correction-1",
                summary: "계약 금액 표기 정정",
                reason: "부가가치세 포함 여부 수정",
                publicState: "CORRECTED",
                nonConclusion:
                  "정정 사실과 영향을 아래 기록에서 확인할 수 있습니다.",
                publishedAt: "2026-07-29T09:10:00Z",
                href: "https://attacker.invalid/corrections/correction-1",
              }).map(([name, value]) => ({ name, label: name, value })),
              omittedCount: 0,
            },
          ],
          omittedCount: 0,
        },
      },
    ],
    state: "READY",
    errorMessage: null,
    focusTarget: "pub_001__state__success__corrections",
  };
}

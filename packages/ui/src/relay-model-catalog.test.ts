import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  RELAY_UNPRICED_CAPTION,
  relayModelCatalogViewModel,
} from "./relay-model-catalog";

describe("relay model catalog view model", () => {
  it("keeps every required model and provider state outside generic previews", () => {
    expect(
      relayModelCatalogViewModel({
        items: [
          {
            modelId: "relay-latest",
            family: "relay",
            createdAt: "2026-07-29T00:00:00Z",
            active: true,
            new: true,
          },
        ],
        currentProviders: [
          {
            providerId: "provider-relay",
            name: "relay",
            currentModel: "relay-latest",
            enabled: true,
            autoUpgrade: true,
            autoUpgradeConflict: true,
            unpriced: true,
          },
        ],
      }),
    ).toEqual({
      models: [
        {
          modelId: "relay-latest",
          family: "relay",
          createdAt: "2026-07-29T00:00:00Z",
          active: true,
          current: true,
          new: true,
          adoption: "기록 없음",
        },
      ],
      providers: [
        {
          providerId: "provider-relay",
          name: "relay",
          currentModel: "relay-latest",
          enabled: true,
          autoUpgrade: true,
          autoUpgradeConflict: true,
          unpriced: true,
        },
      ],
      caption: RELAY_UNPRICED_CAPTION,
    });
  });

  it("fails closed when a required catalog state is absent", () => {
    expect(
      relayModelCatalogViewModel({ items: [{}], currentProviders: [] }),
    ).toBeUndefined();
  });

  it("pins the explicit ledger columns and exact unpriced caption", () => {
    const source = readFileSync(
      new URL(
        "./components/sections/RelayModelCatalogLedger.svelte",
        import.meta.url,
      ),
      "utf8",
    );
    for (const heading of [
      "모델 식별자",
      "모델 계열",
      "공개 시각",
      "현재 사용",
      "신규",
      "채택 기록",
      "현재 모델",
      "자동 업그레이드",
      "자동 업그레이드 충돌",
      "단가 상태",
    ])
      expect(source).toContain(heading);
    expect(source).toContain("{RELAY_UNPRICED_CAPTION}");
    expect(RELAY_UNPRICED_CAPTION).toBe("단가 미설정: 비용 0으로 기록");
    expect(source).not.toContain("slice(0, 6)");
  });
});

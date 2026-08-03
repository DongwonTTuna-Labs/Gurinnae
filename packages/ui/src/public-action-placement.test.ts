import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parse } from "yaml";
import {
  PUBLIC_ACTION_PLACEMENT_SCREEN_IDS,
  publicActionPlacement,
} from "./public-action-placement";

type CatalogScreen = Readonly<{
  id: string;
  actions: readonly Readonly<{ id: string }>[];
}>;

function publicCatalogScreens(): readonly CatalogScreen[] {
  const document: unknown = parse(
    readFileSync(
      new URL("../../../specs/ui/screen-catalog.yaml", import.meta.url),
      "utf8",
    ),
  );
  if (!isCatalog(document))
    throw new Error("화면 카탈로그 형식이 올바르지 않습니다.");
  return document.screens.filter((screen) => screen.id.startsWith("PUB-"));
}

describe("public action placement", () => {
  it("classifies every action on all 34 public screens exactly once", () => {
    const screens = publicCatalogScreens();
    expect(screens).toHaveLength(34);
    expect(PUBLIC_ACTION_PLACEMENT_SCREEN_IDS).toHaveLength(34);
    expect(new Set(PUBLIC_ACTION_PLACEMENT_SCREEN_IDS)).toEqual(
      new Set(screens.map((screen) => screen.id)),
    );
    for (const screen of screens)
      expect(publicActionPlacement(screen)).toBeDefined();
  });

  it("fails closed for a new or duplicated public action", () => {
    const screen = publicCatalogScreens()[0];
    if (!screen) throw new Error("공개 화면 계약이 없습니다.");
    expect(() =>
      publicActionPlacement({
        ...screen,
        actions: [...screen.actions, { id: "unclassified-action" }],
      }),
    ).toThrow("미분류: unclassified-action");
    expect(() =>
      publicActionPlacement({
        ...screen,
        actions: [...screen.actions, screen.actions[0] ?? { id: "search" }],
      }),
    ).toThrow("action 중복");
    expect(() => publicActionPlacement({ id: "PUB-035", actions: [] })).toThrow(
      "미분류 공개 화면",
    );
  });

  it("keeps server forms and attachments in their owning sections", () => {
    const byId = new Map(
      publicCatalogScreens().map((screen) => [screen.id, screen]),
    );
    const correction = byId.get("PUB-027");
    const contact = byId.get("PUB-026");
    const preferences = byId.get("PUB-030");
    if (!correction || !contact || !preferences)
      throw new Error("공개 폼 화면 계약이 없습니다.");

    expect(publicActionPlacement(contact)?.sectionActionIds).toEqual({
      form: ["submit-contact"],
    });
    expect(publicActionPlacement(correction)).toMatchObject({
      sectionActionIds: { review: ["submit-correction"] },
      componentActionIds: ["save-draft"],
      attachmentSectionId: "evidence",
    });
    expect(publicActionPlacement(preferences)?.sectionActionIds).toEqual({
      preferences: ["save-preferences", "unsubscribe"],
    });
  });

  it("appends public ledger downloads without replacing primary interactions", () => {
    const byId = new Map(
      publicCatalogScreens().map((screen) => [screen.id, screen]),
    );
    const search = byId.get("PUB-002");
    const cases = byId.get("PUB-003");
    if (!search || !cases) throw new Error("공개 대장 화면 계약이 없습니다.");

    expect(publicActionPlacement(search)).toMatchObject({
      headerActionIds: ["clear", "download-csv", "download-jsonl"],
      componentActionIds: ["submit-search", "open-result"],
    });
    expect(publicActionPlacement(cases)).toMatchObject({
      headerActionIds: ["subscribe-filter", "download-csv", "download-jsonl"],
      componentActionIds: ["apply-filter", "open-case"],
    });
  });
});

function isCatalog(value: unknown): value is { screens: CatalogScreen[] } {
  if (!isRecord(value) || !Array.isArray(value.screens)) return false;
  return value.screens.every(
    (screen) =>
      isRecord(screen) &&
      typeof screen.id === "string" &&
      Array.isArray(screen.actions) &&
      screen.actions.every(
        (action) => isRecord(action) && typeof action.id === "string",
      ),
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

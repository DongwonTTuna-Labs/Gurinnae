import { type ScreenViewModel, typedScreenViewModel } from "@gurine/ui";
import { describe, expect, it } from "vitest";

const screens = Object.values(
  import.meta.glob("./routes/**/screen.ts", { eager: true, import: "screen" }),
);

const EXPLICITLY_EMPTY_PROJECTION_SECTIONS = new Set([
  "PUB-020.schemas",
  "PUB-020.license",
  "PUB-020.corrections",
  "PUB-020.limits",
]);

describe("public screen manifest", () => {
  it("materializes all 34 unique public screens", () => {
    assertScreens(screens, 34);
    assertTypedContracts(screens);
  });
});

function assertTypedContracts(values: unknown[]): void {
  const emptyProjectionSections = new Set<string>();
  for (const value of values) {
    const screen = value as ScreenViewModel;
    const typed = typedScreenViewModel(screen);
    expect(typed.screenId).toBe(screen.id);
    expect(typed.sections.map((section) => section.id)).toEqual(
      screen.sections.map((section) => section.id),
    );
    for (const section of typed.sections) {
      if (section.fields.length === 0) {
        emptyProjectionSections.add(`${screen.id}.${section.id}`);
      }
    }
  }
  expect(emptyProjectionSections).toEqual(EXPLICITLY_EMPTY_PROJECTION_SECTIONS);
}

function assertScreens(values: unknown[], expected: number): void {
  expect(values).toHaveLength(expected);
  const ids = new Set<string>();
  const routes = new Set<string>();
  for (const value of values) {
    if (!isRecord(value)) throw new Error("screen export is not an object");
    const id = stringField(value, "id");
    const route = stringField(value, "route");
    if (ids.has(id) || routes.has(route))
      throw new Error(`duplicate screen: ${id} ${route}`);
    ids.add(id);
    routes.add(route);
    arrayField(value, "sections");
    arrayField(value, "actions");
    const states = value.states;
    if (
      (Array.isArray(states) && states.length === 0) ||
      states === undefined
    ) {
      throw new Error(`${id} has no declared states`);
    }
    arrayField(value, "dataOperations");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringField(value: Record<string, unknown>, name: string): string {
  const field = value[name];
  if (typeof field !== "string" || field === "")
    throw new Error(`${name} is invalid`);
  return field;
}

function arrayField(value: Record<string, unknown>, name: string): unknown[] {
  const field = value[name];
  if (!Array.isArray(field)) throw new Error(`${name} is not an array`);
  return field;
}

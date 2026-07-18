import { describe, expect, it } from "vitest";
import { typedScreenViewModel, type ScreenViewModel } from "@gurine/ui";

const screens = Object.values(
  import.meta.glob("./routes/**/screen.ts", { eager: true, import: "screen" }),
);

describe("internal screen manifest", () => {
  it("materializes all 52 unique internal screens", () => {
    assertScreens(screens, 52);
    assertTypedContracts(screens);
  });
});

function assertTypedContracts(values: unknown[]): void {
  for (const value of values) {
    const screen = value as ScreenViewModel;
    const typed = typedScreenViewModel(screen);
    expect(typed.screenId).toBe(screen.id);
    expect(typed.sections.map((section) => section.id)).toEqual(screen.sections.map((section) => section.id));
    expect(typed.sections.every((section) => section.fields.length > 0)).toBe(true);
  }
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

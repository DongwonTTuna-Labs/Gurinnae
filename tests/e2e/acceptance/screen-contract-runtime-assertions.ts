import { globSync, readFileSync } from "node:fs";
import { basename, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { expect } from "@playwright/test";
import {
  apiOperations,
  arrayValue,
  assertResponse,
  assertUnique,
  catalogScreens,
  objectValue as contractObjectValue,
  stringValue as contractStringValue,
  stringList,
  yamlObject,
} from "./screen-contract-assertions";

type ObjectValue = Record<string, unknown>;
type DataOperation = {
  operationId: string;
  api: string;
  method: string;
  path: string;
  responseSchema: string;
};
type RouteScreen = {
  id: string;
  route: string;
  dataOperations: DataOperation[];
};

function isObjectValue(value: unknown): value is ObjectValue {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function objectValue(value: unknown, context: string): ObjectValue {
  if (!isObjectValue(value)) throw new Error(`${context} must be an object`);
  return value;
}

function stringValue(value: unknown, context: string): string {
  if (typeof value !== "string" || value.trim() === "")
    throw new Error(`${context} must be a non-empty string`);
  return value;
}

let routeScreenPromise: Promise<RouteScreen[]> | undefined;
function routeScreens(): Promise<RouteScreen[]> {
  routeScreenPromise ??= Promise.all(
    globSync("apps/*/src/routes/**/screen.ts")
      .sort()
      .map(async (path) => {
        const loaded: unknown = await import(pathToFileURL(resolve(path)).href);
        const screen = objectValue(
          objectValue(loaded, path).screen,
          `${path}.screen`,
        );
        if (!Array.isArray(screen.dataOperations))
          throw new Error(`${path}.screen.dataOperations must be an array`);
        return {
          id: stringValue(screen.id, `${path}.screen.id`),
          route: stringValue(screen.route, `${path}.screen.route`),
          dataOperations: screen.dataOperations.map((value, index) => {
            const item = objectValue(value, `${path}.dataOperations[${index}]`);
            return {
              operationId: stringValue(
                item.operation_id,
                `${path}.operation_id`,
              ),
              api: stringValue(item.api, `${path}.api`),
              method: stringValue(item.method, `${path}.method`),
              path: stringValue(item.path, `${path}.path`),
              responseSchema: stringValue(
                item.response_schema,
                `${path}.response_schema`,
              ),
            };
          }),
        };
      }),
  );
  return routeScreenPromise;
}

export async function assertScreenInventory(): Promise<void> {
  const catalog = catalogScreens().map(
    ({ id, surface, route, testPrefix }) => ({
      id,
      surface,
      route,
      testPrefix,
    }),
  );
  const modules = await routeScreens();
  expect(catalog, "screen catalog count").toHaveLength(94);
  for (const [surface, count] of [
    ["public", 34],
    ["response", 8],
    ["internal", 52],
  ] as const)
    expect(
      catalog.filter((screen) => screen.surface === surface),
      `${surface} screens`,
    ).toHaveLength(count);
  assertUnique(
    catalog.map((screen) => screen.id),
    "screen ids unique",
  );
  assertUnique(
    catalog.map((screen) => screen.testPrefix),
    "screen test prefixes unique",
  );
  assertUnique(
    catalog.map((screen) => screen.route),
    "screen routes unique",
  );
  for (const surface of ["public", "response", "internal"])
    assertUnique(
      catalog
        .filter((screen) => screen.surface === surface)
        .map((screen) => screen.route),
      `${surface} routes unique`,
    );
  expect(modules, "route screen modules").toHaveLength(94);
  assertUnique(
    modules.map((screen) => screen.id),
    "route module ids unique",
  );
  expect(
    modules.map(({ id, route }) => `${id}\0${route}`).sort(),
    "catalog ↔ screen.ts",
  ).toEqual(catalog.map(({ id, route }) => `${id}\0${route}`).sort());
}

export async function assertRouteOperationOwnership(): Promise<void> {
  const data = (await routeScreens()).flatMap(
    (screen) => screen.dataOperations,
  );
  const operations = apiOperations();
  expect(data, "screen.ts dataOperations").toHaveLength(225);
  for (const item of data) {
    const matches = operations.filter(
      (operation) => operation.id === item.operationId,
    );
    expect(matches, `${item.operationId} matching API ownership`).toHaveLength(
      1,
    );
    const match = matches[0];
    if (!match) continue;
    expect(
      [match.api, match.method, match.path],
      `${item.operationId} route contract`,
    ).toEqual([item.api, item.method, item.path]);
    assertResponse(match, item.responseSchema, item.operationId);
  }
}

export function assertProductBeforeImplementation(): void {
  for (const screen of catalogScreens()) {
    expect(screen.users.length, `${screen.id} primary users`).toBeGreaterThan(
      0,
    );
    expect(
      screen.questions.length,
      `${screen.id} user questions`,
    ).toBeGreaterThan(0);
    expect(screen.job.length, `${screen.id} primary job`).toBeGreaterThan(0);
    expect(
      screen.sections.every((entry) => entry.complete),
      `${screen.id} complete sections`,
    ).toBe(true);
    expect(
      screen.sections.map((entry) => entry.order),
      `${screen.id} sequential sections`,
    ).toEqual(screen.sections.map((_, index) => index + 1));
    expect(screen.aboveFold, `${screen.id} above-fold prefix`).toEqual(
      screen.sections
        .slice(0, screen.aboveFold.length)
        .map((entry) => entry.id),
    );
    expect(
      screen.implementationFileCount,
      `${screen.id} implementation files`,
    ).toBeGreaterThan(0);
    expect(
      screen.keyOrder.indexOf("sections"),
      `${screen.id} product contract ordering`,
    ).toBeLessThan(screen.keyOrder.indexOf("implementation_files"));
  }
}

export function catalogScreenIds(): string[] {
  return catalogScreens()
    .map((screen) => screen.id)
    .sort();
}

export function catalogPrimaryActions(): Map<string, string> {
  return new Map(
    catalogScreens().map((screen) => [screen.id, screen.primaryActionId]),
  );
}

export function assertHumanReadableSheets(): void {
  const direct = globSync("specs/ui/screens/*.md").sort();
  const nested = globSync("specs/ui/screens/**/*.md").filter((path) =>
    relative("specs/ui/screens", path).includes("/"),
  );
  expect(direct, "direct screen sheets").toHaveLength(94);
  expect(nested, "milestone-era nested screen sheets").toEqual([]);
  expect(
    direct.map((path) => basename(path, ".md")).sort(),
    "sheet ↔ catalog ids",
  ).toEqual(catalogScreenIds());
  const required = [
    /^Route: /m,
    /^## 사용자 목적$/m,
    /^## 이 화면이 즉시 답해야 하는 질문$/m,
    /^## 최종 정보 순서$/m,
    /^## Layout$/m,
    /^## Actions$/m,
    /^## Data contracts$/m,
    /^## Required states$/m,
    /^## Accessibility contract$/m,
    /^## Acceptance$/m,
  ];
  for (const path of direct) {
    const markdown = readFileSync(path, "utf8");
    for (const pattern of required)
      expect(markdown, `${path} ${pattern.source}`).toMatch(pattern);
  }
}

export function assertFinalComponents(): void {
  const sections = catalogScreens().flatMap((screen) => screen.sections);
  const document = yamlObject("specs/ui/component-catalog.yaml");
  const components = arrayValue(document.components, "components").map(
    (value, index) => {
      const item = contractObjectValue(value, `components[${index}]`);
      return {
        id: contractStringValue(item.id, `components[${index}].id`),
        status: contractStringValue(item.status, `components[${index}].status`),
        complete: [
          "anatomy",
          "variants",
          "states",
          "accessibility",
          "implementation_requirements",
        ].every(
          (key) =>
            arrayValue(item[key], `components[${index}].${key}`).length > 0,
        ),
      };
    },
  );
  expect(sections, "section component references").toHaveLength(492);
  expect(components, "component catalog").toHaveLength(58);
  assertUnique(
    components.map((component) => component.id),
    "component ids unique",
  );
  const ids = components.map((component) => component.id);
  for (const component of components) {
    expect(component.status, `${component.id} status`).toBe("FINAL");
    expect(component.complete, `${component.id} contract completeness`).toBe(
      true,
    );
  }
  for (const entry of sections)
    expect(ids, `${entry.component} component reference`).toContain(
      entry.component,
    );
}

export function assertAnalyticsMapping(): void {
  const screens = catalogScreens();
  const declared = screens.flatMap((screen) =>
    screen.analytics.map((event) => ({ event, screenId: screen.id })),
  );
  const document = yamlObject("specs/ui/analytics-events.yaml");
  const commonForbidden = stringList(
    document.common_forbidden,
    "common_forbidden",
  );
  const events = arrayValue(document.events, "events").map((value, index) => {
    const item = contractObjectValue(value, `events[${index}]`);
    return {
      name: contractStringValue(item.name, `events[${index}].name`),
      consumers: stringList(item.consumers, `events[${index}].consumers`),
      allowed: stringList(
        item.allowed_properties,
        `events[${index}].allowed_properties`,
      ),
      forbidden: stringList(
        item.forbidden_properties,
        `events[${index}].forbidden_properties`,
      ),
    };
  });
  expect(declared, "screen analytics occurrences").toHaveLength(241);
  expect(events, "analytics event catalog").toHaveLength(233);
  assertUnique(
    events.map((event) => event.name),
    "analytics event names unique",
  );
  expect(
    [...new Set(declared.map((entry) => entry.event))].sort(),
    "screen → event closure",
  ).toEqual(events.map((event) => event.name).sort());
  const screenEvents = new Set(
    declared.map((entry) => `${entry.screenId}\0${entry.event}`),
  );
  for (const event of events) {
    for (const consumer of event.consumers)
      expect(
        screenEvents.has(`${consumer}\0${event.name}`),
        `${event.name} → ${consumer}`,
      ).toBe(true);
    const forbidden = new Set([...commonForbidden, ...event.forbidden]);
    expect(
      event.allowed.filter((property) => forbidden.has(property)),
      `${event.name} payload privacy`,
    ).toEqual([]);
  }
  for (const entry of declared) {
    const event = events.find((candidate) => candidate.name === entry.event);
    expect(event?.consumers, `${entry.screenId} → ${entry.event}`).toContain(
      entry.screenId,
    );
  }
}

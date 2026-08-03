import { readFileSync } from "node:fs";
import { resolve } from "node:path";

export type RouteContract = {
  screenId: string;
  surface: string;
  route: string;
  app: string;
  url: string;
  sections: Array<{ id: string; component: string }>;
};

const ports: Record<string, number> = {
  "apps/public-web": 29101,
  "apps/review-console": 29102,
  "apps/response-portal": 29103,
};

export function routeCatalog(): RouteContract[] {
  const text = readFileSync(
    resolve("specs/repository/frontend-route-map.yaml"),
    "utf8",
  );
  const contracts: Array<Omit<RouteContract, "url">> = [];
  let current: Partial<Omit<RouteContract, "url">> | undefined;
  for (const line of text.split("\n")) {
    if (line.startsWith("- screen_id: ")) {
      if (complete(current)) contracts.push(current);
      current = { screenId: line.slice("- screen_id: ".length).trim() };
    } else if (current && line.startsWith("  surface: ")) {
      current.surface = line.slice("  surface: ".length).trim();
    } else if (current && line.startsWith("  route: ")) {
      current.route = line.slice("  route: ".length).trim();
    } else if (current && line.startsWith("  app: ")) {
      current.app = line.slice("  app: ".length).trim();
    }
  }
  if (complete(current)) contracts.push(current);
  if (contracts.length !== 94)
    throw new Error(
      `route catalog expected 94 screens, got ${contracts.length}`,
    );
  const sections = screenSections();
  return contracts.map((contract) => ({
    ...contract,
    url: `http://127.0.0.1:${ports[contract.app]}${materializeRoute(contract.route)}`,
    sections: sections.get(contract.screenId) ?? [],
  }));
}

function screenSections(): Map<
  string,
  Array<{ id: string; component: string }>
> {
  const text = readFileSync(
    resolve("specs/ui/screen-build-manifest.yaml"),
    "utf8",
  );
  const result = new Map<string, Array<{ id: string; component: string }>>();
  let screenId: string | undefined;
  let sectionId: string | undefined;
  for (const line of text.split("\n")) {
    if (line.startsWith("- id: ")) {
      screenId = line.slice(6).trim();
      result.set(screenId, []);
      sectionId = undefined;
    } else if (screenId && line.startsWith("    id: ")) {
      sectionId = line.slice(8).trim();
    } else if (screenId && sectionId && line.startsWith("    component: ")) {
      result
        .get(screenId)
        ?.push({ id: sectionId, component: line.slice(15).trim() });
      sectionId = undefined;
    }
  }
  return result;
}

function complete(
  value: Partial<Omit<RouteContract, "url">> | undefined,
): value is Omit<RouteContract, "url"> {
  return Boolean(
    value?.screenId &&
      value.surface &&
      value.route &&
      value.app &&
      ports[value.app],
  );
}

function materializeRoute(route: string): string {
  return route.replaceAll(/\{([^}]+)\}/g, (_, name: string) =>
    name.toLowerCase().includes("slug") || name.toLowerCase().includes("path")
      ? "synthetic-record"
      : "80000000-0000-4000-8000-000000000001",
  );
}

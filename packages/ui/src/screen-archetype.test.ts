import { readFileSync } from "node:fs";
import { compile } from "svelte/compiler";
import { describe, expect, it } from "vitest";
import {
  ARCHETYPE_ASSEMBLIES,
  ARCHETYPE_ASSEMBLY_IDS,
  archetypeAssemblyFor,
  SCREEN_ARCHETYPES,
} from "./screen-archetype";

type CatalogScreen = { id: string; archetype: string };

function screenArchetypesFrom(fileName: string): CatalogScreen[] {
  const source = readFileSync(
    new URL(`../../../specs/ui/${fileName}`, import.meta.url),
    "utf8",
  );
  const screens: CatalogScreen[] = [];
  let screenId: string | undefined;
  for (const line of source.split("\n")) {
    const idMatch = line.match(/^- id: ([A-Z]+-[0-9]+)$/u);
    if (idMatch?.[1]) {
      screenId = idMatch[1];
      continue;
    }
    const archetypeMatch = line.match(/^ {2}archetype: ([A-Z_]+)$/u);
    if (screenId && archetypeMatch?.[1]) {
      screens.push({ id: screenId, archetype: archetypeMatch[1] });
      screenId = undefined;
    }
  }
  return screens;
}

const catalogScreens = screenArchetypesFrom("screen-catalog.yaml");
const manifestScreens = screenArchetypesFrom("screen-build-manifest.yaml");
const authorityArchetypes = [
  ...readFileSync(
    new URL("../../../specs/ui/page-archetypes.yaml", import.meta.url),
    "utf8",
  ).matchAll(/^- id: ([A-Z_]+)$/gmu),
].map((match) => match[1]);
const assemblyComponents = [
  {
    id: "evidence-landing",
    name: "EvidenceLandingAssembly",
    layoutClass: "evidence-landing-layout",
    layoutSignals: [
      "ComparisonWorkbench",
      "EvidenceLedger",
      "grid-column: span 6",
    ],
  },
  {
    id: "record",
    name: "RecordAssembly",
    layoutClass: "record-layout",
    layoutSignals: [
      'data-authority-archetype="SEARCH_INDEX"',
      'data-authority-archetype="ENTITY_DETAIL"',
      "grid-column: span 9",
    ],
  },
  {
    id: "policy",
    name: "PolicyAssembly",
    layoutClass: "policy-layout",
    layoutSignals: ["LongFormArticle", "max-width: 72ch"],
  },
  {
    id: "guided-form",
    name: "GuidedFormAssembly",
    layoutClass: "guided-form-layout",
    layoutSignals: [
      'data-authority-archetype="AUTH_SYSTEM"',
      "GuidedFormSection",
      "max-width: 42rem",
    ],
  },
  {
    id: "queue",
    name: "QueueAssembly",
    layoutClass: "queue-layout",
    layoutSignals: ['[id="tasks"]', "DataCollection", "grid-column: span 8"],
  },
  {
    id: "workspace",
    name: "WorkspaceAssembly",
    layoutClass: "workspace-layout",
    layoutSignals: [
      "repeat(3, minmax(0, 1fr))",
      "ClaimWorkbench",
      "grid-column: span 2",
    ],
  },
  {
    id: "decision-review",
    name: "DecisionReviewAssembly",
    layoutClass: "decision-review-layout",
    layoutSignals: [
      "ComparisonWorkbench",
      "SignalTriagePanel",
      "grid-column: span 8",
    ],
  },
  {
    id: "operations",
    name: "OperationsAssembly",
    layoutClass: "operations-layout",
    layoutSignals: [
      "OperationsStatusPanel",
      ".section:first-child",
      "grid-column: span 6",
    ],
  },
] as const;

describe("closed screen archetype assemblies", () => {
  it("assigns all 95 authority screens and keeps the manifest mapping closed", () => {
    expect(catalogScreens).toHaveLength(95);
    expect(new Set(catalogScreens.map(({ id }) => id)).size).toBe(95);
    expect(catalogScreens).toContainEqual({
      id: "PUB-035",
      archetype: "GUIDED_FORM",
    });
    expect(manifestScreens).toEqual(catalogScreens);

    const archetypes = new Set(
      catalogScreens.map(({ archetype }) => archetype),
    );
    expect([...archetypes].sort()).toEqual([...SCREEN_ARCHETYPES].sort());
    expect(authorityArchetypes).toEqual(SCREEN_ARCHETYPES);
    expect(
      catalogScreens.every(
        ({ archetype }) => archetypeAssemblyFor(archetype).length > 0,
      ),
    ).toBe(true);
  });

  it("collapses ten authority archetypes into exactly eight explicit assemblies", () => {
    expect(ARCHETYPE_ASSEMBLIES).toEqual({
      EVIDENCE_LANDING: "evidence-landing",
      SEARCH_INDEX: "record",
      ENTITY_DETAIL: "record",
      POLICY: "policy",
      GUIDED_FORM: "guided-form",
      QUEUE: "queue",
      WORKSPACE: "workspace",
      DECISION_REVIEW: "decision-review",
      OPERATIONS: "operations",
      AUTH_SYSTEM: "guided-form",
    });
    expect(new Set(Object.values(ARCHETYPE_ASSEMBLIES))).toHaveLength(8);
    expect(new Set(Object.values(ARCHETYPE_ASSEMBLIES))).toEqual(
      new Set(ARCHETYPE_ASSEMBLY_IDS),
    );
  });

  it("fails closed instead of selecting a generic fallback", () => {
    expect(() => archetypeAssemblyFor("SEARCH")).toThrow(
      "unsupported screen archetype: SEARCH",
    );
    expect(() => archetypeAssemblyFor("")).toThrow(
      "unsupported screen archetype:",
    );
  });

  it("dispatches to eight concrete grid assemblies without a generic component fallback", () => {
    const centralAssembly = readFileSync(
      new URL(
        "./components/archetypes/ArchetypeAssembly.svelte",
        import.meta.url,
      ),
      "utf8",
    );
    const compiledLayoutCss = assemblyComponents.map(
      ({ id, name, layoutClass, layoutSignals }) => {
        const source = readFileSync(
          new URL(`./components/archetypes/${name}.svelte`, import.meta.url),
          "utf8",
        );
        const compiled = compile(source, {
          filename: `${name}.svelte`,
          generate: "server",
        });
        const css = compiled.css?.code ?? "";
        expect(centralAssembly).toContain(
          `import ${name} from "./${name}.svelte";`,
        );
        expect(source).toContain(`<SectionList`);
        expect(source).toContain(`data-archetype-assembly="${id}"`);
        expect(source).toContain("data-authority-archetype={screen.archetype}");
        expect(source).toContain(`data-component="${name}"`);
        expect(source).toContain(`class="${layoutClass}"`);
        expect(compiled.warnings).toEqual([]);
        expect(css).toContain("display: grid");
        expect(css).toContain("display: contents");
        expect(css.match(/grid-column:/gu)?.length ?? 0).toBeGreaterThanOrEqual(
          3,
        );
        for (const signal of layoutSignals) {
          expect(source).toContain(signal);
        }
        return css;
      },
    );
    expect(centralAssembly).toContain(
      "satisfies Record<\n  ReturnType<typeof archetypeAssemblyFor>",
    );
    expect(centralAssembly).not.toContain("<SectionList");
    expect(compiledLayoutCss.join("\n")).not.toMatch(
      /(?:display\s*:\s*flex|\border\s*:|grid-auto-flow\s*:|masonry|\bdense\b)/u,
    );
  });

  it("keeps the authored section sequence and shell handoff free of CSS reordering", () => {
    const sectionList = readFileSync(
      new URL("./components/screen/SectionList.svelte", import.meta.url),
      "utf8",
    );
    const shellSources = [
      "PublicShell",
      "ResponseShell",
      "AuthShell",
      "InternalShell",
    ].map((name) =>
      readFileSync(
        new URL(`./components/chrome/${name}.svelte`, import.meta.url),
        "utf8",
      ),
    );
    const contextRail = readFileSync(
      new URL(
        "./components/chrome/InternalContextRail.svelte",
        import.meta.url,
      ),
      "utf8",
    );
    expect(sectionList).toContain(
      "{#each contract.sections as typedSection, index (typedSection.id)}",
    );
    expect(sectionList).toContain(
      "{@const section = sourceSectionForId(screen, typedSection.id)}",
    );
    for (const shell of shellSources) {
      expect(shell).toContain("<ArchetypeAssembly");
      expect(shell).not.toContain("<SectionList");
    }
    expect(
      `${sectionList}\n${shellSources.join("\n")}\n${contextRail}`,
    ).not.toMatch(/(?:\border\s*:|grid-auto-flow\s*:|masonry|\bdense\b)/u);
  });

  it("retains surface exceptions and the INT-002 queue-to-workspace handoff", () => {
    const publicShell = readFileSync(
      new URL("./components/chrome/PublicShell.svelte", import.meta.url),
      "utf8",
    );
    const responseShell = readFileSync(
      new URL("./components/chrome/ResponseShell.svelte", import.meta.url),
      "utf8",
    );
    const authShell = readFileSync(
      new URL("./components/chrome/AuthShell.svelte", import.meta.url),
      "utf8",
    );
    const internalShell = readFileSync(
      new URL("./components/chrome/InternalShell.svelte", import.meta.url),
      "utf8",
    );
    const screenChrome = readFileSync(
      new URL("./screen-chrome.ts", import.meta.url),
      "utf8",
    );
    expect(catalogScreens.find(({ id }) => id === "INT-002")?.archetype).toBe(
      "QUEUE",
    );
    expect(archetypeAssemblyFor("QUEUE")).toBe("queue");
    expect(screenChrome).toContain('screen.id === "INT-002"');
    expect(internalShell).toContain('<ArchetypeAssembly variant="workspace"');
    expect(responseShell).toContain('<ArchetypeAssembly variant="form"');
    expect(authShell).toContain('<ArchetypeAssembly variant="form"');
    expect(
      publicShell.indexOf("evidenceLanding && statusSectionId"),
    ).toBeLessThan(publicShell.indexOf("<ScreenHeading"));
    expect(publicShell).toContain("skipStatus={evidenceLanding}");
  });
});

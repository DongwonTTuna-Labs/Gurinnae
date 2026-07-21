import { ROUTE_SCREEN_CONTRACTS } from "./generated-screen-contracts";
import { journeyForScreenId } from "./generated-screen-journeys";
import type { ScreenProjectionBinding } from "./generated-screen-projections";
import { SCREEN_PROJECTION_BINDINGS } from "./generated-screen-projections";
import type {
  JourneyId,
  ScreenRuntime,
  ScreenRuntimeProjection,
  ScreenViewModel,
  SemanticRegion,
} from "./index";
import {
  normalizeRegion,
  restoreAction,
  valueAtPath,
} from "./screen-projection-helpers";
import { specializedFields } from "./screen-projection-specialized";
import type { AnalysisProjection } from "./screen-projection-specialized-types";
import {
  labelFor,
  safeProjectionValue,
  sensitiveName,
} from "./screen-projection-values";

/** Values that are safe to put in browser text, links or accessible names. */
export type SafeProjectionValue = string | number | boolean;

export type ProjectionField = {
  name: string;
  label: string;
  value: SafeProjectionValue | null;
  known: boolean;
  source: string;
};

export type ProjectionSectionState =
  | "LOADING"
  | "READY"
  | "EMPTY"
  | "PARTIAL"
  | "STALE"
  | "ERROR"
  | "BLOCKED"
  | "UNKNOWN";

export type ScreenSectionProjection = {
  screenId: string;
  sectionId: string;
  region: SemanticRegion;
  component: string;
  fields: readonly ProjectionField[];
  state: ProjectionSectionState;
  errorMessage: string | null;
  focusTarget: string;
  /** Optional closed CAS visualization/graph payload for dedicated accessible renderers. */
  analysis?: AnalysisProjection;
};

export type ScreenProjection = {
  screenId: string;
  route: string;
  journey: JourneyId;
  state: ProjectionSectionState;
  sections: Readonly<Record<string, ScreenSectionProjection>>;
  focus: {
    heading: string;
    main: string;
    errorSummary: string;
    stateLive: string;
    entrySection: string;
    restoreAction: string | null;
  };
  responsive: {
    compact: "COMPACT_SINGLE_COLUMN";
    medium: "MEDIUM_REFLOW";
    wide: "WIDE_AUTHORITY_LAYOUT";
    pageHorizontalOverflow: "FORBIDDEN";
  };
};

type RouteContract =
  (typeof ROUTE_SCREEN_CONTRACTS)[keyof typeof ROUTE_SCREEN_CONTRACTS];

/**
 * This is the closed browser projection registry.  Its keys are derived from
 * the generated 94-screen authority registry and are checked at runtime as
 * well as compile time; a new screen cannot silently fall through a generic
 * page mapper.
 */
export const SCREEN_PROJECTION_REGISTRY: Readonly<
  Record<string, RouteContract>
> = Object.freeze(ROUTE_SCREEN_CONTRACTS);

function stateFor(
  runtime: ScreenRuntime,
  blocked = false,
): ProjectionSectionState {
  if (blocked) return "BLOCKED";
  if (
    runtime.state === "loading" ||
    runtime.state === "initial-loading" ||
    runtime.state === "refreshing"
  )
    return "LOADING";
  if (
    runtime.state === "success" ||
    runtime.state === "saved" ||
    runtime.state === "current" ||
    runtime.state === "draft" ||
    runtime.state === "healthy" ||
    runtime.state === "ready" ||
    runtime.state === "receipt"
  )
    return "READY";
  if (
    runtime.state === "empty" ||
    runtime.state === "filtered-empty" ||
    runtime.state === "not-found"
  )
    return "EMPTY";
  if (
    runtime.state === "partial" ||
    runtime.state === "partial-failure" ||
    runtime.state === "degraded"
  )
    return "PARTIAL";
  if (runtime.state === "stale" || runtime.state === "telemetry-gap")
    return "STALE";
  if (
    runtime.state === "error" ||
    runtime.state === "server-error" ||
    runtime.state === "incident"
  )
    return "ERROR";
  if (
    runtime.state === "conflict" ||
    runtime.state === "blocked" ||
    runtime.state === "validation-error" ||
    runtime.state === "invalid-filter" ||
    runtime.state === "maintenance" ||
    runtime.state === "forbidden" ||
    runtime.state === "unauthorized" ||
    runtime.state === "unauthenticated" ||
    runtime.state === "reauth-required" ||
    runtime.state === "offline" ||
    runtime.state === "session-expiring" ||
    runtime.state === "session-expired"
  )
    return "BLOCKED";
  if (runtime.state === "saving" || runtime.state === "submitting")
    return "LOADING";
  if (runtime.state === "terminal" || runtime.state === "superseded")
    return "STALE";
  return "UNKNOWN";
}

/**
 * A successful HTTP response is not the same thing as a usable projection.
 * Keep missing/partial field sets visible to the user instead of allowing the
 * transport state to make an empty generic renderer look ready.
 */
function sectionStateFor(
  runtime: ScreenRuntime,
  blocked: boolean,
  fields: readonly ProjectionField[],
): ProjectionSectionState {
  const transport = stateFor(runtime, blocked);
  if (transport !== "READY") return transport;
  if (fields.length === 0) return "UNKNOWN";
  const known = fields.filter((field) => field.known).length;
  // The contract is present but no allowlisted value was resolved.  This is
  // distinct from an authority-confirmed empty result and must stay visible.
  if (known === 0) return "UNKNOWN";
  if (known < fields.length) return "PARTIAL";
  return "READY";
}

function screenStateFor(
  runtime: ScreenRuntime,
  sections: readonly ScreenSectionProjection[],
): ProjectionSectionState {
  const transport = stateFor(runtime);
  if (transport !== "READY") return transport;
  if (sections.length === 0) return "UNKNOWN";
  const ready = sections.filter((section) => section.state === "READY").length;
  const empty = sections.filter((section) => section.state === "EMPTY").length;
  const unknown = sections.filter(
    (section) => section.state === "UNKNOWN",
  ).length;
  if (ready === sections.length) return "READY";
  // An absent typed envelope is UNKNOWN, never an authority-confirmed empty
  // result. EMPTY is reserved for a successful query that explicitly carried
  // an empty result state.
  if (ready === 0 && empty === sections.length) return "EMPTY";
  if (ready === 0 && unknown === sections.length) return "UNKNOWN";
  return "PARTIAL";
}

/**
 * Resolve a section only from the server-owned allowlist envelope.
 *
 * The previous implementation searched every blocking operation DTO and
 * guessed camel/snake-case field names.  That made a successful transport
 * response look like a typed view-model and could expose operation ids in the
 * browser.  A missing envelope is deliberately represented as UNKNOWN with a
 * stable authority source, not inferred from raw runtime JSON.
 */
function envelopeFields(
  screenId: string,
  sectionId: string,
  fieldNames: readonly string[],
  projection: ScreenRuntimeProjection | undefined,
): {
  fields: ProjectionField[];
  blocked: boolean;
  analysis?: import("./screen-projection-specialized-types").AnalysisProjection;
} {
  const section =
    projection?.screenId === screenId
      ? projection.sections[sectionId]
      : undefined;
  const fields = fieldNames.map((name) => {
    const value = section?.fields[name];
    if (sensitiveName.test(name)) {
      return {
        name,
        label: labelFor(name),
        value: null,
        known: false,
        source: "redacted",
      } satisfies ProjectionField;
    }
    return {
      name,
      label: labelFor(name),
      value: value?.value ?? null,
      known: value?.known === true && value.value !== null,
      source: value?.source ?? `authority:${screenId}.${sectionId}.${name}`,
    } satisfies ProjectionField;
  });
  return {
    fields,
    blocked: section?.blocked === true,
    ...(section?.analysis ? { analysis: section.analysis } : {}),
  };
}

/**
 * Build the initial server-to-browser projection envelope.  BFF route
 * adapters can replace individual values with their closed typed projections;
 * every field is present from the start so an absent adapter fails closed.
 */
export function emptyScreenProjection(
  screen: ScreenViewModel,
): ScreenRuntimeProjection {
  const contract = SCREEN_PROJECTION_REGISTRY[screen.id];
  if (!contract)
    throw new Error(`screen projection contract missing: ${screen.id}`);
  return {
    screenId: screen.id,
    contractVersion: "AUTHORITY_V1",
    sections: Object.fromEntries(
      contract.sections.map((section) => [
        section.id,
        {
          blocked: false,
          fields: Object.fromEntries(
            section.fields.map((name) => [
              name,
              {
                value: null,
                known: false,
                source: `authority:${screen.id}.${section.id}.${name}`,
              },
            ]),
          ),
        },
      ]),
    ),
  };
}
/**
 * Materialize the generated, operation-bound allowlist after server fetches.
 * The resolver follows only the exact field path authored in the authority
 * overlay; it never scans a DTO or guesses alternate key spellings.
 */
export function projectFetchedData(
  screen: ScreenViewModel,
  data: Readonly<Record<string, unknown>>,
): ScreenRuntimeProjection {
  const projection = emptyScreenProjection(screen);
  const bindings: Record<string, ScreenProjectionBinding> | undefined =
    SCREEN_PROJECTION_BINDINGS[
      screen.id as keyof typeof SCREEN_PROJECTION_BINDINGS
    ] as Record<string, ScreenProjectionBinding> | undefined;
  if (!bindings) return projection;
  const sections: Record<
    string,
    {
      blocked: boolean;
      fields: Record<
        string,
        { value: SafeProjectionValue | null; known: boolean; source: string }
      >;
      analysis?: import("./screen-projection-specialized-types").AnalysisProjection;
    }
  > = {};
  for (const [_fieldName, binding] of Object.entries(bindings)) {
    const operationValue = data[binding.operationId];
    const raw = valueAtPath(operationValue, binding.path);
    const value = safeProjectionValue(raw);
    const existing = sections[binding.sectionId] ?? {
      blocked: false,
      fields: {},
    };
    existing.fields[binding.fieldName] = {
      value,
      known: value !== null,
      source: `${binding.operationId}.${binding.path}`,
    };
    sections[binding.sectionId] = existing;
  }
  // CAS responses may publish a reduced analysisVm, while the closed v13
  // transport DTO remains valid on its own. Materialize whichever typed
  // projection is available into the same runtime envelope.
  for (const section of screen.sections) {
    const specialized = specializedFields(screen.id, section.id, data);
    if (!specialized) continue;
    const existing = sections[section.id] ?? { blocked: false, fields: {} };
    for (const projectedField of specialized.fields) {
      // Specialized mappers are themselves closed, authority-derived
      // projections. Merge every field they explicitly emit (including
      // response journeys and CAS visualizations) while never exposing the
      // underlying DTO to the browser.
      existing.fields[projectedField.name] = projectedField;
    }
    if (specialized.analysis) existing.analysis = specialized.analysis;
    sections[section.id] = existing;
  }
  return {
    ...projection,
    sections: Object.fromEntries(
      Object.entries(projection.sections).map(([sectionId, section]) => [
        sectionId,
        {
          blocked: sections[sectionId]?.blocked ?? section.blocked,
          ...(sections[sectionId]?.analysis
            ? { analysis: sections[sectionId].analysis }
            : {}),
          fields: Object.fromEntries(
            Object.entries(section.fields).map(([fieldName, field]) => [
              fieldName,
              sections[sectionId]?.fields[fieldName] ?? field,
            ]),
          ),
        },
      ]),
    ),
  };
}

/** Create the complete typed browser projection for one screen. */
export function projectScreen(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
): ScreenProjection {
  const contract = SCREEN_PROJECTION_REGISTRY[screen.id];
  if (!contract)
    throw new Error(`screen projection contract missing: ${screen.id}`);
  const journey = journeyForScreenId(screen.id);
  const sections = Object.fromEntries(
    contract.sections.map((section) => {
      // Specialized view-models are defined over the server-owned operation
      // data map.  Passing the full ScreenRuntime object silently made every
      // mapper see an empty payload (and therefore rendered UNKNOWN/EMPTY on
      // the response, approval, and commercial-health journeys).
      // The server-owned envelope is authoritative whenever present.  A
      // browser-side specialized mapper is only a compatibility path for
      // legacy fixture loads where the server could not emit a projection;
      // it must never override a typed, allowlisted response with raw DTOs.
      const serverEnvelope = envelopeFields(
        screen.id,
        section.id,
        [
          ...new Set([
            ...section.fields,
            ...Object.keys(runtime.projection?.sections[section.id]?.fields ?? {}),
          ]),
        ],
        runtime.projection,
      );
      // The browser must render only the server-owned allowlist. A missing or
      // empty projection is an explicit UNKNOWN state, never an invitation to
      // inspect raw operation DTOs or guess alternate field paths.
      const projectedEnvelope = serverEnvelope;
      const fields = projectedEnvelope.fields;
      const state = sectionStateFor(runtime, projectedEnvelope.blocked, fields);
      const projected: ScreenSectionProjection = {
        screenId: screen.id,
        sectionId: section.id,
        region: normalizeRegion(section.region),
        component: section.component,
        fields,
        state,
        errorMessage:
          state === "ERROR" || state === "BLOCKED"
            ? (runtime.errors[0] ?? "확인이 필요합니다.")
            : null,
        focusTarget: section.testId,
        ...(projectedEnvelope.analysis
          ? { analysis: projectedEnvelope.analysis }
          : {}),
      };
      return [section.id, projected] as const;
    }),
  );
  const projectedSections = Object.values(sections);
  const state = screenStateFor(runtime, projectedSections);
  const id = screen.id.toLowerCase();
  return {
    screenId: screen.id,
    route: contract.route,
    journey,
    state,
    sections,
    focus: {
      heading: `${id}__heading`,
      main: `${id}__main`,
      errorSummary: `${id}__error_summary`,
      stateLive: `${id}__state_live`,
      entrySection: contract.sections[0]?.testId ?? `${id}__main`,
      restoreAction: restoreAction(screen),
    },
    responsive: {
      compact: "COMPACT_SINGLE_COLUMN",
      medium: "MEDIUM_REFLOW",
      wide: "WIDE_AUTHORITY_LAYOUT",
      pageHorizontalOverflow: "FORBIDDEN",
    },
  };
}

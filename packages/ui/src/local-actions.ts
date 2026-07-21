import type { ScreenRuntime, ScreenViewModel } from "./index";

type ScreenAction = ScreenViewModel["actions"][number];

const staticTargets: Record<string, string> = {
  "PUB-001:search": "/search",
  "PUB-001:browse-cases": "/cases",
  "PUB-003:open-case": "/cases",
  "PUB-004:request-correction": "/correction-request",
  "PUB-013:view-coverage": "/coverage",
  "PUB-020:view-schema": "/api",
  "PUB-020:open-api-docs": "/api",
  "PUB-021:view-data-policy": "/data",
  "PUB-022:view-governance": "/about/governance",
  "PUB-022:contact": "/contact",
  "PUB-023:view-governance": "/about/governance",
  "PUB-024:view-editorial-policy": "/editorial-policy",
  "PUB-024:request-correction": "/correction-request",
  "PUB-025:request-correction": "/correction-request",
  "PUB-025:view-history": "/editorial-policy#history",
  "PUB-026:open-correction": "/correction-request",
  "PUB-026:security-report": "/contact#security",
  "PUB-028:manage-request": "/correction-request/receipt#manage",
  "PUB-031:privacy-contact": "/contact?topic=privacy",
  "PUB-031:view-history": "/privacy#history",
  "PUB-032:view-data": "/data",
  "PUB-032:contact": "/contact",
  "PUB-033:report-accessibility": "/contact?topic=accessibility",
  "PUB-033:request-alternative": "/contact?topic=alternative-format",
  "PUB-034:go-home": "/",
  "PUB-034:view-status": "#impact",
  "RSP-001:continue": "/respond/overview",
  "RSP-001:report-problem": "/respond/unavailable",
  "RSP-002:start-answer": "/respond/answer",
  "RSP-002:request-extension": "/respond/extension",
  "RSP-003:next": "/respond/attachments",
  "RSP-004:next": "/respond/review",
  "RSP-005:change-answer": "/respond/answer",
  "RSP-005:change-files": "/respond/attachments",
  "RSP-006:submit-supplement": "/respond/unavailable#supplement",
  "RSP-007:return": "/respond/overview",
  "RSP-008:request-new-link": "/respond/unavailable#new-link",
  "RSP-008:contact-owner": "/respond/unavailable#contact",
  "AUTH-002:cancel": "/internal/my-work",
  "AUTH-003:request-access": "/auth/access-denied#request",
  "AUTH-003:go-my-work": "/internal/my-work",
  "INT-004:manage": "#preferences",
  "REV-003:cancel": "/internal/review",
  "SRC-002:view-runs": "runs",
  "RULE-001:propose-version": "/internal/rules#new-version",
  "OPS-001:open-jobs": "/internal/operations/jobs",
  "OPS-001:open-kill": "/internal/operations/kill-switches",
  "OPS-004:open-provider": "/internal/operations/providers",
};

const fallbackTargets: Record<string, string> = {
  "INT-001:open-incident": "#incidents",
  "CAS-008:open-submission": "#submissions",
  "CAS-012:open-event": "#timeline",
  "CAS-013:open-blocker": "#tasks",
  "CAS-016:open-event": "#events",
  "SRC-004:open-quarantine": "#errors",
  "OPS-001:open-incident": "#incidents",
  "AUD-001:open-event": "#events",
};

export function localActionHref(
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
  action: ScreenAction,
): string | undefined {
  const explicit = [action.href, action.destination, action.target].find(
    (value): value is string => typeof value === "string" && value.length > 0,
  );
  if (explicit)
    return safeHref(renderRoute(explicit, runtime.pathname ?? screen.route));

  const serverDestination = runtime.destinations?.[action.id];
  if (serverDestination) return safeHref(serverDestination);

  const key = `${screen.id}:${action.id}`;
  const contextual = contextualTarget(key, screen, runtime);
  if (contextual) return contextual;

  const configured = staticTargets[key];
  if (configured)
    return safeHref(
      resolveRelative(configured, runtime.pathname ?? screen.route),
    );

  return fallbackTargets[key];
}

function contextualTarget(
  key: string,
  screen: ScreenViewModel,
  runtime: ScreenRuntime,
): string | undefined {
  const path = runtime.pathname ?? screen.route;
  switch (key) {
    case "PUB-005:view-latest":
      return path.split("/revisions/")[0];
    case "PUB-005:compare":
      return "#diff";
    case "PUB-006:view-rule":
      return "/methodology";
    case "PUB-014:view-related-cases": {
      const rule = lastSegment(path);
      return `/cases?ruleId=${encodeURIComponent(rule)}`;
    }
    case "PUB-017:view-related-rules":
      return "/methodology";
    case "PUB-019:view-old-revision":
    case "REV-003:open-public":
      return undefined;
    case "CAS-002:start-next":
      return path.replace(/\/overview\/?$/, "/signals");
    case "CAS-008:new-request":
      return path.replace(/\/responses\/?$/, "/responses/new");
    case "CAS-014:open-review":
      return path.replace(/\/preview\/?$/, "/review");
    case "RULE-002:open-evaluation":
      return `${trimSlash(path)}/evaluation`;
    case "SRC-002:view-runs":
      return `${trimSlash(path)}/runs`;
    case "SRC-002:view-drift":
      return `${trimSlash(path)}/schema-drift`;
    default:
      return undefined;
  }
}

function safeHref(value: string): string | undefined {
  if (
    (value.startsWith("/") && !value.startsWith("//")) ||
    value.startsWith("#")
  )
    return value;
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:"
      ? value
      : undefined;
  } catch {
    return undefined;
  }
}

function resolveRelative(value: string, pathname: string): string {
  if (value.startsWith("/") || value.startsWith("#")) return value;
  return `${trimSlash(pathname)}/${value.replace(/^\/+/, "")}`;
}

function renderRoute(value: string, pathname: string): string {
  const patternSegments = value.split("/");
  const pathSegments = pathname.split("/");
  const params = new Map<string, string>();
  patternSegments.forEach((segment, index) => {
    const match = segment.match(/^\{([^}]+)\}$/);
    const pathSegment = pathSegments[index];
    if (match?.[1] && pathSegment) params.set(match[1], pathSegment);
  });
  return value.replaceAll(
    /\{([^}]+)\}/g,
    (_, name: string) => params.get(name) ?? "",
  );
}

function trimSlash(value: string): string {
  return value === "/" ? "" : value.replace(/\/$/, "");
}

function lastSegment(value: string): string {
  return value.split("/").filter(Boolean).at(-1) ?? "";
}

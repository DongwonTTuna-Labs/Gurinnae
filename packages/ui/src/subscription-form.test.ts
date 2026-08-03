import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { ScreenField, ScreenRuntime, ScreenViewModel } from "./index";
import {
  namedFormAction,
  needsScopeRef,
  publicSubscriptionForm,
  SUBSCRIPTION_FREQUENCY_LABELS,
  SUBSCRIPTION_SCOPE_LABELS,
  scopeReferenceLabel,
  scopeReferencePattern,
} from "./subscription-form";

const screen = {
  id: "PUB-029",
  title: "업데이트 구독",
  route: "/subscribe",
  archetype: "GUIDED_FORM",
  sections: [],
  actions: [
    {
      id: "request-verification",
      label: "검증 이메일 보내기",
      operation_id: "createSubscription",
    },
  ],
  states: [],
  dataOperations: [],
} satisfies ScreenViewModel;

const scopeOptions = Object.keys(SUBSCRIPTION_SCOPE_LABELS);
const frequencyOptions = Object.keys(SUBSCRIPTION_FREQUENCY_LABELS);

const fields = (): ScreenField[] => [
  {
    name: "email",
    label: "email",
    type: "text",
    required: true,
  },
  {
    name: "scopeType",
    label: "scope type",
    type: "text",
    required: true,
    options: scopeOptions,
  },
  {
    name: "scopeRef",
    label: "scope ref",
    type: "text",
    required: false,
  },
  {
    name: "query",
    label: "query",
    type: "json",
    required: false,
  },
  {
    name: "frequency",
    label: "frequency",
    type: "text",
    required: true,
    options: frequencyOptions,
  },
  {
    name: "locale",
    label: "locale",
    type: "text",
    required: true,
    readonly: true,
    value: "ko-KR",
  },
  {
    name: "consent",
    label: "consent",
    type: "boolean",
    required: true,
    value: false,
  },
  {
    name: "abuseProof",
    label: "abuse proof",
    type: "json",
    required: true,
    challengeAction: "createSubscription",
  },
];

function runtime(formFields = fields()): ScreenRuntime {
  return {
    state: "success",
    data: {},
    errors: [],
    forms: { "request-verification": formFields },
    idempotencyKeys: { "request-verification": "subscription-key-001" },
    search: "?/old-action&scopeType=CASE&notice=ready",
  };
}

describe("public subscription form", () => {
  it("keeps standalone scope selection open without inventing a default", () => {
    const result = publicSubscriptionForm(screen, runtime());

    expect(result.ready).toBe(true);
    if (!result.ready) return;
    expect(result.model.fixedScopeType).toBeUndefined();
    expect(result.model.scopeType.value).toBeUndefined();
    expect(result.model.scopeType.options).toEqual(scopeOptions);
    expect(result.model.fixedFields.map((field) => field.name)).toEqual([
      "locale",
    ]);
    expect(result.model.formAction).toBe(
      "?/request-verification&scopeType=CASE&notice=ready",
    );
  });

  it("fails closed when the server omits the idempotency boundary", () => {
    expect(
      publicSubscriptionForm(screen, {
        ...runtime(),
        idempotencyKeys: {},
      }),
    ).toEqual({
      ready: false,
      reason: "구독 제출 멱등성 계약을 확인할 수 없습니다.",
    });
  });

  it("preserves a server-owned case context as hidden fixed fields", () => {
    const presetFields = fields().map((field) => {
      if (field.name === "scopeType")
        return { ...field, readonly: true, value: "CASE" };
      if (field.name === "scopeRef")
        return { ...field, readonly: true, value: "case-safe-001" };
      return field;
    });

    const result = publicSubscriptionForm(screen, runtime(presetFields));

    expect(result.ready).toBe(true);
    if (!result.ready) return;
    expect(result.model.fixedScopeType).toBe("CASE");
    expect(result.model.fixedFields.map((field) => field.name)).toEqual([
      "scopeType",
      "scopeRef",
      "locale",
    ]);
  });

  it("accepts QUERY only when a server-owned query snapshot is fixed", () => {
    const presetFields = fields().map((field) => {
      if (field.name === "scopeType")
        return { ...field, readonly: true, value: "QUERY" };
      if (field.name === "query")
        return {
          ...field,
          readonly: true,
          value: JSON.stringify({
            route: "/cases",
            filters: [],
            sort: "updated_desc",
          }),
        };
      return field;
    });

    const result = publicSubscriptionForm(screen, runtime(presetFields));

    expect(result.ready).toBe(true);
    if (!result.ready) return;
    expect(result.model.fixedScopeType).toBe("QUERY");
    expect(result.model.fixedFields.map((field) => field.name)).toEqual([
      "scopeType",
      "query",
      "locale",
    ]);
  });

  it("accepts only a five-digit server-owned REGION reference", () => {
    const regionFields = (scopeRef: string) =>
      fields().map((field) => {
        if (field.name === "scopeType")
          return { ...field, readonly: true, value: "REGION" };
        if (field.name === "scopeRef")
          return { ...field, readonly: true, value: scopeRef };
        return field;
      });

    const accepted = publicSubscriptionForm(
      screen,
      runtime(regionFields("11680")),
    );
    expect(accepted.ready).toBe(true);
    if (accepted.ready) expect(accepted.model.fixedScopeType).toBe("REGION");
    expect(
      publicSubscriptionForm(screen, runtime(regionFields("1168A"))),
    ).toEqual({
      ready: false,
      reason: "지역 구독 시군구 코드가 올바르지 않습니다.",
    });
  });

  it.each([
    {
      name: "missing locale preset",
      change: (items: ScreenField[]) =>
        items.map((field): ScreenField => {
          if (field.name !== "locale") return field;
          const { value: _value, ...withoutValue } = field;
          return { ...withoutValue, readonly: false };
        }),
      reason: "서버가 확정한 언어·지역 설정이 없습니다.",
    },
    {
      name: "prechecked consent",
      change: (items: ScreenField[]) =>
        items.map((field) =>
          field.name === "consent" ? { ...field, value: true } : field,
        ),
      reason: "구독 동의는 미리 선택할 수 없습니다.",
    },
    {
      name: "missing case reference",
      change: (items: ScreenField[]) =>
        items.map((field) =>
          field.name === "scopeType"
            ? { ...field, readonly: true, value: "CASE" }
            : field,
        ),
      reason: "구독 문맥 식별자가 없습니다.",
    },
    {
      name: "unmapped frequency",
      change: (items: ScreenField[]) =>
        items.map((field) =>
          field.name === "frequency"
            ? { ...field, options: [...frequencyOptions, "MONTHLY"] }
            : field,
        ),
      reason: "구독 빈도 선택지가 폐쇄형 라벨 계약과 일치하지 않습니다.",
    },
    {
      name: "proof bound to another operation",
      change: (items: ScreenField[]) =>
        items.map((field) =>
          field.name === "abuseProof"
            ? { ...field, challengeAction: "createCorrectionRequest" }
            : field,
        ),
      reason: "자동 제출 방지 증빙은 현재 구독 요청에 결속되어야 합니다.",
    },
  ])("fails closed for $name", ({ change, reason }) => {
    expect(publicSubscriptionForm(screen, runtime(change(fields())))).toEqual({
      ready: false,
      reason,
    });
  });

  it("keeps named action transport metadata first and removes stale actions", () => {
    expect(
      namedFormAction(
        "request-verification",
        "?%2Fold-action&/other-action&q=공개&frequency=DAILY",
      ),
    ).toBe("?/request-verification&q=공개&frequency=DAILY");
  });

  it("uses context-specific Korean labels for editable scope references", () => {
    expect(scopeReferenceLabel("CASE")).toBe("사건 식별자");
    expect(scopeReferenceLabel("AGENCY")).toBe("기관 식별자");
    expect(scopeReferenceLabel("SUPPLIER")).toBe("업체 식별자");
    expect(scopeReferenceLabel("REGION")).toBe("시군구 코드");
    expect(needsScopeRef("REGION")).toBe(true);
    expect(scopeReferencePattern("REGION")).toBe("[0-9]{5}");
  });

  it("does not expose an arbitrary JSON editor or precheck consent", () => {
    const source = readFileSync(
      new URL(
        "./components/sections/PublicSubscriptionForm.svelte",
        import.meta.url,
      ),
      "utf8",
    );
    expect(source).not.toContain("<textarea");
    expect(source).not.toMatch(/checked(?:=|\s)/);
    expect(source).toContain("검색 조건 구독은 검색 결과 화면");
    expect(source).toContain("<BotChallenge");
    expect(source).toContain("name={field.name}");
    expect(source).toContain(
      'data-testid="pub_029__action__request_verification"',
    );
    expect(source.match(/data-action-id=\{model\.actionId\}/g)).toHaveLength(1);
    expect(source).toMatch(
      /<button[^>]*type="submit"[^>]*data-action-id=\{model\.actionId\}[^>]*>/,
    );
  });
});

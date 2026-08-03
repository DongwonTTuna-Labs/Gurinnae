import { operationFields, type RuntimeField } from "@gurine/config";
import { humanFieldLabel } from "@gurine/ui";
import { describe, expect, it } from "vitest";
import {
  decorateRelayModelFields,
  FIRST_RELAY_DATA_POLICY_CAPTION,
  relayModelActionPreset,
  relayModelFormCaption,
  relayModelFormContext,
} from "./relay-model-form";
import { operations } from "./screen-contract";

const fields: RuntimeField[] = [
  {
    name: "providerId",
    label: "provider Id",
    type: "text",
    required: true,
  },
  {
    name: "expectedVersion",
    label: "expected Version",
    type: "number",
    required: true,
  },
  { name: "modelId", label: "model Id", type: "text", required: true },
  { name: "track", label: "track", type: "text", required: false },
];

const catalog = {
  listRelayModels: {
    items: [
      { modelId: "relay-model-new", track: "relay-", active: true },
      { modelId: "relay-model-old", track: "relay-", active: false },
    ],
    currentProviders: [
      {
        providerId: "provider-relay",
        currentModel: "relay-model-new",
        enabled: false,
        version: 7,
        autoUpgrade: false,
        track: "relay-",
        dataPolicyState: "UNCONFIGURED",
      },
    ],
  },
};

describe("relay model form context", () => {
  it("renders the exact first-activation policy controls from OpenAPI", () => {
    const operation = operations.get("upgradeProviderModel");
    if (!operation) throw new Error("upgradeProviderModel contract is missing");
    const decorated = decorateRelayModelFields(
      "upgradeProviderModel",
      operationFields(operation, {}, {}, ["dataPolicy"]),
      catalog,
    );
    const policyFields = decorated.filter(
      (field) => field.payloadPath?.[0] === "dataPolicy",
    );
    expect(
      policyFields.map((field) => ({
        name: field.name,
        label: humanFieldLabel(field.name),
        type: field.type,
        required: field.required,
        options: field.options,
      })),
    ).toEqual([
      {
        name: "processingRegion",
        label: "처리 지역",
        type: "text",
        required: true,
        options: undefined,
      },
      {
        name: "retentionMode",
        label: "보존 방식",
        type: "text",
        required: true,
        options: ["ZERO_RETENTION", "BOUNDED_PROVIDER_RETENTION", "LOCAL_ONLY"],
      },
      {
        name: "policyVersion",
        label: "정책 버전",
        type: "text",
        required: true,
        options: undefined,
      },
    ]);
    expect(relayModelFormCaption("upgradeProviderModel", decorated)).toBe(
      FIRST_RELAY_DATA_POLICY_CAPTION,
    );
    expect(FIRST_RELAY_DATA_POLICY_CAPTION).toBe("첫 활성화 데이터 정책");
  });

  it("binds the sole current provider and offers only active catalog models", () => {
    expect(relayModelFormContext(catalog)).toEqual({
      preset: { providerId: "provider-relay", expectedVersion: 7 },
      authority: {
        providerId: "provider-relay",
        expectedVersion: 7,
        currentModel: "relay-model-new",
        enabled: false,
        autoUpgrade: false,
        track: "relay-",
        dataPolicyState: "UNCONFIGURED",
      },
      activeModelIds: ["relay-model-new"],
      requiresDataPolicy: true,
      suggestedTrack: "relay-",
    });
    expect(relayModelActionPreset("upgradeProviderModel", catalog)).toEqual({
      providerId: "provider-relay",
      expectedVersion: 7,
    });
    expect(
      decorateRelayModelFields("upgradeProviderModel", fields, catalog).find(
        (field) => field.name === "modelId",
      )?.options,
    ).toEqual(["relay-model-new"]);
  });

  it("requires all policy leaves only for first activation", () => {
    const policyFields: RuntimeField[] = [
      {
        name: "processingRegion",
        label: "processing Region",
        type: "text",
        required: false,
        payloadPath: ["dataPolicy", "processingRegion"],
      },
      {
        name: "retentionMode",
        label: "retention Mode",
        type: "text",
        required: false,
        payloadPath: ["dataPolicy", "retentionMode"],
      },
      {
        name: "policyVersion",
        label: "policy Version",
        type: "text",
        required: false,
        payloadPath: ["dataPolicy", "policyVersion"],
      },
    ];
    expect(
      decorateRelayModelFields(
        "upgradeProviderModel",
        policyFields,
        catalog,
      ).map((field) => field.required),
    ).toEqual([true, true, true]);

    const configured = structuredClone(catalog);
    const configuredProvider = configured.listRelayModels.currentProviders[0];
    if (!configuredProvider) throw new Error("provider fixture is missing");
    configuredProvider.dataPolicyState = "CONFIGURED";
    expect(
      decorateRelayModelFields(
        "upgradeProviderModel",
        policyFields,
        configured,
      ).map((field) => field.required),
    ).toEqual([false, false, false]);
  });

  it("suggests the current catalog track while leaving it editable", () => {
    const decorated = decorateRelayModelFields(
      "setModelAutoUpgrade",
      fields,
      catalog,
    );
    expect(decorated.find((field) => field.name === "track")).toMatchObject({
      value: "relay-",
      readonly: false,
    });
  });

  it("falls back to the current model catalog row when provider track is absent", () => {
    const currentProvider = catalog.listRelayModels.currentProviders[0];
    if (!currentProvider) throw new Error("provider fixture is missing");
    const { track: _track, ...providerWithoutTrack } = currentProvider;
    const withoutProviderTrack = {
      listRelayModels: {
        ...catalog.listRelayModels,
        currentProviders: [providerWithoutTrack],
      },
    };
    expect(relayModelFormContext(withoutProviderTrack)?.suggestedTrack).toBe(
      "relay-",
    );
  });

  it("fails closed when the provider is missing or ambiguous", () => {
    for (const currentProviders of [
      [],
      [
        ...catalog.listRelayModels.currentProviders,
        {
          providerId: "provider-relay-2",
          currentModel: null,
          enabled: false,
          version: 1,
          autoUpgrade: false,
          track: null,
          dataPolicyState: "UNCONFIGURED",
        },
      ],
    ]) {
      const data = {
        listRelayModels: {
          ...catalog.listRelayModels,
          currentProviders,
        },
      };
      expect(relayModelFormContext(data)).toBeUndefined();
      const decorated = decorateRelayModelFields(
        "upgradeProviderModel",
        fields,
        data,
      );
      expect(
        decorated.find((field) => field.name === "providerId")?.readonly,
      ).toBe(true);
      expect(
        decorated.find((field) => field.name === "modelId")?.options,
      ).toEqual([]);
    }
  });
});

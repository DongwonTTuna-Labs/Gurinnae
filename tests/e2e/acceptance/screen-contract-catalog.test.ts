import { describe, expect, it } from "bun:test";
import {
  addendumOperationContractsFrom,
  apiOperations,
  composeApiOperations,
  objectValue,
  operationContracts,
  privateBillingApiOperationsFrom,
  screenDataContracts,
  yamlObject,
} from "./screen-contract-catalog";

const PRIVATE_BILLING_OPERATION_IDS = [
  "private.GetDonationFixtureOffer",
  "private.QueueDonationIntent",
  "private.ReceivePaymentWebhook",
] as const;

describe("screen operation catalog", () => {
  it("unions the exact private billing registry without duplicate IDs", () => {
    const operations = operationContracts();
    const operationIds = operations.map(({ operationId }) => operationId);

    expect(new Set(operationIds).size).toBe(operationIds.length);
    expect(
      operationIds.filter((operationId) => operationId.startsWith("private.")),
    ).toEqual(PRIVATE_BILLING_OPERATION_IDS);
    expect(
      operations.find(
        ({ operationId }) => operationId === "private.QueueDonationIntent",
      ),
    ).toMatchObject({
      api: "billing-gateway-private",
      assurance: "NONE",
      capability: "none",
      kind: "COMMAND",
      method: "POST",
      mutatesState: true,
      path: "/internal/v1/donation-intents",
      requestSchema: "DonationIntentQueueRequestV1",
      responseSchema: "DonationIntentQueuedReceiptV1",
      status: "READY",
      stepUp: false,
      successStatus: "202",
    });
    expect(
      screenDataContracts()
        .map(({ operationId }) => operationId)
        .sort(),
    ).toEqual([...operationIds].sort());
  });

  it("composes private ownership separately from generated OpenAPI", () => {
    const privateApiOperations = apiOperations().filter(
      ({ source }) => source === "PRIVATE_BILLING_REGISTRY",
    );
    expect(privateApiOperations.map(({ id }) => id)).toEqual(
      PRIVATE_BILLING_OPERATION_IDS,
    );
    expect(
      privateApiOperations.find(
        ({ id }) => id === "private.QueueDonationIntent",
      ),
    ).toMatchObject({
      api: "billing-gateway-private",
      method: "POST",
      path: "/internal/v1/donation-intents",
      responses: {
        "202": {
          content: {
            "application/json": {
              schema: {
                $ref: "#/components/schemas/DonationIntentQueuedReceiptV1",
              },
            },
          },
        },
      },
      source: "PRIVATE_BILLING_REGISTRY",
    });
  });

  it("rejects private billing binding set and shape drift", () => {
    const addendum = structuredClone(
      yamlObject("specs/product/addendum-operation-contracts.yaml"),
    );
    const resources = structuredClone(
      yamlObject("specs/product/addendum-resource-error-contracts.yaml"),
    );
    const bindings = objectValue(
      resources.private_billing_gateway_operation_bindings,
      "private billing operation bindings",
    );
    delete bindings["private.QueueDonationIntent"];
    expect(() => addendumOperationContractsFrom(addendum, resources)).toThrow(
      "private billing operation/binding set mismatch",
    );

    const shapeResources = structuredClone(
      yamlObject("specs/product/addendum-resource-error-contracts.yaml"),
    );
    const shapeBindings = objectValue(
      shapeResources.private_billing_gateway_operation_bindings,
      "private billing operation bindings",
    );
    objectValue(
      shapeBindings["private.QueueDonationIntent"],
      "private.QueueDonationIntent",
    ).success_status = 200;
    expect(() =>
      addendumOperationContractsFrom(addendum, shapeResources),
    ).toThrow(
      "private.QueueDonationIntent private billing operation shape mismatch",
    );
  });

  it("rejects missing and duplicate private API ownership", () => {
    const addendum = structuredClone(
      yamlObject("specs/product/addendum-operation-contracts.yaml"),
    );
    const resources = structuredClone(
      yamlObject("specs/product/addendum-resource-error-contracts.yaml"),
    );
    for (const key of [
      "private_billing_gateway_operations",
      "private_billing_gateway_operation_bindings",
      "private_billing_gateway_request_schemas",
      "private_billing_gateway_error_sets",
    ])
      delete objectValue(
        key === "private_billing_gateway_operations"
          ? addendum[key]
          : resources[key],
        key,
      )["private.QueueDonationIntent"];
    expect(() => privateBillingApiOperationsFrom(addendum, resources)).toThrow(
      "private billing declared operation set mismatch",
    );

    const currentAddendum = yamlObject(
      "specs/product/addendum-operation-contracts.yaml",
    );
    const currentResources = yamlObject(
      "specs/product/addendum-resource-error-contracts.yaml",
    );
    const privateApiOperations = privateBillingApiOperationsFrom(
      currentAddendum,
      currentResources,
    );
    const duplicate = privateApiOperations[0];
    if (!duplicate) throw new Error("private billing API operations are empty");
    expect(() =>
      composeApiOperations(privateApiOperations, [duplicate]),
    ).toThrow(`duplicate API operation ownership: ${duplicate.id}`);
  });
});

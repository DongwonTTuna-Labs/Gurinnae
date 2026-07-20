import { describe, expect, it } from "vitest";
import {
  formPayload,
  indexOperations,
  type OpenApiDocument,
  operationFields,
  optimisticVersion,
} from "./screen-runtime";

const document = {
  paths: {
    "/resource": {
      patch: {
        operationId: "updateResource",
        requestBody: {
          content: {
            "application/json": {
              schema: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  paused: { type: "boolean" },
                  tags: { type: "array", items: { type: "string" } },
                  attestation: { type: "boolean" },
                },
                required: ["attestation"],
              },
            },
          },
        },
      },
    },
  },
} satisfies OpenApiDocument;

describe("screen runtime form payloads", () => {
  const indexed = indexOperations([document]).get("updateResource");
  if (!indexed) throw new Error("test operation was not indexed");
  const fields = operationFields(indexed, {});

  it("does not synthesize defaults for optional PATCH fields", () => {
    expect(
      fields.find((field) => field.name === "paused")?.value,
    ).toBeUndefined();
    expect(
      fields.find((field) => field.name === "tags")?.value,
    ).toBeUndefined();
    expect(fields.find((field) => field.name === "attestation")?.value).toBe(
      false,
    );
  });

  it("materializes OpenAPI const fields as server-bound readonly values", () => {
    const constDocument = {
      paths: {
        "/command": {
          post: {
            operationId: "constCommand",
            requestBody: {
              content: {
                "application/json": {
                  schema: {
                    type: "object",
                    properties: {
                      schemaVersion: {
                        type: "string",
                        const: "command.v1",
                      },
                    },
                    required: ["schemaVersion"],
                  },
                },
              },
            },
          },
        },
      },
    } satisfies OpenApiDocument;
    const constOperation = indexOperations([constDocument]).get("constCommand");
    if (!constOperation) throw new Error("const operation was not indexed");
    expect(operationFields(constOperation, {})).toEqual([
      {
        name: "schemaVersion",
        label: "schema Version",
        type: "text",
        required: true,
        value: "command.v1",
        readonly: true,
      },
    ]);
  });

  it("builds query fields and marks route-bound values read-only", () => {
    const queryDocument = {
      paths: {
        "/estimate": {
          get: {
            operationId: "estimate",
            parameters: [
              {
                name: "sourceId",
                in: "query",
                required: true,
                schema: { type: "string" },
              },
              {
                name: "from",
                in: "query",
                required: true,
                schema: { type: "string", format: "date" },
              },
            ],
          },
        },
      },
    } satisfies OpenApiDocument;
    const query = indexOperations([queryDocument]).get("estimate");
    if (!query) throw new Error("query operation was not indexed");
    expect(operationFields(query, { sourceId: "source-a" })).toEqual([
      {
        name: "sourceId",
        label: "source Id",
        type: "text",
        required: true,
        value: "source-a",
        readonly: true,
      },
      {
        name: "from",
        label: "from",
        type: "date",
        required: true,
      },
    ]);
  });

  it("marks server presets read-only so fixed scope fields are not presented as editable", () => {
    expect(
      operationFields(indexed, {}, { name: "server-bound" }).find(
        (field) => field.name === "name",
      ),
    ).toMatchObject({ value: "server-bound", readonly: true });
  });

  it("omits an absent optional boolean while retaining required false", () => {
    const form = new FormData();
    form.set("name", "renamed");
    const payload = formPayload(form, fields);
    expect(payload).toEqual({ name: "renamed", attestation: false });
  });

  it("allows an optional boolean to be explicitly cleared", () => {
    const form = new FormData();
    form.set("paused", "false");
    const payload = formPayload(form, fields);
    expect(payload).toEqual({ paused: false, attestation: false });
  });

  it("rejects tampering with a server-bound preset", () => {
    const fixedFields = operationFields(indexed, {}, { name: "server-bound" });
    const form = new FormData();
    form.set("name", "caller-overwrite");
    expect(() =>
      formPayload(form, fixedFields, { name: "server-bound" }),
    ).toThrow("서버 대상과 일치하지 않습니다");
  });

  it("prefers a nested current target version over wrapper metadata", () => {
    expect(
      optimisticVersion({
        id: { version: 1 },
        data: { currentCaseVersion: 7 },
      }),
    ).toBe(7);
  });
});

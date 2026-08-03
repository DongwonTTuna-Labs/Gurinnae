import { describe, expect, it } from "bun:test";
import { mockOperationId, validateMockResponse } from "./mock-api-openapi";
import { handleMockRequest } from "./mock-api-routes";

const request = () => new Request("http://mock.test/v1/openapi.json");

describe("public OpenAPI mock response", () => {
  it("routes and validates the canonical generated OpenAPI document", async () => {
    expect(mockOperationId(request())).toBe("downloadPublicOpenApi");

    const response = await handleMockRequest(request());
    expect(response.status).toBe(200);
    const document = await response.json();
    expect(document.openapi).toBe("3.1.0");
    expect(document.paths["/v1/openapi.json"].get.operationId).toBe(
      "downloadPublicOpenApi",
    );
  });

  it("rejects the legacy BinaryDownload envelope for this raw document operation", async () => {
    const response = await validateMockResponse(
      request(),
      Response.json({ id: "public-openapi-v1", status: "READY", version: 1 }),
    );
    expect(response.status).toBe(500);
    expect(await response.json()).toMatchObject({
      error: "MOCK_OPENAPI_RESPONSE_INVALID",
      operationId: "downloadPublicOpenApi",
      violations: [
        {
          message: "payload must equal the generated public OpenAPI document",
        },
      ],
    });
  });
});

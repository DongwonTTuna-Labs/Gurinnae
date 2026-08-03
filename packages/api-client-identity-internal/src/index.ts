export const packageName = "@gurine/api-client-identity-internal";
export { createClient } from "./generated/client";
export * from "./generated/index";
// The procurement generator has its own `Options`/`ClientOptions` symbols.
// Re-export its operations and domain DTOs explicitly so the two generated
// surfaces remain composable without an ambiguous package-level type export.
export {
  decideSupplierRelationshipAssertion,
  recordSupplierIdentityResolution,
  recordSupplierRelationshipAssertion,
} from "./generated-procurement/sdk.gen";
export type {
  AddendumProblemDetailsV1,
  AssertionPartyV1,
  CreateSupplierRelationshipAssertionRequestV1,
  DecideSupplierRelationshipAssertionData,
  DecideSupplierRelationshipAssertionError,
  DecideSupplierRelationshipAssertionErrors,
  DecideSupplierRelationshipAssertionRequestV1,
  DecideSupplierRelationshipAssertionResponse,
  DecideSupplierRelationshipAssertionResponses,
  RecordSupplierIdentityResolutionData,
  RecordSupplierIdentityResolutionError,
  RecordSupplierIdentityResolutionErrors,
  RecordSupplierIdentityResolutionResponse,
  RecordSupplierIdentityResolutionResponses,
  RecordSupplierRelationshipAssertionData,
  RecordSupplierRelationshipAssertionError,
  RecordSupplierRelationshipAssertionErrors,
  RecordSupplierRelationshipAssertionResponse,
  RecordSupplierRelationshipAssertionResponses,
  SupplierIdentityResolutionReceiptV1,
  SupplierIdentityResolutionRequestV1,
  SupplierRelationshipAssertionReceiptV1,
} from "./generated-procurement/types.gen";
export * from "./server";

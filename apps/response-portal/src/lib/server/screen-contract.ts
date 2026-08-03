import { indexOperations, type OpenApiDocument } from "@gurine/config";
import submissionOpenApi from "../../../../../specs/generated/submission-api.openapi.json";

export const operations = indexOperations([
  submissionOpenApi as OpenApiDocument,
]);
export const ADDENDUM_SUBMISSION_OPERATION_IDS = Object.freeze([
  "createResponseAppeal",
  "getResponseAppeal",
  "requestCommunicationEndpointLink",
  "verifyCommunicationEndpointLink",
  "unlinkCommunicationEndpoint",
  "createPrivacyRequest",
  "exchangePrivacyRequestReceiptToken",
  "getPrivacyRequest",
] as const);
export const ATTACHMENT_MAX_BYTES = 52_428_800;
export const ATTACHMENT_ACCEPT = [
  "application/pdf",
  "image/jpeg",
  "image/png",
  "text/plain",
  "text/csv",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
].join(",");

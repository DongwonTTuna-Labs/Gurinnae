import {
  DONATION_FIXTURE_OFFER,
  DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
  donationQueuedReceipt,
  parseDonationQueueRequest,
  resolvePrivateDonationOperation,
} from "./mock-api-donation-contract";
import { problem } from "./mock-api-state";

export {
  DONATION_FIXTURE_OFFER,
  DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
  validatePrivateDonationMockContract,
} from "./mock-api-donation-contract";

export async function handleDonationMock(
  request: Request,
  url: URL,
  environment = process.env.GURINE_ENV,
  configuredPaymentToken = process.env
    .DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN,
): Promise<Response | undefined> {
  const operationId = resolvePrivateDonationOperation(request, url);
  if (!operationId) return undefined;
  if (
    environment !== "test" ||
    configuredPaymentToken !== DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN
  ) {
    return problem(503, "DEPENDENCY_UNAVAILABLE");
  }
  if (operationId === "private.GetDonationFixtureOffer") {
    return url.searchParams.size === 0
      ? Response.json(DONATION_FIXTURE_OFFER)
      : problem(400, "INVALID_PARAMETER");
  }
  const input = await parseDonationQueueRequest(request);
  return input
    ? Response.json(donationQueuedReceipt(input), { status: 202 })
    : problem(400, "INVALID_PARAMETER");
}

import { describe, expect, it } from "vitest";
import {
  AnonymousSubmissionRateLimiter,
  anonymousDestination,
} from "./anonymous-rate-limit";

describe("anonymous submission BFF rate limiting", () => {
  it("enforces both per-IP and per-destination limits without retaining raw identities", () => {
    let now = 1_000;
    const limiter = new AnonymousSubmissionRateLimiter({
      now: () => now,
      ipLimit: { attempts: 3, windowMs: 1_000 },
      destinationLimit: { attempts: 2, windowMs: 2_000 },
    });
    const request = {
      operationId: "createSubscription",
      destination: "email:reader@example.test",
      key: "test-hmac-key",
    };
    expect(
      limiter.consume({ ...request, clientAddress: "192.0.2.10" }),
    ).toEqual({ allowed: true });
    expect(
      limiter.consume({ ...request, clientAddress: "192.0.2.11" }),
    ).toEqual({ allowed: true });
    expect(
      limiter.consume({ ...request, clientAddress: "192.0.2.12" }),
    ).toEqual({ allowed: false, retryAfterSeconds: 2 });

    now = 3_001;
    expect(
      limiter.consume({ ...request, clientAddress: "192.0.2.12" }),
    ).toEqual({ allowed: true });
  });

  it("limits one client across changing destinations", () => {
    const limiter = new AnonymousSubmissionRateLimiter({
      ipLimit: { attempts: 2, windowMs: 60_000 },
      destinationLimit: { attempts: 10, windowMs: 60_000 },
    });
    const request = {
      clientAddress: "192.0.2.20",
      operationId: "createContactRequest",
      key: "test-hmac-key",
    };
    expect(
      limiter.consume({ ...request, destination: "email:first@example.test" }),
    ).toEqual({ allowed: true });
    expect(
      limiter.consume({ ...request, destination: "email:second@example.test" }),
    ).toEqual({ allowed: true });
    expect(
      limiter.consume({ ...request, destination: "email:third@example.test" }),
    ).toMatchObject({ allowed: false });
  });

  it("derives privacy-safe logical destinations for every anonymous start", () => {
    expect(
      anonymousDestination(
        "createSubscription",
        { email: " Reader@Example.Test " },
        "192.0.2.1",
      ),
    ).toBe("email:reader@example.test");
    expect(
      anonymousDestination(
        "createDatasetExport",
        { datasetId: "public-contracts" },
        "192.0.2.1",
      ),
    ).toBe("dataset:public-contracts");
    expect(
      anonymousDestination(
        "createCorrectionRequestDraft",
        { caseSlug: "Case-A", publicationRevision: 3 },
        "192.0.2.1",
      ),
    ).toBe("case:case-a:3");
    expect(
      anonymousDestination(
        "private.QueueDonationIntent",
        { tierId: "fixture-tier" },
        "192.0.2.1",
      ),
    ).toBe("client:192.0.2.1");
  });
});

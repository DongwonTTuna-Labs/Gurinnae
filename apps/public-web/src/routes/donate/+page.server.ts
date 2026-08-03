import type {
  DonationActionErrorCode,
  DonationFormSelection,
  ScreenRuntime,
} from "@gurine/ui";
import { type Actions, fail } from "@sveltejs/kit";
import {
  loadDonationFixtureOffer,
  parseDonationForm,
  parseDonationFormSelection,
  queueDonationIntent,
} from "$lib/server/donation-bff";
import {
  checkAnonymousRateLimit,
  formIdempotencyKey,
  sameOrigin,
} from "$lib/server/screen-helpers";
import { loadScreen } from "$lib/server/screen-load";
import { donationScreenRuntime } from "$lib/view-models/pub-035";
import { screen } from "./screen";

export const load = async (event) => {
  const loaded = await loadScreen(event, screen);
  const offer = await loadDonationFixtureOffer(event);
  const donation = donationScreenRuntime(offer);
  const runtime: ScreenRuntime = {
    ...loaded.runtime,
    state: offer.state === "READY" ? "success" : "partial",
    donation,
  };
  return {
    ...loaded,
    runtime,
  };
};

export const actions: Actions = {
  "queue-donation": async (event) => {
    if (!sameOrigin(event)) return actionFailure(403, "ORIGIN_DENIED");

    let form: FormData;
    try {
      form = await event.request.formData();
    } catch {
      return actionFailure(400, "INVALID_REQUEST");
    }
    const selection = parseDonationFormSelection(form);

    let idempotencyKey: string;
    try {
      idempotencyKey = formIdempotencyKey(form);
    } catch {
      return actionFailure(400, "INVALID_REQUEST", selection);
    }
    const input = parseDonationForm(form);
    if (!input) return actionFailure(400, "INVALID_REQUEST", selection);

    let rateLimitFailure: ReturnType<typeof checkAnonymousRateLimit>;
    try {
      rateLimitFailure = checkAnonymousRateLimit(
        event,
        "private.QueueDonationIntent",
        {
          offerVersionId: input.offerVersionId,
          offerDigest: input.offerDigest,
          tierId: input.tierId,
          cadence: input.cadence,
          provider: input.provider,
        },
      );
    } catch {
      return actionFailure(503, "UNAVAILABLE", selection);
    }
    if (rateLimitFailure) {
      return actionFailure(429, "RATE_LIMITED", selection);
    }

    const result = await queueDonationIntent(event, input, idempotencyKey);
    if (!result.ok) {
      return actionFailure(result.status, result.code, selection);
    }
    return {
      donationAction: {
        state: "QUEUED" as const,
        receipt: result.receipt,
      },
    };
  },
};

function actionFailure(
  status: 400 | 403 | 409 | 429 | 502 | 503,
  code: DonationActionErrorCode,
  selection?: DonationFormSelection,
) {
  const donationAction = { state: "ERROR" as const, code };
  return fail(
    status,
    selection
      ? { donationAction, donationSelection: selection }
      : { donationAction },
  );
}

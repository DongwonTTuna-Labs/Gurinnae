import type {
  DonationActionState,
  DonationOfferViewModel,
  DonationScreenRuntime,
  ScreenRuntime,
} from "@gurine/ui";
import { donationActionState } from "@gurine/ui";

export function donationScreenRuntime(
  offer: DonationOfferViewModel,
  action: DonationActionState = { state: "IDLE" },
): DonationScreenRuntime {
  return { offer, action };
}

export function withDonationAction(
  runtime: ScreenRuntime,
  actionData: unknown,
): ScreenRuntime {
  const donation = runtime.donation ?? {
    offer: {
      state: "UNAVAILABLE" as const,
      reason: "후원 화면 구성을 확인할 수 없습니다.",
    },
    action: { state: "IDLE" as const },
  };
  return {
    ...runtime,
    donation: { ...donation, action: donationActionState(actionData) },
  };
}

import type { RequestEvent } from "@sveltejs/kit";
import {
  isProviderControlOperation,
  type RelayProviderAuthority,
  relayModelFormContext,
} from "./relay-model-form";
import { operations } from "./screen-contract";
import { controlRequest } from "./screen-control";

export type RelayModelMutationContext =
  | {
      ok: true;
      data: Record<string, unknown>;
      preset: Readonly<Record<string, unknown>>;
      authority?: Readonly<RelayProviderAuthority>;
      activeModelIds: readonly string[];
    }
  | {
      ok: false;
      status: number;
      message?: string;
      value?: unknown;
    };

export async function loadRelayModelMutationContext(
  event: RequestEvent,
  operationId: string,
): Promise<RelayModelMutationContext> {
  if (!isProviderControlOperation(operationId)) {
    return { ok: true, data: {}, preset: {}, activeModelIds: [] };
  }
  const catalogOperation = operations.get("listRelayModels");
  if (!catalogOperation) {
    return {
      ok: false,
      status: 500,
      message: "모델 카탈로그 계약을 찾지 못했습니다.",
    };
  }
  const result = await controlRequest(
    event,
    catalogOperation,
    catalogOperation.path,
    "",
  );
  if (!result.response.ok) {
    return {
      ok: false,
      status: result.response.status,
      value: result.value,
    };
  }
  const data = { listRelayModels: result.value };
  const context = relayModelFormContext(data);
  if (!context) {
    return {
      ok: false,
      status: 409,
      message: "relay 공급자 대상을 하나로 확정할 수 없습니다.",
    };
  }
  return {
    ok: true,
    data,
    preset: context.preset,
    authority: context.authority,
    activeModelIds: context.activeModelIds,
  };
}

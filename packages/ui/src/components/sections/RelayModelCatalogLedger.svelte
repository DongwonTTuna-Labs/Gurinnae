<script lang="ts">
import {
  RELAY_UNPRICED_CAPTION,
  type RelayModelCatalogViewModel,
} from "../../relay-model-catalog";

let { catalog }: { catalog?: RelayModelCatalogViewModel } = $props();
const yesNo = (value: boolean) => (value ? "예" : "아니오");
</script>

<div class="relay-model-ledger" data-component="RelayModelCatalogLedger" data-testid="ops_005__model_catalog_ledger">
  <p class="catalog-caption">{RELAY_UNPRICED_CAPTION}</p>
  {#if catalog}
    <div class="table-scroll" role="region" aria-label="relay 모델 대장">
      <table>
        <caption>relay 모델 대장</caption>
        <thead><tr><th scope="col">모델 식별자</th><th scope="col">모델 계열</th><th scope="col">공개 시각</th><th scope="col">활성</th><th scope="col">현재 사용</th><th scope="col">신규</th><th scope="col">채택 기록</th></tr></thead>
        <tbody>
          {#each catalog.models as model (model.modelId)}
            <tr><th scope="row"><code>{model.modelId}</code></th><td>{model.family ?? "확인 필요"}</td><td>{model.createdAt ?? "확인 필요"}</td><td>{yesNo(model.active)}</td><td>{yesNo(model.current)}</td><td>{yesNo(model.new)}</td><td>{model.adoption}</td></tr>
          {:else}
            <tr><td colspan="7">등록된 모델 없음</td></tr>
          {/each}
        </tbody>
      </table>
    </div>
    <div class="table-scroll" role="region" aria-label="relay 공급자 모델 상태">
      <table>
        <caption>relay 공급자 모델 상태</caption>
        <thead><tr><th scope="col">공급자</th><th scope="col">현재 모델</th><th scope="col">사용 상태</th><th scope="col">자동 업그레이드</th><th scope="col">자동 업그레이드 충돌</th><th scope="col">단가 상태</th></tr></thead>
        <tbody>
          {#each catalog.providers as provider (provider.providerId)}
            <tr><th scope="row">{provider.name}</th><td>{provider.currentModel ?? "미선택"}</td><td>{provider.enabled ? "사용" : "중지"}</td><td>{provider.autoUpgrade ? "사용" : "중지"}</td><td>{provider.autoUpgradeConflict ? "충돌" : "없음"}</td><td>{provider.unpriced ? "미설정" : "설정"}</td></tr>
          {:else}
            <tr><td colspan="6">등록된 relay 공급자 없음</td></tr>
          {/each}
        </tbody>
      </table>
    </div>
  {:else}
    <p class="catalog-unavailable" role="status">모델 카탈로그 확인 필요</p>
  {/if}
</div>

<style>
  .relay-model-ledger {
    display: grid;
    gap: 0.5rem;
    min-width: 0;
  }

  .catalog-caption,
  .catalog-unavailable {
    margin: 0;
    color: var(--ink-700);
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  .table-scroll {
    max-width: 100%;
    overflow-x: auto;
    border-block: 1px solid var(--paper-200);
  }

  table {
    width: 100%;
    min-width: 42rem;
    border-collapse: collapse;
    text-align: left;
    font-size: 0.8125rem;
  }

  caption {
    padding: 0.375rem 0.5rem;
    color: var(--ink-700);
    font-weight: 650;
    text-align: left;
  }

  th,
  td {
    padding: 0.375rem 0.5rem;
    border-top: 1px solid var(--paper-100);
    vertical-align: top;
  }

  th {
    color: var(--ink-900);
    font-weight: 650;
  }

  code {
    font: inherit;
  }

  @media (max-width: 620px) {
    table {
      min-width: 38rem;
    }
  }

  @media (forced-colors: active) {
    .table-scroll,
    th,
    td {
      border-color: CanvasText;
    }
  }
</style>

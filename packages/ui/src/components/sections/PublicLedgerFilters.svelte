<script lang="ts">
import { presentEnumValue } from "../../enum-presentation";
import type { ScreenRuntime, ScreenSection } from "../../index";
import {
  type PublicLedgerFilterScreenId,
  type UrlFilterContract,
  urlFilterArrayValues,
  urlFilterScalarValue,
} from "../../url-filter-contracts";

const SEARCH_TYPES = [
  "CASE",
  "CONTRACT",
  "AGENCY",
  "SUPPLIER",
  "METHODOLOGY",
  "CORRECTION",
] as const;
const PUBLICATION_STATES = [
  "PUBLISHED_ANOMALY",
  "PUBLISHED_EXPLAINED",
  "OFFICIALLY_CONFIRMED",
  "CORRECTED",
  "RETRACTED",
  "TEMPORARILY_RESTRICTED",
] as const;
const CORRECTION_STATES = ["CORRECTED", "RETRACTED"] as const;
const IDENTITY_STATES = ["VERIFIED", "AMBIGUOUS"] as const;
const CONTRACT_STATES = [
  "ANNOUNCED",
  "AWARDED",
  "ACTIVE",
  "COMPLETED",
  "CANCELLED",
  "UNKNOWN",
] as const;

let {
  screenId,
  section,
  runtime,
  contract,
  formAction,
  showStateMessage,
  stateMessage,
}: {
  screenId: PublicLedgerFilterScreenId;
  section: ScreenSection;
  runtime: ScreenRuntime;
  contract: UrlFilterContract;
  formAction: string;
  showStateMessage: boolean;
  stateMessage: string;
} = $props();

function initialSearchParams(): URLSearchParams {
  return new URLSearchParams((runtime.search ?? "").replace(/^\?/, ""));
}

const initial = initialSearchParams();
let q = $state(initial.get("q") ?? "");
let types = $state(initial.getAll("types"));
let publicationState = $state(initial.getAll("publicationState"));
let dateFrom = $state(initial.get("dateFrom") ?? "");
let dateTo = $state(initial.get("dateTo") ?? "");
let agencyId = $state(initial.get("agencyId") ?? "");
let supplierId = $state(initial.get("supplierId") ?? "");
let ruleId = $state(initial.get("ruleId") ?? "");
let sidoCode = $state(initial.get("sidoCode") ?? "");
let sigunguCode = $state(initial.get("sigunguCode") ?? "");
let publishedFrom = $state(initial.get("publishedFrom") ?? "");
let publishedTo = $state(initial.get("publishedTo") ?? "");
let hasResponse = $state(initial.get("hasResponse") ?? "");
let hasCorrection = $state(initial.get("hasCorrection") ?? "");
let agencyType = $state(initial.getAll("agencyType").join(", "));
let jurisdiction = $state(initial.get("jurisdiction") ?? "");
let businessStatus = $state(initial.getAll("businessStatus").join(", "));
let identityStatus = $state(initial.getAll("identityStatus"));
let contractStatus = $state(initial.getAll("contractStatus"));
let procurementMethod = $state(initial.getAll("procurementMethod").join(", "));
let signedFrom = $state(initial.get("signedFrom") ?? "");
let signedTo = $state(initial.get("signedTo") ?? "");
let amountMin = $state(initial.get("amountMin") ?? "");
let amountMax = $state(initial.get("amountMax") ?? "");
let sort = $state(initial.get("sort") ?? "");

const activeSection = $derived(
  screenId === "PUB-002"
    ? section.id === "query"
    : screenId === "PUB-007" || screenId === "PUB-009"
      ? section.id === "search"
      : section.id === "filters",
);
const ownsNamedAction = $derived(
  screenId === "PUB-007" || screenId === "PUB-009"
    ? section.id === "search"
    : showStateMessage,
);

function scalarValue(key: string): string | undefined {
  const values: Readonly<Record<string, string>> = {
    q,
    dateFrom,
    dateTo,
    agencyId,
    supplierId,
    ruleId,
    sidoCode,
    sigunguCode,
    publishedFrom,
    publishedTo,
    hasResponse,
    hasCorrection,
    jurisdiction,
    signedFrom,
    signedTo,
    amountMin,
    amountMax,
    sort,
  };
  return urlFilterScalarValue(values[key] ?? "");
}

function arrayValues(key: string): readonly string[] {
  if (key === "types") return types;
  if (key === "publicationState") return publicationState;
  if (key === "identityStatus") return identityStatus;
  if (key === "contractStatus") return contractStatus;
  if (key === "agencyType") return urlFilterArrayValues(agencyType);
  if (key === "businessStatus") return urlFilterArrayValues(businessStatus);
  if (key === "procurementMethod")
    return urlFilterArrayValues(procurementMethod);
  return [];
}

function exampleHref(term: string): string {
  return `/search?q=${encodeURIComponent(term)}`;
}
</script>

{#if activeSection}
  <form
    id={ownsNamedAction ? `action-${contract.actionId}` : undefined}
    class="ledger-filters"
    method="GET"
    action={formAction}
    role="search"
    aria-label={section.title}
    data-action-id={ownsNamedAction ? contract.actionId : undefined}
  >
    {#if screenId === "PUB-002"}
      <label for={`${section.test_id}-query`}>기관·업체·계약·사건 검색</label>
      <div class="ledger-filters__query">
        <input bind:value={q} id={`${section.test_id}-query`} data-testid="pub_002__state__awaiting_query__search_input" data-focus-target="pub_002__state__awaiting_query__search_input" data-query-key="q" type="search" autocomplete="off" placeholder="이름·계약번호·키워드" />
        <button type="submit">{contract.actionLabel}</button>
      </div>
      <details>
        <summary>유형·지역·공개 상태·기간·정렬</summary>
        <div class="ledger-filters__grid">
          <label for={`${section.test_id}-types`}>객체 유형<select bind:value={types} id={`${section.test_id}-types`} data-query-key="types" multiple size="3">{#each SEARCH_TYPES as value}<option {value}>{presentEnumValue(value)}</option>{/each}</select></label>
          <label for={`${section.test_id}-publication-state`}>공개 상태<select bind:value={publicationState} id={`${section.test_id}-publication-state`} data-query-key="publicationState" multiple size="3">{#each PUBLICATION_STATES as value}<option {value}>{presentEnumValue(value)}</option>{/each}</select></label>
          <label for={`${section.test_id}-sido-code`}>시도 코드<input bind:value={sidoCode} id={`${section.test_id}-sido-code`} data-query-key="sidoCode" type="text" inputmode="numeric" pattern="[0-9]{2}" maxlength="2" placeholder="2자리" /></label>
          <label for={`${section.test_id}-sigungu-code`}>시군구 코드<input bind:value={sigunguCode} id={`${section.test_id}-sigungu-code`} data-query-key="sigunguCode" type="text" inputmode="numeric" pattern="[0-9]{5}" maxlength="5" placeholder="5자리" /></label>
          <label for={`${section.test_id}-date-from`}>시작일<input bind:value={dateFrom} id={`${section.test_id}-date-from`} data-query-key="dateFrom" type="date" /></label>
          <label for={`${section.test_id}-date-to`}>종료일<input bind:value={dateTo} id={`${section.test_id}-date-to`} data-query-key="dateTo" type="date" /></label>
          <label for={`${section.test_id}-sort`}>정렬<select bind:value={sort} id={`${section.test_id}-sort`} data-query-key="sort"><option value="">기본 정렬</option><option value="relevance">관련도</option><option value="updated_desc">최근 갱신순</option><option value="title_asc">제목순</option></select></label>
        </div>
      </details>
    {:else if screenId === "PUB-007" || screenId === "PUB-009"}
      <label for={`${section.test_id}-query`}>{screenId === "PUB-007" ? "기관명 검색" : "업체명 검색"}</label>
      <div class="ledger-filters__query">
        <input bind:value={q} id={`${section.test_id}-query`} data-query-key="q" type="search" autocomplete="off" placeholder={screenId === "PUB-007" ? "공식·과거 기관명" : "공식·과거 업체명"} />
        <button type="submit">{contract.actionLabel}</button>
      </div>
      <details>
        <summary>{screenId === "PUB-007" ? "기관 유형·관할·정렬" : "영업·식별 상태·정렬"}</summary>
        <div class="ledger-filters__grid">
          {#if screenId === "PUB-007"}
            <label for={`${section.test_id}-agency-type`}>기관 유형<input bind:value={agencyType} id={`${section.test_id}-agency-type`} data-query-key="agencyType" type="search" autocomplete="off" placeholder="예: 지방자치단체" /></label>
            <label for={`${section.test_id}-jurisdiction`}>관할 지역<input bind:value={jurisdiction} id={`${section.test_id}-jurisdiction`} data-query-key="jurisdiction" type="search" autocomplete="off" placeholder="시도·시군구" /></label>
          {:else}
            <label for={`${section.test_id}-business-status`}>영업 상태<input bind:value={businessStatus} id={`${section.test_id}-business-status`} data-query-key="businessStatus" type="search" autocomplete="off" placeholder="예: 영업 중" /></label>
            <label for={`${section.test_id}-identity-status`}>식별 상태<select bind:value={identityStatus} id={`${section.test_id}-identity-status`} data-query-key="identityStatus" multiple size="2">{#each IDENTITY_STATES as value}<option {value}>{presentEnumValue(value)}</option>{/each}</select></label>
          {/if}
          <label for={`${section.test_id}-sort`}>정렬<select bind:value={sort} id={`${section.test_id}-sort`} data-query-key="sort"><option value="">이름순</option><option value="updated_desc">최근 갱신순</option><option value="contract_count_desc">계약 많은 순</option></select></label>
        </div>
      </details>
    {:else}
      <div class="ledger-filters__grid">
        {#if screenId === "PUB-003"}
          <label for={`${section.test_id}-publication-state`}>공개 상태<select bind:value={publicationState} id={`${section.test_id}-publication-state`} data-query-key="publicationState" multiple size="3">{#each PUBLICATION_STATES as value}<option {value}>{presentEnumValue(value)}</option>{/each}</select></label>
          <label for={`${section.test_id}-sido-code`}>시도 코드<input bind:value={sidoCode} id={`${section.test_id}-sido-code`} data-query-key="sidoCode" type="text" inputmode="numeric" pattern="[0-9]{2}" maxlength="2" placeholder="2자리" /></label>
          <label for={`${section.test_id}-sigungu-code`}>시군구 코드<input bind:value={sigunguCode} id={`${section.test_id}-sigungu-code`} data-query-key="sigunguCode" type="text" inputmode="numeric" pattern="[0-9]{5}" maxlength="5" placeholder="5자리" /></label>
          <label for={`${section.test_id}-published-from`}>공개 시작일<input bind:value={publishedFrom} id={`${section.test_id}-published-from`} data-query-key="publishedFrom" type="date" /></label>
          <label for={`${section.test_id}-published-to`}>공개 종료일<input bind:value={publishedTo} id={`${section.test_id}-published-to`} data-query-key="publishedTo" type="date" /></label>
          <label for={`${section.test_id}-has-response`}>소명<select bind:value={hasResponse} id={`${section.test_id}-has-response`} data-query-key="hasResponse"><option value="">전체</option><option value="true">있음</option><option value="false">없음</option></select></label>
          <label for={`${section.test_id}-has-correction`}>정정<select bind:value={hasCorrection} id={`${section.test_id}-has-correction`} data-query-key="hasCorrection"><option value="">전체</option><option value="true">있음</option><option value="false">없음</option></select></label>
          <label for={`${section.test_id}-sort`}>정렬<select bind:value={sort} id={`${section.test_id}-sort`} data-query-key="sort"><option value="">기본 정렬</option><option value="updated_desc">최근 갱신순</option><option value="published_desc">최근 공개순</option><option value="title_asc">제목순</option></select></label>
        {:else if screenId === "PUB-011"}
          <label for={`${section.test_id}-query`}>계약 검색<input bind:value={q} id={`${section.test_id}-query`} data-query-key="q" type="search" autocomplete="off" placeholder="계약명·계약번호" /></label>
          <label for={`${section.test_id}-contract-status`}>계약 상태<select bind:value={contractStatus} id={`${section.test_id}-contract-status`} data-query-key="contractStatus" multiple size="3">{#each CONTRACT_STATES as value}<option {value}>{presentEnumValue(value)}</option>{/each}</select></label>
          <label for={`${section.test_id}-procurement-method`}>계약 방식<input bind:value={procurementMethod} id={`${section.test_id}-procurement-method`} data-query-key="procurementMethod" type="search" autocomplete="off" placeholder="계약 방식" /></label>
          <label for={`${section.test_id}-signed-from`}>체결일 시작<input bind:value={signedFrom} id={`${section.test_id}-signed-from`} data-query-key="signedFrom" type="date" /></label>
          <label for={`${section.test_id}-signed-to`}>체결일 종료<input bind:value={signedTo} id={`${section.test_id}-signed-to`} data-query-key="signedTo" type="date" /></label>
          <label for={`${section.test_id}-amount-min`}>최소 금액<input bind:value={amountMin} id={`${section.test_id}-amount-min`} data-query-key="amountMin" inputmode="decimal" type="text" pattern="^-?\d+(\.\d+)?$" /></label>
          <label for={`${section.test_id}-amount-max`}>최대 금액<input bind:value={amountMax} id={`${section.test_id}-amount-max`} data-query-key="amountMax" inputmode="decimal" type="text" pattern="^-?\d+(\.\d+)?$" /></label>
          <label for={`${section.test_id}-sort`}>정렬<select bind:value={sort} id={`${section.test_id}-sort`} data-query-key="sort"><option value="">최근 계약순</option><option value="amount_desc">금액 높은 순</option><option value="amount_asc">금액 낮은 순</option><option value="title_asc">제목순</option></select></label>
        {:else}
          <label for={`${section.test_id}-publication-state`}>변경 유형<select bind:value={publicationState} id={`${section.test_id}-publication-state`} data-query-key="publicationState" multiple size="2">{#each CORRECTION_STATES as value}<option {value}>{presentEnumValue(value)}</option>{/each}</select></label>
          <label for={`${section.test_id}-published-from`}>공개 시작일<input bind:value={publishedFrom} id={`${section.test_id}-published-from`} data-query-key="publishedFrom" type="date" /></label>
          <label for={`${section.test_id}-published-to`}>공개 종료일<input bind:value={publishedTo} id={`${section.test_id}-published-to`} data-query-key="publishedTo" type="date" /></label>
          <label for={`${section.test_id}-sort`}>정렬<select bind:value={sort} id={`${section.test_id}-sort`} data-query-key="sort"><option value="">최근 변경순</option><option value="title_asc">제목순</option></select></label>
        {/if}
      </div>
      <div class="ledger-filters__actions"><button type="submit">{contract.actionLabel}</button></div>
    {/if}

    {#each contract.queryKeys as key}
      {#if contract.arrayKeys.includes(key)}
        {#each arrayValues(key) as value}<input type="hidden" name={key} {value} />{/each}
      {:else if scalarValue(key) !== undefined}
        <input type="hidden" name={key} value={scalarValue(key)} />
      {/if}
    {/each}

    {#if showStateMessage && runtime.state !== "awaiting-query"}
      <p class="ledger-filters__status" aria-live="polite" role="status">{stateMessage}</p>
    {/if}
    {#if showStateMessage && screenId === "PUB-002" && runtime.state === "awaiting-query"}
      <nav class="ledger-filters__suggestions" aria-label="검색 시작">
        <span>예시 검색어</span>
        {#each ["시설 유지보수 계약", "재난 안전", "정정 공개"] as example}<a href={exampleHref(example)}>{example}</a>{/each}
        <a href="/agencies">기관 대장 보기</a>
      </nav>
    {/if}
  </form>
{/if}

<style>
  .ledger-filters {
    display: grid;
    width: 100%;
    gap: 0.5rem;
    padding-block: 0.625rem;
    border-block: 1px solid var(--paper-200);
  }

  .ledger-filters > label,
  .ledger-filters__grid label {
    color: var(--ink-700);
    font-size: 0.75rem;
    font-weight: 650;
  }

  .ledger-filters__query {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 0.5rem;
  }

  .ledger-filters__grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
    gap: 0.5rem;
  }

  .ledger-filters__grid label {
    display: grid;
    gap: 0.25rem;
  }

  input,
  select,
  button {
    min-width: 0;
    min-height: var(--target-min);
    border: 1px solid var(--paper-200);
    border-radius: 4px;
    font: inherit;
  }

  input,
  select {
    width: 100%;
    padding: 0.45rem 0.625rem;
    background: var(--paper-0);
    color: var(--ink-950);
    font-size: 0.875rem;
  }

  button {
    padding-inline: 0.875rem;
    border-color: var(--blue-700);
    background: var(--blue-700);
    color: var(--paper-0);
    cursor: pointer;
    font-size: 0.875rem;
    font-weight: 650;
  }

  details {
    padding-top: 0.375rem;
    border-top: 1px solid var(--paper-200);
  }

  summary {
    min-height: var(--target-min);
    padding-block: 0.375rem;
    color: var(--ink-700);
    cursor: pointer;
    font-size: 0.8125rem;
    font-weight: 650;
  }

  .ledger-filters__actions {
    display: flex;
    justify-content: flex-end;
  }

  .ledger-filters__status {
    display: flex;
    gap: 0.5rem;
    min-block-size: 1.5rem;
    margin: 0;
    color: var(--ink-700);
    font-size: 0.75rem;
    line-height: 1.4;
  }

  .ledger-filters__status::before {
    width: 0.45rem;
    height: 0.45rem;
    flex: 0 0 auto;
    margin-top: 0.4em;
    border-radius: 50%;
    background: var(--blue-500);
    content: "";
  }

  .ledger-filters__suggestions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.375rem 0.75rem;
    align-items: center;
    color: var(--ink-700);
    font-size: 0.75rem;
  }

  .ledger-filters__suggestions span {
    font-weight: 650;
  }

  .ledger-filters__suggestions a {
    color: var(--blue-700);
    text-underline-offset: 0.15em;
  }

  @media (max-width: 640px) {
    .ledger-filters__query,
    .ledger-filters__grid {
      grid-template-columns: 1fr;
    }

    button {
      width: 100%;
    }
  }

  @media (forced-colors: active) {
    .ledger-filters,
    details,
    input,
    select,
    button {
      border-color: CanvasText;
      background: Canvas;
      color: CanvasText;
    }
  }
</style>

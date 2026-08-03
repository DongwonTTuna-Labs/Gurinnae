<script lang="ts">
import {
  fundingDisclosureStatusLabel,
  fundingTimestampLabel,
  type ScreenSectionProps,
} from "../../index";
import SectionHeading from "./SectionHeading.svelte";

let { section, runtime }: ScreenSectionProps = $props();
const funding = $derived(runtime.fundingTransparency);
const model = $derived(
  funding?.sections.find((candidate) => candidate.id === section.id),
);
const reports = $derived(funding?.reports ?? []);
const external = (href: string) => href.startsWith("https://");
</script>
<SectionHeading {section} kicker="공개 재원 원장" />
{#if model}
  <div class="funding-status">
    <span class:available={model.status === "AVAILABLE"}></span>
    <strong>{fundingDisclosureStatusLabel(model.status)}</strong>
    <time datetime={model.updatedAt}>기준 {fundingTimestampLabel(model.updatedAt)}</time>
  </div>
  <p class="funding-body">{model.body}</p>
  {#if model.links.length > 0}
    <ul class="source-links" aria-label={`${model.heading} 공개 근거`}>
      {#each model.links as link (link.href)}
        <li>
          <a
            href={link.href}
            rel={external(link.href) ? "noreferrer" : undefined}
          >{link.label}</a>
        </li>
      {/each}
    </ul>
  {/if}
  {#if section.id === "reports"}
    {#if reports.length > 0}
      <div class="report-table-wrap">
        <table>
          <caption>승인 공개 개정별 투명성 보고서</caption>
          <thead>
            <tr>
              <th scope="col">기간</th>
              <th scope="col">보고서</th>
              <th scope="col">발행 시각</th>
              <th scope="col">다운로드</th>
            </tr>
          </thead>
          <tbody>
            {#each reports as report (report.id)}
              <tr>
                <td>{report.periodStart}–{report.periodEnd}</td>
                <td>
                  <strong>{report.title}</strong>
                  <small>{report.summary}</small>
                </td>
                <td><time datetime={report.publishedAt}>{fundingTimestampLabel(report.publishedAt)}</time></td>
                <td class="report-actions">
                  <a href={report.jsonDownloadHref} download>JSON</a>
                  <a href={report.csvDownloadHref} download>CSV</a>
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
      <ul class="report-record-list" aria-label="승인 공개 투명성 보고서">
        {#each reports as report (report.id)}
          <li>
            <dl>
              <div>
                <dt>기간</dt>
                <dd>{report.periodStart}–{report.periodEnd}</dd>
              </div>
              <div>
                <dt>보고서</dt>
                <dd>
                  <strong>{report.title}</strong>
                  <small>{report.summary}</small>
                </dd>
              </div>
              <div>
                <dt>발행 시각</dt>
                <dd><time datetime={report.publishedAt}>{fundingTimestampLabel(report.publishedAt)}</time></dd>
              </div>
            </dl>
            <div class="report-actions" aria-label={`${report.title} 다운로드`}>
              <a href={report.jsonDownloadHref} download>JSON</a>
              <a href={report.csvDownloadHref} download>CSV</a>
            </div>
          </li>
        {/each}
      </ul>
    {:else}
      <p class="report-empty" role="status">다운로드 가능한 승인 보고서가 없습니다.</p>
    {/if}
  {/if}
{:else}
  <p class="funding-error" role="status">
    공개 재원 자료를 검증할 수 없어 값을 표시하지 않습니다.
  </p>
{/if}
<style>
  .funding-status {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem 0.5rem;
    align-items: center;
    padding: 0.375rem 0.5rem;
    border-block: 1px solid var(--paper-200);
    font-size: 0.75rem;
  }
  .funding-status > span {
    width: 0.5rem;
    height: 0.5rem;
    border-radius: 50%;
    background: var(--amber-600);
  }
  .funding-status > span.available {
    background: var(--blue-600);
  }
  .funding-status time {
    margin-left: auto;
    color: var(--ink-500);
  }
  .funding-body,
  .funding-error,
  .report-empty {
    margin: 0;
    padding: 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    color: var(--ink-800);
    font-size: 0.8125rem;
    line-height: 1.5;
  }
  .funding-error {
    color: var(--red-700);
  }
  .source-links {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem 0.75rem;
    margin: 0;
    padding: 0.375rem 0.5rem;
    border-bottom: 1px solid var(--paper-200);
    list-style: none;
  }
  .source-links a,
  .report-actions a {
    display: inline-flex;
    box-sizing: border-box;
    min-width: 44px;
    min-height: 44px;
    align-items: center;
    justify-content: center;
    font-size: 0.75rem;
    font-weight: 650;
  }
  .report-table-wrap {
    max-width: 100%;
    overflow-x: auto;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.75rem;
  }
  caption {
    padding: 0.375rem 0.5rem;
    color: var(--ink-500);
    text-align: left;
  }
  th,
  td {
    padding: 0.5rem;
    border-block: 1px solid var(--paper-200);
    text-align: left;
    vertical-align: top;
  }
  th {
    color: var(--ink-500);
    font-weight: 650;
  }
  td strong,
  td small {
    display: block;
  }
  td small {
    margin-top: 0.125rem;
    color: var(--ink-600);
    font-size: 0.75rem;
  }
  .report-actions {
    display: flex;
    gap: 0.25rem;
    align-items: flex-start;
    white-space: nowrap;
  }
  .report-record-list {
    display: none;
    margin: 0;
    padding: 0;
    list-style: none;
  }
  @media (max-width: 720px) {
    .report-table-wrap {
      display: none;
    }
    .report-record-list {
      display: grid;
    }
    .report-record-list > li {
      display: grid;
      gap: 0.5rem;
      padding: 0.5rem;
      border-block: 1px solid var(--paper-200);
    }
    .report-record-list dl {
      display: grid;
      gap: 0.375rem;
      margin: 0;
    }
    .report-record-list dl > div {
      display: grid;
      grid-template-columns: 5.5rem minmax(0, 1fr);
      gap: 0.5rem;
    }
    .report-record-list dt {
      color: var(--ink-500);
      font-size: 0.75rem;
      font-weight: 650;
    }
    .report-record-list dd {
      min-width: 0;
      margin: 0;
      font-size: 0.75rem;
      overflow-wrap: anywhere;
    }
    .report-record-list dd strong,
    .report-record-list dd small {
      display: block;
    }
    .report-record-list dd small {
      margin-top: 0.125rem;
      color: var(--ink-600);
      font-size: 0.75rem;
    }
  }
</style>

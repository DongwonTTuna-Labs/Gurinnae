use super::*;

const ZERO_SHA256: &str = "0000000000000000000000000000000000000000000000000000000000000000";

fn string_field(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn uuid_field(value: &Value, key: &str) -> Option<Uuid> {
    string_field(value, key).and_then(|raw| Uuid::parse_str(&raw).ok())
}

fn sha_field(value: &Value, key: &str, fallback: &str) -> String {
    string_field(value, key)
        .filter(|value| is_sha256(value))
        .unwrap_or_else(|| sha256(fallback.as_bytes()))
}

fn array_field<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn status_label(status: &str) -> &'static str {
    match status {
        "QUEUED" => "대기 중",
        "RUNNING" => "실행 중",
        "SUCCEEDED" => "완료",
        "FAILED" => "실패",
        "CANCELLED" => "취소됨",
        "BUDGET_BLOCKED" => "예산 차단",
        "POLICY_BLOCKED" => "정책 차단",
        _ => "확인되지 않음",
    }
}

fn screen_state(status: &str) -> &'static str {
    match status {
        "QUEUED" | "RUNNING" => "loading",
        "SUCCEEDED" => "saved",
        "FAILED" => "error",
        "CANCELLED" | "BUDGET_BLOCKED" | "POLICY_BLOCKED" => "blocked",
        _ => "error",
    }
}

fn control_state(status: &str) -> &'static str {
    match status {
        "QUEUED" => "NONE",
        "RUNNING" => "ACTIVE",
        "FAILED" | "CANCELLED" | "BUDGET_BLOCKED" | "POLICY_BLOCKED" => "BLOCKED",
        _ => "SETTLED",
    }
}

fn cost_micros(value: Option<&Value>) -> Option<i64> {
    let raw = value.and_then(Value::as_str)?.trim();
    if raw.is_empty() || raw.starts_with('-') {
        return None;
    }
    let mut parts = raw.split('.');
    let whole_text = parts.next()?;
    if whole_text.is_empty() || !whole_text.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let whole = whole_text.parse::<i64>().ok()?;
    let fraction = parts.next().unwrap_or("");
    if parts.next().is_some() || fraction.len() > 6 || !fraction.chars().all(|c| c.is_ascii_digit())
    {
        return None;
    }
    let micros = fraction
        .chars()
        .take(6)
        .collect::<String>()
        .chars()
        .chain(std::iter::repeat('0'))
        .take(6)
        .collect::<String>()
        .parse::<i64>()
        .ok()?;
    let total = whole.checked_mul(1_000_000)?.checked_add(micros)?;
    Some(total)
}

fn href(case_id: Uuid, run_id: Uuid) -> String {
    format!("/internal/cases/{case_id}/agent-runs/{run_id}")
}

fn metric_visualization(
    _screen_id: &str,
    id: &str,
    title: &str,
    question: &str,
    value: i64,
    source_digest: &str,
    narrative: &str,
) -> Result<Value, ServiceError> {
    let rows = json!([[id, value.to_string()]]);
    let table_payload = json!({
        "caption": title,
        "headers": ["항목", "값"],
        "rows": rows,
        "dataSha256": ZERO_SHA256,
    });
    let table_digest = canonical_json_digest(&json!({
        "caption": title,
        "headers": ["항목", "값"],
        "rows": rows,
    }))?;
    let mut table = table_payload;
    table["dataSha256"] = json!(table_digest);
    // The chart and its accessible table are two renderings of one canonical
    // fact set.  Bind both to the table's normalized payload so a screen can
    // verify parity without recomputing a different digest shape.
    let data_digest = table_digest.clone();
    Ok(json!({
        "visualizationId": id,
        "kind": "METRIC",
        "title": title,
        "questionAnswered": question,
        "unit": "건",
        "asOf": format_time(OffsetDateTime::now_utc())?,
        "uncertaintyNote": Value::Null,
        "sourceDigest": source_digest,
        "dataSha256": data_digest,
        "value": value,
        "formattedValue": value.to_string(),
        "comparison": Value::Null,
        "narrativeAlternative": narrative,
        "tableAlternative": table,
    }))
}

fn visualization_set(screen_id: &str, visualizations: Vec<Value>) -> Result<Value, ServiceError> {
    let digest_input = visualizations
        .iter()
        .map(|item| {
            json!({
                "visualizationId": item.get("visualizationId").cloned().unwrap_or(Value::Null),
                "dataSha256": item.get("dataSha256").cloned().unwrap_or(Value::Null),
            })
        })
        .collect::<Vec<_>>();
    let set_digest = canonical_json_digest(&json!(digest_input))?;
    Ok(json!({
        "schemaVersion": "visualization-vm.v2",
        "screenId": screen_id,
        "visualizations": visualizations,
        "visualizationSetSha256": set_digest,
    }))
}

struct NodeInput {
    node_id: Uuid,
    node_type: &'static str,
    label: String,
    state: String,
    object_id: Uuid,
    object_version: Option<i64>,
    object_sha256: String,
    locator: Option<String>,
    occurred_at: Option<String>,
    href: Option<String>,
}

fn node(input: NodeInput) -> Value {
    json!({
        "nodeId": input.node_id,
        "nodeType": input.node_type,
        "label": input.label,
        "state": input.state,
        "objectId": input.object_id,
        "objectVersion": input.object_version,
        "objectSha256": input.object_sha256,
        "locator": input.locator,
        "occurredAt": input.occurred_at,
        "href": input.href,
    })
}

fn edge(
    from: Uuid,
    to: Uuid,
    relation: &str,
    ordinal: i64,
    run_id: Uuid,
) -> Result<Value, ServiceError> {
    let edge_id = stable_uuid(
        "analysis-edge",
        &format!("{run_id}:{from}:{to}:{relation}:{ordinal}"),
    );
    let mut value = json!({
        "edgeId": edge_id,
        "fromNodeId": from,
        "toNodeId": to,
        "relation": relation,
        "ordinal": ordinal,
        "edgeSha256": ZERO_SHA256,
    });
    let mut digest_input = value.clone();
    digest_input
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?
        .remove("edgeSha256");
    value["edgeSha256"] = json!(canonical_json_digest(&digest_input)?);
    Ok(value)
}

fn accessible_row(
    from: &Value,
    relation: &str,
    to: &Value,
    ordinal: i64,
) -> Result<Value, ServiceError> {
    let from_label = string_field(from, "label").unwrap_or_else(|| "확인되지 않음".to_owned());
    let to_label = string_field(to, "label").unwrap_or_else(|| "확인되지 않음".to_owned());
    let source_href = from.get("href").cloned().unwrap_or(Value::Null);
    let mut row = json!({
        "ordinal": ordinal,
        "fromLabel": from_label,
        "relationLabel": relation,
        "toLabel": to_label,
        "sourceHref": source_href,
        "factSha256": ZERO_SHA256,
    });
    let mut digest_input = row.clone();
    digest_input
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?
        .remove("factSha256");
    row["factSha256"] = json!(canonical_json_digest(&digest_input)?);
    Ok(row)
}

#[path = "query_analysis_detail.rs"]
mod query_analysis_detail;
#[path = "query_analysis_provenance.rs"]
mod query_analysis_provenance;
pub(super) use query_analysis_detail::attach_cas011;
pub(super) use query_analysis_provenance::provenance_graph;

fn action(action_id: &str, label: &str, kind: &str, operation_id: Option<&str>) -> Value {
    json!({
        "actionId": action_id,
        "label": label,
        "kind": kind,
        "enabled": operation_id.is_some(),
        "blockedReason": if operation_id.is_some() { Value::Null } else { json!("권한 또는 현재 상태 확인 필요") },
        "consequence": label,
        "assurance": if operation_id.is_some() { "ACTIVE_SESSION" } else { "NONE" },
        "operationId": operation_id,
    })
}
pub(super) fn cas010_projection(case_id: Uuid, items: &Value) -> Result<Value, ServiceError> {
    let runs = array_field(items, "items");
    let now = format_time(OffsetDateTime::now_utc())?;
    let summaries = runs.iter().filter_map(|run| {
        let id = uuid_field(run, "id")?;
        let status = string_field(run, "status").unwrap_or_else(|| "FAILED".to_owned());
        let proposals = run.get("suggestionCounts").cloned().unwrap_or_else(|| json!({}));
        let ledger = run.get("budgetLedger").and_then(Value::as_object);
        let settled = ledger.and_then(|value| cost_micros(value.get("settledAmount")));
        let unknown = if settled.is_none() { Value::String("COST_LEDGER_UNAVAILABLE".to_owned()) } else { Value::Null };
        Some(json!({"runId":id,"agentTypeLabel":string_field(run,"agentType").unwrap_or_else(||"Agent".to_owned()),"objective":string_field(run,"objective").unwrap_or_else(||"확인되지 않음".to_owned()),"status":status,"statusLabel":status_label(&status),"controlState":control_state(&status),"startedAt":run.get("startedAt").cloned().unwrap_or(Value::Null),"completedAt":run.get("completedAt").cloned().unwrap_or(Value::Null),"snapshotAsOf":string_field(run,"createdAt").unwrap_or_else(||now.clone()),"sourceCount":run.get("sourceUseCount").and_then(Value::as_i64).unwrap_or(0),"proposalSummary":{"pending":proposals.get("pending").and_then(Value::as_i64).unwrap_or(0),"accepted":proposals.get("accepted").and_then(Value::as_i64).unwrap_or(0),"rejected":proposals.get("rejected").and_then(Value::as_i64).unwrap_or(0),"expired":0},"costMicrosKrw":settled,"currency":"KRW","highestPriorityResult":string_field(run,"objective").unwrap_or_else(||"확인되지 않음".to_owned()),"highestPriorityUnknown":unknown,"href":href(case_id,id)}))
    }).collect::<Vec<_>>();
    let source_digest = canonical_json_digest(items)?;
    let visual = metric_visualization(
        "CAS-010",
        "run-count",
        "Agent 실행",
        "현재 케이스의 실행 건수는 얼마인가?",
        summaries.len() as i64,
        &source_digest,
        "현재 케이스에 연결된 실행만 집계했습니다.",
    )?;
    let (budget_state, budget_values) = cas010_budget(runs);
    let is_empty = summaries.is_empty();
    let (current_state, next_action) = if is_empty {
        ("아직 실행된 조사가 없습니다.", "새 조사를 시작하세요.")
    } else {
        ("실행 목록 확인 가능", "검토할 실행을 선택하세요.")
    };
    let screen_state = if is_empty { "empty" } else { "saved" };
    let mut vm = json!({"schemaVersion":"analysis-vm.cas-010.v2","screenId":"CAS-010","screenState":screen_state,"title":"Agent 실행","caseId":case_id,"tenSecond":{"objectAndScope":"현재 케이스의 Agent 실행","currentState":current_state,"mattersNow":"실행 상태와 비용을 한눈에 확인하세요.","whyTrust":"각 실행은 고정된 입력 스냅샷과 비용 요약에 연결됩니다.","unknownOrDisputed":"확인되지 않은 결과는 추정하지 않습니다.","nextAction":next_action},"freshness":{"asOf":now,"state":"CURRENT","source":"listCaseAgentRuns"},"filters":{"agentTypes":[],"statuses":[],"proposalStates":[],"sort":"NEWEST"},"runs":summaries,"budget":{"periodLabel":"현재 케이스","state":budget_state,"costLedgerState":budget_state,"values":budget_values},"primaryAction":action("start-run","새 조사 실행","COMMAND",Some("startAgentRun")),"secondaryActions":[action("open-run","실행 상세","NAVIGATION",None)],"visualizations":visualization_set("CAS-010",vec![visual])?,"supportReference":{},"viewModelSha256":ZERO_SHA256});
    let mut digest_input = vm.clone();
    digest_input
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?
        .remove("viewModelSha256");
    vm["viewModelSha256"] = json!(canonical_json_digest(&digest_input)?);
    // Preserve the complete typed analysis VM. The browser needs the
    // authority-owned identity, filters, budget and next-action fields in
    // addition to the visualization alternative; projecting only metrics
    // makes every other CAS section falsely UNKNOWN.
    Ok(vm)
}

fn cas010_budget(runs: &[Value]) -> (&'static str, Value) {
    let sum = |key: &str| {
        runs.iter()
            .filter_map(|run| budget_ledger(run).and_then(|row| cost_micros(row.get(key))))
            .try_fold(0_i64, i64::checked_add)
    };
    let limit = sum("reservedAmount");
    let settled = sum("settledAmount");
    let exposure = sum("reservedExposureAmount");
    let available = sum("availableAmount");
    let bound = !runs.is_empty()
        && runs.iter().all(|run| {
            budget_ledger(run)
                .and_then(|row| row.get("state"))
                .and_then(Value::as_str)
                .is_some_and(|state| state != "RECONCILIATION_REQUIRED")
        });
    let state = if bound && limit.is_some() && settled.is_some() {
        "AVAILABLE"
    } else {
        "BLOCKED"
    };
    let values = match (limit, settled) {
        (Some(limit), Some(settled)) => match limit.checked_sub(settled) {
            Some(remaining) => {
                json!({"limitMicrosKrw":limit,"reservedMicrosKrw":exposure,"settledMicrosKrw":settled,"remainingMicrosKrw":available.unwrap_or(remaining)})
            }
            None => {
                json!({"limitMicrosKrw":null,"reservedMicrosKrw":null,"settledMicrosKrw":null,"remainingMicrosKrw":null,"unknownReason":"COST_LEDGER_INCONSISTENT"})
            }
        },
        _ => {
            json!({"limitMicrosKrw":null,"reservedMicrosKrw":null,"settledMicrosKrw":null,"remainingMicrosKrw":null,"unknownReason":"COST_LEDGER_UNAVAILABLE"})
        }
    };
    (state, values)
}

fn budget_ledger(value: &Value) -> Option<&serde_json::Map<String, Value>> {
    value.get("budgetLedger").and_then(Value::as_object)
}

#[cfg(test)]
#[path = "query_analysis_vm_tests.rs"]
mod tests;

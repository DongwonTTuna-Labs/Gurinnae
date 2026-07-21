use super::*;

struct RunContext<'a> {
    row: &'a Value,
    run_id: Uuid,
    case_id: Uuid,
    status: String,
    snapshot: String,
    sources: &'a [Value],
    turns: &'a [Value],
    validations: &'a [Value],
    citations: &'a [Value],
}

fn build_inputs(context: &RunContext<'_>) -> Value {
    json!(context.sources.iter().filter_map(|source| {
        let id = uuid_field(source, "id")?;
        // A projection must never manufacture provenance from a source-use
        // identifier.  If the upstream artifact did not provide its content
        // digest, expose an explicit unknown value and let the UI explain the
        // missing evidence instead of presenting a plausible-looking hash.
        let content = string_field(source, "sourceContentSha256")
            .or_else(|| string_field(source, "selectedContentSha256"));
        let source_kind = string_field(source, "sourceKind").unwrap_or_else(|| "UNKNOWN".to_owned());
        Some(json!({
            "sourceUseId": id,
            "sourceKind": source_kind,
            "humanLabel": format!("{} 출처", source_kind),
            "revisionLabel": string_field(source, "sourceAssetRevision").map(|v| format!("v{v}")),
            "contentSha256": content,
            "classification": string_field(source, "classification").unwrap_or_else(|| "UNKNOWN".to_owned()),
            "rightsState": if string_field(source, "accessRight").as_deref() == Some("ALLOW") { "ALLOWED" } else { "UNKNOWN" },
            "freshnessState": string_field(source, "freshnessState").unwrap_or_else(|| "UNKNOWN".to_owned()),
            "locatorLabel": string_field(source, "locatorValue"),
            "href": format!("{}/sources/{id}", href(context.case_id, context.run_id)),
        }))
    }).collect::<Vec<_>>())
}

fn build_model(context: &RunContext<'_>, first_turn: &Value) -> Value {
    let complete = !context.turns.is_empty()
        && context
            .turns
            .iter()
            .all(|turn| string_field(turn, "status").as_deref() == Some("COMPLETED"));
    json!({
        "providerMode": string_field(first_turn, "providerMode").unwrap_or_else(|| "UNKNOWN".to_owned()),
        "providerLabel": string_field(first_turn, "provider").or_else(|| string_field(context.row, "provider")).unwrap_or_else(|| "확인되지 않음".to_owned()),
        "modelLabel": string_field(first_turn, "model").or_else(|| string_field(context.row, "model")).unwrap_or_else(|| "확인되지 않음".to_owned()),
        "promptVersion": string_field(first_turn, "promptVersion").unwrap_or_else(|| "unknown".to_owned()),
        "promptSha256": string_field(first_turn, "promptSha256").filter(|value| is_sha256(value)).map(Value::from).unwrap_or(Value::Null),
        "outputSchemaVersion": string_field(first_turn, "outputSchemaVersion").or_else(|| string_field(context.row, "outputSchemaVersion")).unwrap_or_else(|| "unknown".to_owned()),
        "outputSchemaSha256": string_field(first_turn, "outputSchemaSha256").filter(|value| is_sha256(value)).map(Value::from).unwrap_or(Value::Null),
        "routingPolicyVersion": string_field(first_turn, "routingPolicyVersion").unwrap_or_else(|| "unknown".to_owned()),
        "dataPolicyLabel": "권한·출처·개인정보 정책 적용",
        "turnCount": context.turns.len(),
        "toolCallCount": context.turns.iter().map(|turn| turn.get("toolCalls").and_then(Value::as_array).map_or(0, Vec::len)).sum::<usize>(),
        "receiptState": if context.turns.is_empty() { "NOT_DISPATCHED" } else if complete { "COMPLETE" } else { "PARTIAL" },
    })
}

fn citation_ids_for_indexes(context: &RunContext<'_>, item: &Value, keys: &[&str]) -> Value {
    let mut ids = Vec::new();
    for key in keys {
        let Some(indexes) = item.get(*key).and_then(Value::as_array) else {
            continue;
        };
        for index in indexes.iter().filter_map(Value::as_u64) {
            let Some(citation) = context.citations.get(index as usize) else {
                continue;
            };
            if let Some(id) = uuid_field(citation, "id")
                && !ids.iter().any(|existing: &Uuid| existing == &id)
            {
                ids.push(id);
            }
        }
    }
    json!(ids)
}

fn citation_ids(context: &RunContext<'_>, item: &Value) -> Value {
    if let Some(ids) = item.get("citationIds").and_then(Value::as_array) {
        let verified = ids
            .iter()
            .filter_map(Value::as_str)
            .filter_map(|value| Uuid::parse_str(value).ok())
            .filter(|id| {
                context
                    .citations
                    .iter()
                    .any(|citation| uuid_field(citation, "id") == Some(*id))
            })
            .collect::<Vec<_>>();
        return json!(verified);
    }
    citation_ids_for_indexes(
        context,
        item,
        &[
            "citationIndexes",
            "supportingCitationIndexes",
            "contradictingCitationIndexes",
        ],
    )
}

fn text_or_json(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| value.filter(|item| item.is_object()).map(Value::to_string))
}

fn project_hypotheses(context: &RunContext<'_>, output: Option<&Map<String, Value>>) -> Value {
    json!(
        output
            .and_then(|value| value.get("hypotheses"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|item| {
                let statement = text_or_json(item.get("statement"))?;
                let state = string_field(item, "state")
                    .or_else(|| string_field(item, "assessment"))
                    .unwrap_or_else(|| "UNRESOLVED".to_owned());
                let unknowns = item
                    .get("unknowns")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|unknown| text_or_json(Some(unknown)))
                    .collect::<Vec<_>>();
                Some(json!({
                    "statement": statement,
                    "state": state,
                    "citationIds": citation_ids(context, item),
                    "unknowns": unknowns,
                }))
            })
            .collect::<Vec<_>>()
    )
}

fn project_counter_evidence(
    context: &RunContext<'_>,
    output: Option<&Map<String, Value>>,
) -> Value {
    json!(output
        .and_then(|value| value.get("counterEvidence"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let summary = text_or_json(item.get("summary"))?;
            let impact = string_field(item, "impact").unwrap_or_else(|| "CONTEXT_ONLY".to_owned());
            Some(json!({"summary":summary,"citationIds":citation_ids(context,item),"impact":impact}))
        })
        .collect::<Vec<_>>())
}

fn project_unknowns(output: Option<&Map<String, Value>>) -> Value {
    json!(
        output
            .and_then(|value| value.get("unknowns"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|item| text_or_json(Some(item)))
            .collect::<Vec<_>>()
    )
}

fn project_investigations(output: Option<&Map<String, Value>>) -> Value {
    json!(
        output
            .and_then(|value| value.get("investigationsPerformed"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|item| {
                let method =
                    string_field(item, "method").or_else(|| string_field(item, "toolId"))?;
                let result =
                    string_field(item, "result").or_else(|| string_field(item, "resultSummary"))?;
                let tool_call_ids = item
                    .get("toolCallIds")
                    .filter(|value| value.is_array())
                    .cloned()
                    .unwrap_or_else(|| json!([]));
                Some(json!({"method":method,"result":result,"toolCallIds":tool_call_ids}))
            })
            .collect::<Vec<_>>()
    )
}

fn project_next_actions(context: &RunContext<'_>, output: Option<&Map<String, Value>>) -> Value {
    json!(output
        .and_then(|value| value.get("nextActions"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let label = string_field(item, "label")
                .or_else(|| string_field(item, "targetDescription"))
                .or_else(|| string_field(item, "actionType"))?;
            let reason = string_field(item, "reason").unwrap_or_else(|| "사람 검토가 필요합니다.".to_owned());
            let proposal_id = context
                .row
                .get("suggestions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find(|suggestion| {
                    let payload = suggestion.get("payload");
                    payload
                        .and_then(|value| value.get("title").or_else(|| value.get("label")))
                        .and_then(Value::as_str)
                        .is_some_and(|value| value == label)
                })
                .and_then(|suggestion| uuid_field(suggestion, "id"));
            Some(json!({
                "label": label,
                "reason": reason,
                "requiresHumanDecision": item.get("requiresHumanDecision").and_then(Value::as_bool).unwrap_or(true),
                "proposalId": proposal_id,
            }))
        })
        .collect::<Vec<_>>())
}

fn build_output(context: &RunContext<'_>, first_validation: &Value) -> Value {
    let output = context.row.get("output").and_then(Value::as_object);
    let output_status = match output
        .and_then(|value| value.get("status").or_else(|| value.get("outcome")))
        .and_then(Value::as_str)
    {
        Some(status @ ("COMPLETED" | "ABSTAINED" | "POLICY_BLOCKED" | "BUDGET_BLOCKED")) => status,
        _ if context.status == "SUCCEEDED" => "COMPLETED",
        _ => "NOT_AVAILABLE",
    };
    let output_summary = output
        .and_then(|value| {
            value
                .get("answerFirstSummary")
                .or_else(|| value.get("summary"))
        })
        .and_then(Value::as_str)
        .map(|value| json!(value))
        .unwrap_or(Value::Null);
    let policy_failure = string_field(first_validation, "failureCode");
    json!({
        "status": output_status,
        "answerFirstSummary": output_summary,
        "hypotheses": project_hypotheses(context, output),
        "counterEvidence": project_counter_evidence(context, output),
        "unknowns": project_unknowns(output),
        "investigationsPerformed": project_investigations(output),
        "nextActions": project_next_actions(context, output),
        "validation": {
            "schema": string_field(first_validation, "schemaStatus").unwrap_or_else(|| "NOT_RUN".to_owned()),
            "citations": string_field(first_validation, "citationStatus").unwrap_or_else(|| "NOT_RUN".to_owned()),
            "rights": string_field(first_validation, "policyStatus").unwrap_or_else(|| "NOT_RUN".to_owned()),
            "policy": string_field(first_validation, "policyStatus").unwrap_or_else(|| "NOT_RUN".to_owned()),
            "failureLabel": policy_failure,
            "validationSha256": string_field(first_validation, "validatedOutcomeSha256"),
        }
    })
}

fn build_safety(context: &RunContext<'_>, first_validation: &Value) -> Value {
    let flags = array_field(context.row, "safetyFlags");
    let policy_ok = matches!(
        string_field(first_validation, "policyStatus").as_deref(),
        Some("PASS" | "PASSED" | "VALID")
    );
    let prompt_injection_state = if flags
        .iter()
        .any(|flag| flag.as_str() == Some("PROMPT_INJECTION_DETECTED"))
    {
        "BLOCKED"
    } else if policy_ok {
        "CLEAR"
    } else {
        "NOT_RUN"
    };
    json!({
        "promptInjectionState": prompt_injection_state,
        "personalDataState": if policy_ok { "CLEAR" } else { "NOT_RUN" },
        "rightsState": if policy_ok { "ALLOWED" } else { "UNKNOWN" },
        "classificationState": "LOCAL_ONLY",
        "blockedReasons": flags,
    })
}

fn build_citations(context: &RunContext<'_>) -> Value {
    json!(context.citations.iter().filter_map(|citation| {
        let id = uuid_field(citation, "id")?;
        Some(json!({
            "citationId": id,
            "sourceKind": string_field(citation, "sourceKind").unwrap_or_else(|| "EVIDENCE_SEGMENT".to_owned()),
            "sourceLabel": "실행 출처",
            "locatorLabel": string_field(citation, "locatorValue").unwrap_or_else(|| "확인되지 않음".to_owned()),
            "supports": string_field(citation, "supports").unwrap_or_else(|| "확인되지 않음".to_owned()),
            "researchOnly": string_field(citation, "sourceKind").as_deref() == Some("RUN_TOOL_ARTIFACT"),
            "promotionState": "NOT_APPLICABLE",
            "href": format!("{}/citations/{id}", href(context.case_id, context.run_id)),
            "citationSha256": sha_field(citation, "citationDigest", &id.to_string()),
        }))
    }).collect::<Vec<_>>())
}

fn build_decisions(row: &Value) -> Value {
    json!(array_field(row, "suggestions").iter().filter_map(|suggestion| {
        let id = uuid_field(suggestion, "id")?;
        let payload = suggestion.get("payload").and_then(Value::as_object);
        let proposal_type = match string_field(suggestion, "type")
            .or_else(|| string_field(suggestion, "suggestionType"))
            .as_deref()
        {
            Some("HYPOTHESIS" | "CLAIM" | "TASK" | "COMPARABLE" | "COMMUNICATION") => string_field(suggestion, "type").or_else(|| string_field(suggestion, "suggestionType")).unwrap_or_else(|| "TASK".to_owned()),
            _ => "TASK".to_owned(),
        };
        let status = match string_field(suggestion, "status").as_deref() {
            Some("PENDING" | "ACCEPTED" | "REJECTED" | "SUPERSEDED" | "EXPIRED") => string_field(suggestion, "status").unwrap_or_else(|| "PENDING".to_owned()),
            _ => "PENDING".to_owned(),
        };
        Some(json!({
            "proposalId": id,
            "proposalType": proposal_type,
            "summary": payload
                .and_then(|value| value.get("title").or_else(|| value.get("label")).or_else(|| value.get("summary")))
                .and_then(Value::as_str)
                .unwrap_or("사람 검토가 필요한 Agent 제안"),
            "status": status,
            "decisionReason": suggestion.get("decisionReason").and_then(Value::as_str).map(Value::from).unwrap_or(Value::Null),
            "decidedByLabel": suggestion.get("decidedBy").and_then(Value::as_str).map(Value::from).unwrap_or(Value::Null),
            "decidedAt": suggestion.get("decidedAt").and_then(Value::as_str).map(Value::from).unwrap_or(Value::Null),
            "materializedTargetHref": Value::Null,
        }))
    }).collect::<Vec<_>>())
}

fn build_identity(context: &RunContext<'_>) -> Value {
    json!({
        "agentTypeLabel": string_field(context.row, "agentType").unwrap_or_else(|| "Agent".to_owned()),
        "objective": string_field(context.row, "objective").unwrap_or_else(|| "확인되지 않음".to_owned()),
        "status": context.status,
        "statusLabel": status_label(&context.status),
        "controlState": control_state(&context.status),
        "version": context.row.get("version").and_then(Value::as_i64).unwrap_or(1),
        "createdAt": string_field(context.row, "createdAt").map(Value::from).unwrap_or(Value::Null),
        "startedAt": context.row.get("startedAt").cloned().unwrap_or(Value::Null),
        "completedAt": context.row.get("completedAt").cloned().unwrap_or(Value::Null),
        "snapshotAsOf": string_field(context.row, "updatedAt").or_else(|| string_field(context.row, "createdAt")).map(Value::from).unwrap_or(Value::Null),
        "snapshotSha256": context.snapshot,
    })
}

fn build_view_model(context: &RunContext<'_>, graph: Value, visuals: Value) -> Value {
    let first_turn = context.turns.first().cloned().unwrap_or_else(|| json!({}));
    let first_validation = context
        .validations
        .first()
        .cloned()
        .unwrap_or_else(|| json!({}));
    let ledger = context.row.get("budgetLedger").and_then(Value::as_object);
    let actual_cost = ledger.and_then(|value| cost_micros(value.get("settledAmount")));
    let limit_cost = ledger.and_then(|value| cost_micros(value.get("reservedAmount")));
    let cost_state = ledger
        .and_then(|value| value.get("state"))
        .and_then(Value::as_str)
        .unwrap_or("RECONCILIATION_REQUIRED");
    let cost_unknown_reason = if ledger.is_none() {
        Some("COST_LEDGER_UNAVAILABLE")
    } else if cost_state == "RECONCILIATION_REQUIRED" {
        Some("COST_LEDGER_RECONCILIATION_REQUIRED")
    } else {
        None
    };
    json!({
        "schemaVersion": "analysis-vm.cas-011.v2",
        "screenId": "CAS-011",
        "screenState": screen_state(&context.status),
        "title": "Agent 실행 상세",
        "caseId": context.case_id,
        "runId": context.run_id,
        "tenSecond": {
            "objectAndScope": format!("{} · 실행 {}", string_field(context.row, "agentType").unwrap_or_else(|| "Agent".to_owned()), context.run_id),
            "currentState": status_label(&context.status),
            "mattersNow": string_field(context.row, "objective").unwrap_or_else(|| "실행 결과와 근거를 확인하세요.".to_owned()),
            "whyTrust": format!("출처 {}건, 인용 {}건, 검증 {}건이 이 실행에 묶여 있습니다.", context.sources.len(), context.citations.len(), context.validations.len()),
            "unknownOrDisputed": "확인되지 않은 내용은 결과에 포함하지 않습니다.",
            "nextAction": "근거와 제안을 검토한 뒤 필요한 사람 결정만 승인하세요.",
        },
        "identity": build_identity(context),
        "inputs": build_inputs(context),
        "model": build_model(context, &first_turn),
        "output": build_output(context, &first_validation),
        "citations": build_citations(context),
        "safety": build_safety(context, &first_validation),
        "decisions": build_decisions(context.row),
        "cost": {"currency":"KRW","limitMicrosKrw":limit_cost,"reservedMicrosKrw":ledger.and_then(|value| cost_micros(value.get("reservedExposureAmount"))),"settledMicrosKrw":actual_cost,"remainingMicrosKrw":ledger.and_then(|value| cost_micros(value.get("availableAmount"))),"state":cost_state,"unknownReason":cost_unknown_reason.map(Value::from).unwrap_or(Value::Null),"reservationId":ledger.and_then(|value| value.get("reservationId")).cloned().unwrap_or(Value::Null),"reservationDigest":ledger.and_then(|value| value.get("reservationDigest")).cloned().unwrap_or(Value::Null),"ledgerEntryCount":ledger.and_then(|value| value.get("ledgerEntryCount")).cloned().unwrap_or(Value::Null),"providerReceiptBound":ledger.and_then(|value| value.get("providerReceiptBound")).cloned().unwrap_or(Value::Bool(false)),"pricingAsOf":string_field(context.row,"updatedAt").or_else(||string_field(context.row,"createdAt")).map(Value::from).unwrap_or(Value::Null),"isEstimate":false},
        "primaryAction": action("review-output", "출력과 근거 검토", "NAVIGATION", None),
        "secondaryActions": [action("rerun", "새 버전으로 다시 실행", "COMMAND", Some("startAgentRun"))],
        "visualizations": visuals,
        "provenanceGraph": graph,
        "supportReference": {},
        "viewModelSha256": ZERO_SHA256,
    })
}

fn publish_projection(row: &mut Value, mut vm: Value) -> Result<(), ServiceError> {
    let mut digest_input = vm.clone();
    digest_input
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?
        .remove("viewModelSha256");
    vm["viewModelSha256"] = json!(canonical_json_digest(&digest_input)?);
    row.as_object_mut()
        .ok_or(ServiceError::Persistence)?
        .insert("analysisVm".to_owned(), vm);
    Ok(())
}

pub fn attach_cas011(row: &mut Value) -> Result<(), ServiceError> {
    let run_id = uuid_field(row, "id").ok_or(ServiceError::Persistence)?;
    let case_id = uuid_field(row, "caseId").ok_or(ServiceError::Persistence)?;
    let status = string_field(row, "status").unwrap_or_else(|| "FAILED".to_owned());
    let sources = array_field(row, "sourceUses");
    let turns = array_field(row, "providerTurns");
    let validations = array_field(row, "validation");
    let citations = array_field(row, "citations");
    let context = RunContext {
        row,
        run_id,
        case_id,
        status: status.clone(),
        snapshot: sha_field(row, "inputSnapshotHash", &run_id.to_string()),
        sources,
        turns,
        validations,
        citations,
    };
    let visual = metric_visualization(
        "CAS-011",
        "source-use-count",
        "분석에 사용된 출처",
        "이 실행이 확인한 출처 사용 건수는 얼마인가?",
        sources.len() as i64,
        &context.snapshot,
        "권한이 확인된 출처 사용 기록만 집계했습니다.",
    )?;
    let visuals = visualization_set("CAS-011", vec![visual])?;
    let graph = provenance_graph(run_id, case_id, row)?;
    publish_projection(row, build_view_model(&context, graph, visuals))
}

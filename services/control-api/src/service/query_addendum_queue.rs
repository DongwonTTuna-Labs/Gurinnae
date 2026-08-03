async fn addendum_queue_query(
    operation: &str,
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Option<Value>, ServiceError> {
    let query = match operation {
        "listActionApprovalQueue" => "SELECT ops.read_action_queue_v1()",
        "listResponseAppeals" => "SELECT ops.read_appeal_queue_v1()",
        "listRetentionRequests" => "SELECT ops.read_retention_queue_v1()",
        "listRecordClassSchedules" => "SELECT ops.read_record_class_schedule_queue_v1()",
        _ => return Ok(None),
    };
    let items: Value = sqlx::query_scalar(query).fetch_one(pool).await.map_err(db)?;
    let items = match operation {
        "listActionApprovalQueue" => normalize_action_queue_items(items),
        "listResponseAppeals" => normalize_appeal_queue_items(items),
        "listRetentionRequests" => normalize_retention_queue_items(items),
        "listRecordClassSchedules" => normalize_record_class_schedule_items(items),
        _ => items,
    };
    if operation == "listActionApprovalQueue" {
        let (items, next_cursor) = filter_action_queue_items(items, parameters)?;
        return action_queue_page(items, next_cursor, parameters).map(Some);
    }
    queue_page(operation, items).map(Some)
}

fn action_queue_page(items: Value, next_cursor: Option<String>, parameters: &BTreeMap<String, String>) -> Result<Value, ServiceError> {
    let total_approximate = items.as_array().map_or(0, Vec::len);
    Ok(json!({"items":items,"appliedFilters":action_queue_filters(parameters),"asOf":format_time(OffsetDateTime::now_utc())?,"nextCursor":next_cursor,"totalApproximate":total_approximate,"operationId":"listActionApprovalQueue","links":[]}))
}

fn queue_page(operation: &str, items: Value) -> Result<Value, ServiceError> {
    let as_of = format_time(OffsetDateTime::now_utc())?;
    Ok(match operation {
        "listResponseAppeals" => json!({"items":items,"appliedFilters":{"state":[],"caseId":null,"dueBefore":null,"sort":"DUE_ASC"},"asOf":as_of,"nextCursor":null,"totalApproximate":null,"operationId":operation,"links":[]}),
        "listRetentionRequests" => json!({"items":items,"appliedFilters":{"requestType":[],"state":[],"dueBefore":null,"legalHoldBlocked":null,"sort":"DUE_ASC"},"asOf":as_of,"nextCursor":null,"totalApproximate":null,"operationId":operation,"links":[]}),
        "listRecordClassSchedules" => json!({"items":items,"appliedRecordClasses":[],"appliedStates":[],"asOf":as_of,"nextCursor":null,"operationId":operation,"links":[]}),
        _ => json!({"items":items,"appliedFilters":{},"asOf":as_of,"nextCursor":null,"totalApproximate":null,"operationId":operation,"links":[]}),
    })
}

fn normalize_appeal_queue_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else { return json!([]); };
    Value::Array(rows.iter().filter_map(|row| {
        let appeal_id = row.get("id")?.clone();
        Some(json!({
            "appealId": appeal_id,
            "responseRequestId": row.get("response_request_id").cloned().unwrap_or(Value::Null),
            "caseId": row.get("case_id").cloned().unwrap_or(Value::Null),
            "decisionSequence": row.get("decision_sequence").cloned().unwrap_or_else(|| json!(0)),
            "state": row.get("state").or_else(|| row.get("initial_state")).cloned().unwrap_or_else(|| json!("RECEIVED")),
            "reasonCode": row.get("reason_code").cloned().unwrap_or_else(|| json!("OTHER")),
            "requestedOutcome": row.get("requested_outcome").cloned().unwrap_or_else(|| json!("HUMAN_REVIEW")),
            "createdAt": row.get("created_at").cloned().unwrap_or(Value::Null),
            "updatedAt": row.get("created_at").cloned().unwrap_or(Value::Null),
            "dueAt": row.get("review_due_at").cloned().unwrap_or(Value::Null)
        }))
    }).collect())
}

fn normalize_retention_queue_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else { return json!([]); };
    Value::Array(rows.iter().filter_map(|row| {
        Some(json!({
            "retentionRequestId": row.get("retention_request_id")?.clone(),
            "requestType": row.get("request_type")?.clone(),
            "decisionVersion": row.get("decision_version").cloned().unwrap_or_else(|| json!(1)),
            "state": row.get("state").cloned().unwrap_or_else(|| json!("REVIEW")),
            "jurisdiction": row.get("jurisdiction").cloned().unwrap_or_else(|| json!("UNKNOWN")),
            "scopeDigest": row.get("scope_digest").cloned().unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000")),
            "legalHoldBlocked": row.get("legal_hold_blocked").cloned().unwrap_or(json!(false)),
            // The immutable decision table has no separate due_at column;
            // expose the decision timestamp as the queue's deterministic
            // due-at witness rather than emitting a schema-invalid null.
            "dueAt": row.get("due_at").cloned().or_else(|| row.get("decided_at").cloned()).unwrap_or(Value::Null),
            "createdAt": row.get("created_at").cloned().unwrap_or(row.get("decided_at").cloned().unwrap_or(Value::Null)),
            "updatedAt": row.get("decided_at").cloned().unwrap_or(Value::Null)
        }))
    }).collect())
}

fn normalize_record_class_schedule_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else { return json!([]); };
    Value::Array(rows.iter().filter_map(|row| {
        Some(json!({
            "recordClass": row.get("record_class")?.clone(),
            "revision": row.get("revision").cloned().unwrap_or_else(|| json!(1)),
            "state": row.get("state").cloned().unwrap_or_else(|| json!("CURRENT")),
            "lawfulBasis": row.get("lawful_basis").cloned().unwrap_or_else(|| json!("UNKNOWN")),
            "activeDuration": row.get("active_duration_seconds").cloned().map(|v| json!(v.to_string())).unwrap_or_else(|| json!("indefinite")),
            "backupDuration": row.get("backup_duration_seconds").cloned().map(|v| json!(v.to_string())).unwrap_or_else(|| json!("indefinite")),
            "terminalAction": row.get("terminal_action").cloned().unwrap_or_else(|| json!("ARCHIVE")),
            "effectiveAt": row.get("effective_at").cloned().unwrap_or(Value::Null),
            "reviewExpiresAt": row.get("review_expires_at").cloned().unwrap_or(Value::Null),
            "scheduleDigest": row.get("schedule_digest").cloned().unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000"))
        }))
    }).collect())
}

fn action_queue_filters(parameters: &BTreeMap<String, String>) -> Value {
    let values = |name: &str| {
        parameters
            .get(name)
            .map(|value| {
                value
                    .split(',')
                    .filter(|item| !item.is_empty())
                    .map(Value::from)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };
    json!({
        "actionKind": values("actionKind"),
        "proposalState": values("proposalState"),
        "assignmentState": values("assignmentState"),
        "dueBefore": parameters.get("dueBefore"),
        "sort": parameters.get("sort").map(String::as_str).unwrap_or("UPDATED_DESC")
    })
}

fn filter_action_queue_items(value: Value, parameters: &BTreeMap<String, String>) -> Result<(Value, Option<String>), ServiceError> {
    let mut rows = value.as_array().cloned().unwrap_or_default();
    let matches_any = |parameter: &str, actual: Option<&str>| {
        parameters.get(parameter).is_none_or(|expected| {
            expected.split(',').filter(|item| !item.is_empty()).any(|item| Some(item) == actual)
        })
    };
    rows.retain(|row| {
        let proposal = row.get("proposal");
        let action_kind = proposal.and_then(|item| item.get("actionKind")).and_then(Value::as_str);
        let proposal_state = proposal.and_then(|item| item.get("state")).and_then(Value::as_str);
        let assignment_state = row.get("assignment").and_then(|item| item.get("state")).and_then(Value::as_str);
        let due_before = parameters.get("dueBefore");
        let due_at = row.get("dueAt").and_then(Value::as_str);
        let due_matches = match (due_before, due_at) {
            (None, _) => true,
            (Some(limit), Some(actual)) => {
                let format = time::format_description::well_known::Rfc3339;
                match (
                    time::OffsetDateTime::parse(limit, &format),
                    time::OffsetDateTime::parse(actual, &format),
                ) {
                    (Ok(limit), Ok(actual)) => actual <= limit,
                    _ => false,
                }
            }
            _ => false,
        };
        matches_any("actionKind", action_kind)
            && matches_any("proposalState", proposal_state)
            && matches_any("assignmentState", assignment_state)
            && due_matches
    });
    if parameters.get("sort").is_some_and(|sort| sort == "DUE_ASC") {
        rows.sort_by_key(|row| row.get("dueAt").and_then(Value::as_str).unwrap_or("").to_owned());
    } else {
        rows.sort_by_key(|row| std::cmp::Reverse(row.get("proposal").and_then(|item| item.get("updatedAt")).and_then(Value::as_str).unwrap_or("").to_owned()));
    }
    let cursor_digest = canonical_json_digest(&json!({"rows":rows,"filters":action_queue_filters(parameters)}))?;
    let offset = match parameters.get("cursor") {
        None => 0,
        Some(cursor) => {
            let (raw_offset, digest) = cursor.split_once(':').ok_or(ServiceError::InvalidRequest)?;
            if digest != cursor_digest { return Err(ServiceError::InvalidRequest); }
            raw_offset.parse::<usize>().map_err(|_| ServiceError::InvalidRequest)?
        }
    };
    let limit = parameters.get("limit").and_then(|value| value.parse::<usize>().ok()).unwrap_or(rows.len());
    let next = (offset.saturating_add(limit) < rows.len()).then(|| format!("{}:{}", offset + limit, cursor_digest));
    let paged = rows.into_iter().skip(offset).take(limit).collect::<Vec<_>>();
    Ok((Value::Array(paged), next))
}

fn normalize_action_queue_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else { return json!([]); };
    Value::Array(rows.iter().map(normalize_action_queue_item).collect())
}

fn normalize_action_queue_item(row: &Value) -> Value {
    let id = row.get("proposalId").cloned().unwrap_or(Value::Null);
    let digest = |key: &str| normalized_digest(row, key);
    json!({
        "proposal": {
            "proposalId": id,
            "version": row.get("version").cloned().unwrap_or_else(|| json!(1)),
            "actionKind": row.get("actionKind").cloned().unwrap_or_else(|| json!("TASK")),
            "state": row.get("state").cloned().unwrap_or_else(|| json!("DRAFT")),
            "contentDigest": digest("contentDigest"),
            "approvalDigest": digest("approvalDigest"),
            "target": {"targetType": row.get("targetType").cloned().unwrap_or_else(|| json!("CASE")), "targetId": row.get("targetId").cloned().unwrap_or(Value::Null), "expectedVersion": row.get("targetVersion").cloned().unwrap_or_else(|| json!(1))},
            "creator": {"actorType": "HUMAN", "actorId": row.get("createdBy").cloned().unwrap_or(Value::Null), "displayName": "검토 담당자"},
            "lastEditor": {"actorType": "HUMAN", "actorId": row.get("createdBy").cloned().unwrap_or(Value::Null), "displayName": "검토 담당자"},
            "createdAt": row.get("createdAt").cloned().unwrap_or(Value::Null),
            "updatedAt": row.get("updatedAt").cloned().unwrap_or(Value::Null),
            "expiresAt": row.get("expiresAt").cloned().unwrap_or(Value::Null)
        },
        "assignment": normalize_action_assignment(row),
        "quorum": {
            "planDigest": digest("quorumPlanDigest"),
            "requiredSlots": row.get("requiredSlots").cloned().unwrap_or_else(|| json!([])),
            "satisfiedSlots": row.get("satisfiedSlots").cloned().unwrap_or_else(|| json!([])),
            "blockingSlots": row.get("blockingSlots").cloned().unwrap_or_else(|| json!([])),
            "conflictSnapshotDigest": digest("conflictSnapshotDigest"),
            "complete": row.get("blockingSlots").and_then(Value::as_array).is_some_and(|slots| slots.is_empty())
        },
        "dueAt": row.get("dueAt").cloned().or_else(|| row.get("expiresAt").cloned()).unwrap_or(Value::Null),
        "riskClass": normalized_risk_class(row),
        "href": format!("/internal/action-proposals/{}", id.as_str().unwrap_or("unknown"))
    })
}

fn normalized_digest(row: &Value, key: &str) -> Value {
    row.get(key).and_then(Value::as_str).filter(|value| is_sha256(value)).map(Value::from)
        .unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000"))
}

fn normalize_action_assignment(row: &Value) -> Value {
    let Some(raw) = row.get("assignment").and_then(Value::as_object) else { return Value::Null; };
    let approval_digest = raw.get("approvalDigest").or_else(|| row.get("approvalDigest"))
        .and_then(Value::as_str).filter(|value| is_sha256(value)).map(Value::from)
        .unwrap_or_else(|| normalized_digest(row, "approvalDigest"));
    let reviewer = raw.get("reviewer").cloned().or_else(|| raw.get("reviewerId").map(|actor_id| json!({"actorType":"HUMAN","actorId":actor_id,"displayName":"Assigned reviewer"}))).unwrap_or(Value::Null);
    json!({
        "assignmentId": raw.get("assignmentId").cloned().unwrap_or(Value::Null),
        "version": raw.get("version").or_else(|| raw.get("assignmentVersion")).cloned().unwrap_or_else(|| json!(1)),
        "assignmentGeneration": raw.get("assignmentGeneration").cloned().unwrap_or_else(|| json!(1)),
        "slotKind": raw.get("slotKind").cloned().unwrap_or_else(|| json!("primary")),
        "requiredCapability": raw.get("requiredCapability").cloned().unwrap_or_else(|| json!("actions.review")),
        "reviewer": reviewer,
        "state": raw.get("state").cloned().unwrap_or_else(|| json!("VACANT")),
        "dueAt": raw.get("dueAt").cloned().unwrap_or(Value::Null),
        "approvalDigest": approval_digest
    })
}

fn normalized_risk_class(row: &Value) -> Value {
    row.get("riskClass").and_then(Value::as_str)
        .filter(|value| matches!(*value, "LOW" | "MEDIUM" | "HIGH" | "CRITICAL"))
        .map(Value::from).unwrap_or_else(|| json!("MEDIUM"))
}

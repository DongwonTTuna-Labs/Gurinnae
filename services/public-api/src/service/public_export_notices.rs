struct ExportEnvelopeNotices {
    non_conclusion_notices: Vec<String>,
    interpretation_notice: Option<&'static str>,
}

#[derive(Clone, Copy)]
enum NonConclusionRowPolicy {
    Required,
    Nullable,
}

fn export_envelope_notices(
    stem: &str,
    rows: &[Value],
) -> Result<ExportEnvelopeNotices, ServiceError> {
    match stem {
        "public-cases" => Ok(ExportEnvelopeNotices {
            non_conclusion_notices: non_conclusion_notices(rows, NonConclusionRowPolicy::Required)?,
            interpretation_notice: None,
        }),
        "contracts" => {
            ensure_contract_interpretation_notices(rows)?;
            Ok(ExportEnvelopeNotices {
                non_conclusion_notices: Vec::new(),
                interpretation_notice: Some(OPERATIONAL_INTERPRETATION_NOTICE),
            })
        }
        "public-search-records" => Ok(ExportEnvelopeNotices {
            non_conclusion_notices: non_conclusion_notices(rows, NonConclusionRowPolicy::Nullable)?,
            interpretation_notice: search_interpretation_notice(rows)?,
        }),
        _ => Err(ServiceError::Persistence),
    }
}

fn non_conclusion_notices(
    rows: &[Value],
    policy: NonConclusionRowPolicy,
) -> Result<Vec<String>, ServiceError> {
    let mut notices = Vec::new();
    let mut seen = BTreeSet::new();
    for row in rows {
        let value = match row.get("nonConclusion") {
            Some(Value::String(value)) if !value.trim().is_empty() => value.trim(),
            Some(Value::Null) if matches!(policy, NonConclusionRowPolicy::Nullable) => continue,
            _ => return Err(ServiceError::Persistence),
        };
        if seen.insert(value) {
            notices.push(value.to_owned());
        }
    }
    Ok(notices)
}

fn ensure_contract_interpretation_notices(rows: &[Value]) -> Result<(), ServiceError> {
    if rows.iter().all(|row| {
        row.get("interpretationNotice").and_then(Value::as_str)
            == Some(OPERATIONAL_INTERPRETATION_NOTICE)
    }) {
        Ok(())
    } else {
        Err(ServiceError::Persistence)
    }
}

fn search_interpretation_notice(rows: &[Value]) -> Result<Option<&'static str>, ServiceError> {
    let mut operational_notice_present = false;
    for row in rows {
        match row.get("interpretationNotice") {
            None | Some(Value::Null) => {}
            Some(Value::String(value)) if value == OPERATIONAL_INTERPRETATION_NOTICE => {
                operational_notice_present = true;
            }
            Some(_) => return Err(ServiceError::Persistence),
        }
    }
    Ok(operational_notice_present.then_some(OPERATIONAL_INTERPRETATION_NOTICE))
}

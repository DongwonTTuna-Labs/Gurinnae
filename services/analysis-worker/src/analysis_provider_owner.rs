#[allow(clippy::too_many_arguments)]
async fn complete_provider_turn_owner<'a, E>(
    executor: E,
    turn: &ProviderTurnIdentity,
    expected_version: i64,
    status: &str,
    envelope_kind: Option<&str>,
    envelope_sha256: Option<&str>,
    envelope_payload_sha256: Option<&str>,
    envelope_canonical: Option<&[u8]>,
    response_redacted: Option<&Value>,
    response_redacted_canonical: Option<&[u8]>,
    call_id: Option<&str>,
    tool_id: Option<&str>,
    receipt_id: Uuid,
    receipt: &Value,
    receipt_canonical: &[u8],
    receipt_sha256: &str,
    provider_turn_canonical: &[u8],
    provider_turn_sha256: &str,
    turn_transcript_sha256: Option<&str>,
    input_units: Option<i64>,
    output_units: Option<i64>,
    provider_request_id_hash: Option<&str>,
    cost_krw: Option<i64>,
    error_code: Option<&str>,
    error_sha256: Option<&str>,
) -> Result<(), Failure>
where
    E: sqlx::Executor<'a, Database = sqlx::Postgres>,
{
    sqlx::query!(
        "SELECT ops.complete_agent_provider_turn(
           $1,$2,$3,$4,CAST($5 AS char(64)),CAST($6 AS char(64)),$7,$8,$9,$10,$11,$12,$13,$14,
           CAST($15 AS char(64)),$16,CAST($17 AS char(64)),CAST($18 AS char(64)),$19,$20,
           CAST($21 AS char(64)),$22,$23,CAST($24 AS char(64)))",
        turn.turn_id,
        expected_version,
        status,
        envelope_kind,
        envelope_sha256,
        envelope_payload_sha256,
        envelope_canonical,
        response_redacted,
        response_redacted_canonical,
        call_id,
        tool_id,
        receipt_id,
        receipt,
        receipt_canonical,
        receipt_sha256,
        provider_turn_canonical,
        provider_turn_sha256,
        turn_transcript_sha256,
        input_units,
        output_units,
        provider_request_id_hash,
        cost_krw,
        error_code,
        error_sha256,
    )
    .fetch_one(executor)
    .await
    .map_err(database)?;
    Ok(())
}

fn unresolved_provider_outcome(detail: impl Into<String>) -> Failure {
    // No authenticated response means there is no honest proof, usage,
    // pricing, policy, or rights tuple from which ProviderReceiptV2 can be
    // built. Keep the durable turn DISPATCHED and let the agent-run
    // reconciliation marker carry the uncertainty. A terminal worker failure
    // prevents an automatic re-dispatch of a request that may have arrived.
    Failure::Terminal("PROVIDER_OUTCOME_UNKNOWN", detail.into())
}

#[cfg(test)]
mod provider_outcome_unknown_tests {
    use super::*;

    #[test]
    fn unresolved_outcome_stays_terminal_without_synthetic_receipt_material() {
        assert!(matches!(
            unresolved_provider_outcome("send result unavailable"),
            Failure::Terminal("PROVIDER_OUTCOME_UNKNOWN", detail)
                if detail == "send result unavailable"
        ));
    }
}

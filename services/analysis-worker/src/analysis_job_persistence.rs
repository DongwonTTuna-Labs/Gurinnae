async fn persist_agent_suggestion(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    context: &AgentContext,
    output: &Value,
) -> Result<(), Failure> {
    if output
        .get("status")
        .or_else(|| output.get("outcome"))
        .and_then(Value::as_str)
        != Some("COMPLETED")
    {
        return Ok(());
    }
    sqlx::query!(
        "INSERT INTO ops.agent_suggestions(agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status)          VALUES($1,$2,$3,$4,$5,$6,'PENDING')",
        context.run_id,
        context.case_id,
        context.agent_type.to_uppercase().replace('-', "_"),
        output,
        json!(context.allowed_ids),
        output.get("citations").cloned().unwrap_or_else(|| json!([])),
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

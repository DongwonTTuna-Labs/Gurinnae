use super::*;

#[expect(
    clippy::too_many_arguments,
    reason = "relay translation binds response proof, policy, pricing, evidence, and agent schema"
)]
pub(super) async fn provider_response_body(
    context: &ProviderResponseContext<'_>,
    response: ProviderDispatchResponse,
    relay_data_policy: Option<&RelayDataPolicy>,
    pricing: &LocalPricing,
    evidence: &Value,
    maximum_cost_krw: i64,
    agent_type: &str,
) -> Result<Value, Failure> {
    if context.provider != RELAY_PROVIDER {
        return match response.response.json().await {
            Ok(body) => Ok(body),
            Err(error) => context
                .reject_unresolved("provider response is not JSON", error.to_string())
                .await,
        };
    }
    let Some(data_policy) = relay_data_policy else {
        return Err(Failure::Terminal(
            "PROVIDER_DATA_POLICY_UNCONFIGURED",
            context.provider.to_owned(),
        ));
    };
    let observation = match observe_relay_gateway_response(
        response.response,
        &response.request_sha256,
    )
    .await
    {
        Ok(value) => value,
        Err(error) => {
            return context
                .reject_unresolved("relay response proof invalid", failure_detail(&error))
                .await;
        }
    };
    match relay_internal_response(
        observation,
        context.model,
        agent_type,
        context.turn,
        context.run_id,
        context.provider_config_id,
        context.semantic_request_sha256,
        pricing,
        data_policy,
        evidence,
        maximum_cost_krw,
    ) {
        Ok(body) => Ok(body),
        Err(error) => context
            .reject_unresolved("relay response shape invalid", failure_detail(&error))
            .await,
    }
}

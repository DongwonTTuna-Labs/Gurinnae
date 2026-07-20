use super::dispatch::allowed_tools;
use super::*;
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub call_id: Uuid,
    pub request: ToolRequest,
    pub request_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolResult {
    pub call_id: Uuid,
    pub response: ToolResponse,
    pub response_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Citation {
    pub source_use_id: Uuid,
    pub selected_content_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentFinalOutput {
    pub status: FinalStatus,
    pub summary: String,
    pub citations: Vec<Citation>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum FinalStatus {
    Completed,
    Abstained,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ProviderEnvelope {
    ToolCall(ToolCall),
    FinalOutput(AgentFinalOutput),
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderTurn {
    pub turn: u16,
    pub prior_transcript_sha256: String,
    pub request_sha256: String,
    pub idempotency_key: String,
    pub envelope: ProviderEnvelope,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderReceipt {
    pub idempotency_key: String,
    pub request_sha256: String,
    pub outcome: ProviderOutcome,
    pub cost_micros_krw: u64,
    pub receipt_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ProviderOutcome {
    ToolCallAccepted,
    FinalAccepted,
    Rejected,
    OutcomeUnknown,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderRequest {
    pub run_id: Uuid,
    pub agent_id: String,
    pub turn: u16,
    pub prior_transcript_sha256: String,
    pub idempotency_key: String,
    pub semantic_request_sha256: String,
    pub max_cost_micros_krw: u64,
    pub prior_tool_result: Option<ToolResult>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderReply {
    pub envelope: ProviderEnvelope,
    pub receipt: ProviderReceipt,
}

pub fn provider_request_sha256(request: &ProviderRequest) -> Result<String, RuntimeError> {
    digest_without_digest(request)
}

pub fn provider_receipt_sha256(receipt: &ProviderReceipt) -> Result<String, RuntimeError> {
    let mut projection = receipt.clone();
    projection.receipt_sha256.clear();
    digest_without_digest(&projection)
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ProviderRuntimeError {
    #[error("provider unavailable")]
    Unavailable,
    #[error("provider receipt is invalid")]
    InvalidReceipt,
    #[error("provider outcome is unknown and needs reconciliation")]
    OutcomeUnknown,
}

pub trait ProviderAdapter: Send + Sync {
    fn complete(&self, request: &ProviderRequest) -> Result<ProviderReply, ProviderRuntimeError>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MultiTurnConfig {
    pub max_provider_turns: u16,
    pub max_tool_calls: u16,
    pub budget_micros_krw: u64,
    pub worst_case_turn_cost_micros_krw: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum RunOutcome {
    Succeeded {
        output: AgentFinalOutput,
        transcript: Transcript,
    },
    Abstained {
        output: AgentFinalOutput,
        transcript: Transcript,
    },
    BudgetBlocked {
        transcript: Transcript,
    },
    ReconciliationRequired {
        transcript: Transcript,
    },
}

pub struct MultiTurnRuntime<P> {
    pub provider: P,
    pub tools: TypedDispatcher,
}
impl<P: ProviderAdapter> MultiTurnRuntime<P> {
    pub fn run(
        &self,
        agent_id: &str,
        run_id: Uuid,
        initial_transcript_sha256: String,
        semantic_request_sha256: String,
        config: MultiTurnConfig,
    ) -> Result<RunOutcome, RuntimeError> {
        validate_run_inputs(agent_id, &semantic_request_sha256, &config)?;
        let mut transcript = Transcript::new(initial_transcript_sha256)?;
        let mut spent = 0_u64;
        let mut tool_calls = 0_u16;
        let mut prior_tool_result: Option<ToolResult> = None;
        for turn_number in 1..=config.max_provider_turns {
            if spent >= config.budget_micros_krw {
                return Ok(RunOutcome::BudgetBlocked { transcript });
            }
            let remaining = config.budget_micros_krw.saturating_sub(spent);
            if remaining < config.worst_case_turn_cost_micros_krw {
                return Ok(RunOutcome::BudgetBlocked { transcript });
            }
            let idempotency_key = format!("{}:{}:{}", run_id, turn_number, semantic_request_sha256);
            let request = ProviderRequest {
                run_id,
                agent_id: agent_id.to_owned(),
                turn: turn_number,
                prior_transcript_sha256: transcript.digest.clone(),
                idempotency_key: idempotency_key.clone(),
                semantic_request_sha256: semantic_request_sha256.clone(),
                max_cost_micros_krw: remaining,
                prior_tool_result: prior_tool_result.clone(),
            };
            let request_hash = provider_request_sha256(&request)?;
            let reply = match self.provider.complete(&request) {
                Ok(value) => value,
                Err(ProviderRuntimeError::OutcomeUnknown) => {
                    return Ok(RunOutcome::ReconciliationRequired { transcript });
                }
                Err(ProviderRuntimeError::Unavailable) => {
                    return Err(RuntimeError::ProviderUnavailable);
                }
                Err(ProviderRuntimeError::InvalidReceipt) => {
                    return Err(RuntimeError::InvalidProviderReceipt);
                }
            };
            validate_reply(&reply, &idempotency_key, &request_hash, remaining)?;
            if matches!(reply.receipt.outcome, ProviderOutcome::OutcomeUnknown) {
                return Ok(RunOutcome::ReconciliationRequired { transcript });
            }
            spent = spent.saturating_add(reply.receipt.cost_micros_krw);
            let provider_turn = ProviderTurn {
                turn: turn_number,
                prior_transcript_sha256: request.prior_transcript_sha256,
                request_sha256: request_hash,
                idempotency_key,
                envelope: reply.envelope.clone(),
            };
            transcript.append(provider_turn)?;
            match reply.envelope {
                ProviderEnvelope::FinalOutput(output) => {
                    return Ok(final_outcome(output, transcript));
                }
                ProviderEnvelope::ToolCall(call) => {
                    tool_calls = tool_calls
                        .checked_add(1)
                        .ok_or(RuntimeError::InvalidTransition)?;
                    if tool_calls > config.max_tool_calls {
                        return Err(RuntimeError::ToolLimitExceeded);
                    }
                    if call.request.binding().run_id != run_id {
                        return Err(RuntimeError::ToolDenied);
                    }
                    let response = self
                        .tools
                        .dispatch(agent_id, &call.request)
                        .map_err(|_| RuntimeError::ToolDenied)?;
                    let response_sha256 = digest_without_digest(&response)?;
                    prior_tool_result = Some(ToolResult {
                        call_id: call.call_id,
                        response,
                        response_sha256,
                    });
                }
            }
        }
        Ok(RunOutcome::Abstained {
            output: AgentFinalOutput {
                status: FinalStatus::Abstained,
                summary: "ITERATION_LIMIT_REACHED".to_owned(),
                citations: Vec::new(),
            },
            transcript,
        })
    }
}

fn final_outcome(output: AgentFinalOutput, transcript: Transcript) -> RunOutcome {
    match output.status {
        FinalStatus::Completed => RunOutcome::Succeeded { output, transcript },
        FinalStatus::Abstained => RunOutcome::Abstained { output, transcript },
    }
}

fn validate_reply(
    reply: &ProviderReply,
    idempotency_key: &str,
    request_hash: &str,
    remaining: u64,
) -> Result<(), RuntimeError> {
    let receipt = &reply.receipt;
    if receipt.idempotency_key != idempotency_key
        || receipt.request_sha256 != request_hash
        || receipt.cost_micros_krw > remaining
        || provider_receipt_sha256(receipt)? != receipt.receipt_sha256
    {
        return Err(RuntimeError::InvalidProviderReceipt);
    }
    Ok(())
}

fn validate_run_inputs(
    agent_id: &str,
    semantic_request_sha256: &str,
    config: &MultiTurnConfig,
) -> Result<(), RuntimeError> {
    if allowed_tools(agent_id).is_none()
        || config.max_provider_turns == 0
        || config.max_tool_calls > config.max_provider_turns
    {
        return Err(RuntimeError::InvalidTransition);
    }
    if !is_sha256(semantic_request_sha256) {
        return Err(RuntimeError::InvalidDigest);
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Transcript {
    pub initial_sha256: String,
    pub turns: Vec<ProviderTurn>,
    pub digest: String,
}
impl Transcript {
    pub fn new(initial_sha256: String) -> Result<Self, RuntimeError> {
        if !is_sha256(&initial_sha256) {
            return Err(RuntimeError::InvalidDigest);
        }
        let mut value = Self {
            initial_sha256,
            turns: Vec::new(),
            digest: String::new(),
        };
        value.digest = digest_without_digest(&value)?;
        Ok(value)
    }
    pub fn append(&mut self, turn: ProviderTurn) -> Result<(), RuntimeError> {
        let expected_turn = match u16::try_from(self.turns.len())
            .ok()
            .and_then(|value| value.checked_add(1))
        {
            Some(value) => value,
            None => return Err(RuntimeError::TranscriptConflict),
        };
        if turn.turn != expected_turn || turn.prior_transcript_sha256 != self.digest {
            return Err(RuntimeError::TranscriptConflict);
        }
        if !is_sha256(&turn.request_sha256) || turn.idempotency_key.is_empty() {
            return Err(RuntimeError::InvalidDigest);
        }
        self.turns.push(turn);
        self.digest = digest_without_digest(self)?;
        Ok(())
    }
}

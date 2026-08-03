use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

mod commands;
mod queries;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    AcceptAgentSuggestion,
    RejectAgentSuggestion,
    StartAgentRun,
    CreateActionProposal,
    UpdateActionDraft,
    PreviewActionDraft,
    SubmitActionForReview,
    ClaimActionReview,
    SubmitActionDecision,
    CancelActionExecution,
    RetryActionExecution,
    WithdrawActionProposal,
    WithdrawActionDecision,
    CancelAgentRun,
    ReconcileAgentRun,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetAgentRun,
    ListCaseAgentRuns,
    ListActionApprovalQueue,
    GetActionProposal,
    GetActionExecutionReceipt,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "acceptAgentSuggestion",
        Handler::Command(CommandHandler::Agents(Command::AcceptAgentSuggestion)),
    ),
    (
        "getAgentRun",
        Handler::Query(QueryHandler::Agents(Query::GetAgentRun)),
    ),
    (
        "listCaseAgentRuns",
        Handler::Query(QueryHandler::Agents(Query::ListCaseAgentRuns)),
    ),
    (
        "rejectAgentSuggestion",
        Handler::Command(CommandHandler::Agents(Command::RejectAgentSuggestion)),
    ),
    (
        "startAgentRun",
        Handler::Command(CommandHandler::Agents(Command::StartAgentRun)),
    ),
    (
        "listActionApprovalQueue",
        Handler::Query(QueryHandler::Agents(Query::ListActionApprovalQueue)),
    ),
    (
        "createActionProposal",
        Handler::Command(CommandHandler::Agents(Command::CreateActionProposal)),
    ),
    (
        "getActionProposal",
        Handler::Query(QueryHandler::Agents(Query::GetActionProposal)),
    ),
    (
        "updateActionDraft",
        Handler::Command(CommandHandler::Agents(Command::UpdateActionDraft)),
    ),
    (
        "previewActionDraft",
        Handler::Command(CommandHandler::Agents(Command::PreviewActionDraft)),
    ),
    (
        "submitActionForReview",
        Handler::Command(CommandHandler::Agents(Command::SubmitActionForReview)),
    ),
    (
        "claimActionReview",
        Handler::Command(CommandHandler::Agents(Command::ClaimActionReview)),
    ),
    (
        "submitActionDecision",
        Handler::Command(CommandHandler::Agents(Command::SubmitActionDecision)),
    ),
    (
        "getActionExecutionReceipt",
        Handler::Query(QueryHandler::Agents(Query::GetActionExecutionReceipt)),
    ),
    (
        "cancelActionExecution",
        Handler::Command(CommandHandler::Agents(Command::CancelActionExecution)),
    ),
    (
        "retryActionExecution",
        Handler::Command(CommandHandler::Agents(Command::RetryActionExecution)),
    ),
    (
        "withdrawActionProposal",
        Handler::Command(CommandHandler::Agents(Command::WithdrawActionProposal)),
    ),
    (
        "withdrawActionDecision",
        Handler::Command(CommandHandler::Agents(Command::WithdrawActionDecision)),
    ),
    (
        "cancelAgentRun",
        Handler::Command(CommandHandler::Agents(Command::CancelAgentRun)),
    ),
    (
        "reconcileAgentRun",
        Handler::Command(CommandHandler::Agents(Command::ReconcileAgentRun)),
    ),
];

pub(super) const fn command_kind(command: Command) -> CommandKind {
    match command {
        Command::AcceptAgentSuggestion
        | Command::RejectAgentSuggestion
        | Command::StartAgentRun => CommandKind::Base,
        Command::CreateActionProposal
        | Command::UpdateActionDraft
        | Command::PreviewActionDraft
        | Command::SubmitActionForReview
        | Command::ClaimActionReview
        | Command::SubmitActionDecision
        | Command::CancelActionExecution
        | Command::RetryActionExecution
        | Command::WithdrawActionProposal
        | Command::WithdrawActionDecision
        | Command::CancelAgentRun => CommandKind::Addendum,
        Command::ReconcileAgentRun => CommandKind::Private,
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "agent commands preserve the existing transaction-bound handler contract"
)]
pub(super) async fn apply(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::AcceptAgentSuggestion | Command::RejectAgentSuggestion => {
            commands::arm_acceptagentsuggestion_rejectagentsuggestion(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::StartAgentRun => {
            commands::arm_startagentrun(operation, payload, id, actor, session_id, field_keys, tx)
                .await
        }
        Command::CreateActionProposal
        | Command::UpdateActionDraft
        | Command::PreviewActionDraft
        | Command::SubmitActionForReview
        | Command::ClaimActionReview
        | Command::SubmitActionDecision
        | Command::CancelActionExecution
        | Command::RetryActionExecution
        | Command::WithdrawActionProposal
        | Command::WithdrawActionDecision
        | Command::CancelAgentRun
        | Command::ReconcileAgentRun => Err(ServiceError::InvalidRequest),
    }
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetAgentRun => queries::query_agent_run(parameters, pool).await,
        Query::ListCaseAgentRuns => queries::list_case_agent_runs(parameters, pool).await,
        Query::ListActionApprovalQueue => {
            queries::list_action_approval_queue(parameters, pool).await
        }
        Query::GetActionProposal => queries::get_action_proposal(parameters, pool).await,
        Query::GetActionExecutionReceipt => {
            queries::get_action_execution_receipt(parameters, pool).await
        }
    }
}

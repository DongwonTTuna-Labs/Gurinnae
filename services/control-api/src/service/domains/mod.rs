use super::*;
use crate::service::registry::{CommandHandler, QueryHandler};

pub(super) mod agents;
pub(super) mod audit_retention;
pub(super) mod cases;
pub(super) mod claims_evidence;
pub(super) mod editorial;
pub(super) mod identity_governance;
pub(super) mod operations;
pub(super) mod resilience_cost;
pub(super) mod rules;
pub(super) mod signals;
pub(super) mod sources;
pub(super) mod work_management;

pub(super) use agents::{Command as AgentsCommand, Query as AgentsQuery};
pub(super) use audit_retention::{Command as AuditRetentionCommand, Query as AuditRetentionQuery};
pub(super) use cases::{Command as CasesCommand, Query as CasesQuery};
pub(super) use claims_evidence::{Command as ClaimsEvidenceCommand, Query as ClaimsEvidenceQuery};
pub(super) use editorial::{Command as EditorialCommand, Query as EditorialQuery};
pub(super) use identity_governance::{
    Command as IdentityGovernanceCommand, Query as IdentityGovernanceQuery,
};
pub(super) use operations::{Command as OperationsCommand, Query as OperationsQuery};
pub(super) use resilience_cost::{Command as ResilienceCostCommand, Query as ResilienceCostQuery};
pub(super) use rules::{Command as RulesCommand, Query as RulesQuery};
pub(super) use signals::{Command as SignalsCommand, Query as SignalsQuery};
pub(super) use sources::{Command as SourcesCommand, Query as SourcesQuery};
pub(super) use work_management::{Command as WorkManagementCommand, Query as WorkManagementQuery};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum CommandKind {
    Base,
    Addendum,
    Private,
}

pub(super) const OPERATION_TABLES: &[&[(&str, crate::service::registry::Handler)]] = &[
    agents::OPERATIONS,
    cases::OPERATIONS,
    signals::OPERATIONS,
    claims_evidence::OPERATIONS,
    editorial::OPERATIONS,
    rules::OPERATIONS,
    sources::OPERATIONS,
    operations::OPERATIONS,
    identity_governance::OPERATIONS,
    audit_retention::OPERATIONS,
    resilience_cost::OPERATIONS,
    work_management::OPERATIONS,
];

pub(super) fn command_kind(handler: CommandHandler) -> CommandKind {
    match handler {
        CommandHandler::Agents(command) => agents::command_kind(command),
        CommandHandler::Cases(command) => cases::command_kind(command),
        CommandHandler::Signals(command) => signals::command_kind(command),
        CommandHandler::ClaimsEvidence(command) => claims_evidence::command_kind(command),
        CommandHandler::Editorial(command) => editorial::command_kind(command),
        CommandHandler::Rules(command) => rules::command_kind(command),
        CommandHandler::Sources(command) => sources::command_kind(command),
        CommandHandler::Operations(command) => operations::command_kind(command),
        CommandHandler::IdentityGovernance(command) => identity_governance::command_kind(command),
        CommandHandler::AuditRetention(command) => audit_retention::command_kind(command),
        CommandHandler::ResilienceCost(command) => resilience_cost::command_kind(command),
        CommandHandler::WorkManagement(command) => work_management::command_kind(command),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "domain command dispatch preserves the existing transaction-bound handler contract"
)]
pub(super) async fn apply_command(
    handler: CommandHandler,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Map<String, Value>, ServiceError> {
    match handler {
        CommandHandler::Agents(command) => {
            let result = agents::apply(
                command,
                operation,
                payload,
                id,
                actor,
                session_id,
                field_keys,
                transaction,
            )
            .await;
            no_command_effect(result)
        }
        CommandHandler::Cases(command) => {
            no_command_effect(cases::apply(command, payload, actor, transaction).await)
        }
        CommandHandler::Signals(command) => {
            no_command_effect(signals::apply(command, payload, id, actor, transaction).await)
        }
        CommandHandler::ClaimsEvidence(command) => no_command_effect(
            claims_evidence::apply(command, payload, id, actor, field_keys, transaction).await,
        ),
        CommandHandler::Editorial(command) => {
            let result = editorial::apply(
                command,
                operation,
                payload,
                id,
                actor,
                session_id,
                field_keys,
                transaction,
            )
            .await;
            no_command_effect(result)
        }
        CommandHandler::Rules(command) => no_command_effect(
            rules::apply(command, operation, payload, id, actor, transaction).await,
        ),
        CommandHandler::Sources(command) => no_command_effect(
            sources::apply(command, operation, payload, id, actor, transaction).await,
        ),
        CommandHandler::Operations(command) => {
            operations::apply(command, operation, payload, id, actor, transaction).await
        }
        CommandHandler::IdentityGovernance(command) => {
            let result = identity_governance::apply(
                command,
                operation,
                payload,
                id,
                actor,
                session_id,
                transaction,
            )
            .await;
            no_command_effect(result)
        }
        CommandHandler::AuditRetention(command) => no_command_effect(
            audit_retention::apply(command, payload, id, actor, transaction).await,
        ),
        CommandHandler::ResilienceCost(command) => no_command_effect(
            resilience_cost::apply(command, payload, id, actor, transaction).await,
        ),
        CommandHandler::WorkManagement(command) => no_command_effect(
            work_management::apply(command, payload, id, actor, transaction).await,
        ),
    }
}

fn no_command_effect(result: Result<(), ServiceError>) -> Result<Map<String, Value>, ServiceError> {
    result?;
    Ok(Map::new())
}

pub(super) async fn query(
    handler: QueryHandler,
    operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match handler {
        QueryHandler::Agents(query) => {
            agents::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::Cases(query) => {
            cases::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::Signals(query) => {
            signals::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::ClaimsEvidence(query) => {
            claims_evidence::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::Editorial(query) => {
            editorial::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::Rules(query) => {
            rules::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::Sources(query) => {
            sources::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::Operations(query) => {
            operations::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::IdentityGovernance(query) => {
            identity_governance::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::AuditRetention(query) => {
            audit_retention::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::ResilienceCost(query) => {
            resilience_cost::query(query, operation, parameters, claims, pool).await
        }
        QueryHandler::WorkManagement(query) => {
            work_management::query(query, operation, parameters, claims, pool).await
        }
    }
}

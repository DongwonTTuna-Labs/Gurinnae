use std::{collections::BTreeMap, sync::OnceLock};

use super::{ServiceError, domains};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Handler {
    Command(CommandHandler),
    Query(QueryHandler),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum CommandHandler {
    Agents(domains::AgentsCommand),
    Cases(domains::CasesCommand),
    Signals(domains::SignalsCommand),
    ClaimsEvidence(domains::ClaimsEvidenceCommand),
    Editorial(domains::EditorialCommand),
    Rules(domains::RulesCommand),
    Sources(domains::SourcesCommand),
    Operations(domains::OperationsCommand),
    IdentityGovernance(domains::IdentityGovernanceCommand),
    AuditRetention(domains::AuditRetentionCommand),
    ResilienceCost(domains::ResilienceCostCommand),
    WorkManagement(domains::WorkManagementCommand),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum QueryHandler {
    Agents(domains::AgentsQuery),
    Cases(domains::CasesQuery),
    Signals(domains::SignalsQuery),
    ClaimsEvidence(domains::ClaimsEvidenceQuery),
    Editorial(domains::EditorialQuery),
    Rules(domains::RulesQuery),
    Sources(domains::SourcesQuery),
    Operations(domains::OperationsQuery),
    IdentityGovernance(domains::IdentityGovernanceQuery),
    AuditRetention(domains::AuditRetentionQuery),
    ResilienceCost(domains::ResilienceCostQuery),
    WorkManagement(domains::WorkManagementQuery),
}

static REGISTRY: OnceLock<Result<BTreeMap<&'static str, Handler>, ()>> = OnceLock::new();

fn registry() -> Result<&'static BTreeMap<&'static str, Handler>, ServiceError> {
    REGISTRY
        .get_or_init(|| {
            let mut registry = BTreeMap::new();
            for &(operation_id, handler) in domains::OPERATION_TABLES
                .iter()
                .flat_map(|table| table.iter())
            {
                if registry.insert(operation_id, handler).is_some() {
                    return Err(());
                }
            }
            Ok(registry)
        })
        .as_ref()
        .map_err(|_| ServiceError::Persistence)
}

pub(super) fn lookup(operation_id: &str) -> Result<Handler, ServiceError> {
    registry()?
        .get(operation_id)
        .copied()
        .ok_or(ServiceError::InvalidRequest)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use gurine_api_contracts::{addendum, control_api};

    use super::*;

    #[test]
    fn registry_is_exactly_the_routed_control_operation_catalog() {
        let mut registry_ids = BTreeSet::new();
        let mut duplicate_ids = BTreeSet::new();
        for &(operation_id, _) in domains::OPERATION_TABLES
            .iter()
            .flat_map(|table| table.iter())
        {
            if !registry_ids.insert(operation_id) {
                duplicate_ids.insert(operation_id);
            }
        }

        let catalog = control_api::OPERATIONS
            .iter()
            .chain(addendum::CONTROL_OPERATIONS.iter())
            .chain(addendum::PRIVATE_CONTROL_OPERATIONS.iter());
        let catalog_ids: BTreeSet<_> = catalog.clone().map(|operation| operation.id).collect();
        let catalog_duplicates = catalog
            .fold(BTreeMap::new(), |mut counts, operation| {
                *counts.entry(operation.id).or_insert(0_usize) += 1;
                counts
            })
            .into_iter()
            .filter_map(|(operation_id, count)| (count > 1).then_some(operation_id))
            .collect::<BTreeSet<_>>();

        assert!(
            duplicate_ids.is_empty(),
            "duplicate registry IDs: {duplicate_ids:?}"
        );
        assert!(
            catalog_duplicates.is_empty(),
            "duplicate catalog IDs: {catalog_duplicates:?}"
        );
        assert_eq!(registry_ids, catalog_ids);
        assert_eq!(registry_ids.len(), 168);
    }

    #[test]
    fn registry_command_query_kinds_match_the_catalog() -> Result<(), ServiceError> {
        for operation in control_api::OPERATIONS
            .iter()
            .chain(addendum::CONTROL_OPERATIONS.iter())
            .chain(addendum::PRIVATE_CONTROL_OPERATIONS.iter())
        {
            let handler = lookup(operation.id)?;
            assert_eq!(
                matches!(handler, Handler::Query(_)),
                operation.operation_kind == "QUERY",
                "operation kind mismatch for {}",
                operation.id
            );
        }
        Ok(())
    }
}

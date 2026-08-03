use super::*;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
pub(super) enum EconomicsImportActionKind {
    #[serde(rename = "ECONOMICS_IMPORT")]
    EconomicsImport,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
enum ActionPayloadSchemaVersion {
    #[serde(rename = "action-payload.v1")]
    V1,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsImportTarget {
    target_type: String,
    target_id: String,
    expected_version: RequiredNullable<i64>,
}

impl EconomicsImportTarget {
    fn validate(&self) -> Result<(), ServiceError> {
        if self.target_type != ECONOMICS_IMPORT_ACTION_KIND
            || self.target_id.is_empty()
            || self.target_id.len() > 200
            || self.expected_version.is_some_and(|version| version < 1)
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsImportRationale {
    summary: String,
    evidence_segment_ids: Vec<Uuid>,
    unknowns: Vec<String>,
    alternatives_considered: Vec<String>,
    risk_note: String,
}

impl EconomicsImportRationale {
    fn validate(&self) -> Result<(), ServiceError> {
        let evidence_is_sorted_unique = self
            .evidence_segment_ids
            .windows(2)
            .all(|pair| pair[0] < pair[1]);
        if !(1..=4_000).contains(&self.summary.len())
            || !(1..=1_000).contains(&self.evidence_segment_ids.len())
            || self.evidence_segment_ids.iter().any(Uuid::is_nil)
            || !evidence_is_sorted_unique
            || self.unknowns.len() > 50
            || self
                .unknowns
                .iter()
                .any(|value| value.is_empty() || value.len() > 2_000)
            || self.alternatives_considered.len() > 20
            || self
                .alternatives_considered
                .iter()
                .any(|value| value.is_empty() || value.len() > 2_000)
            || !(1..=4_000).contains(&self.risk_note.len())
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
enum EconomicsImportEffectClass {
    #[serde(rename = "INTERNAL_MATERIALIZATION")]
    InternalMaterialization,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
enum EconomicsImportAggregate {
    #[serde(rename = "ECONOMICS_IMPORT")]
    EconomicsImport,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
enum EconomicsImportSourceState {
    #[serde(rename = "UNRECORDED")]
    Unrecorded,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
pub(super) enum EconomicsImportDisposition {
    #[serde(rename = "RECORDED")]
    Recorded,
    #[serde(rename = "REPLACED")]
    Replaced,
    #[serde(rename = "REVERSED")]
    Reversed,
    #[serde(rename = "REVIEW_TASK_CREATED")]
    ReviewTaskCreated,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsImportFromState {
    aggregate: EconomicsImportAggregate,
    state: EconomicsImportSourceState,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsImportToState {
    aggregate: EconomicsImportAggregate,
    state: EconomicsImportDisposition,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsImportEffect {
    effect_class: EconomicsImportEffectClass,
    from_state: RequiredNullable<EconomicsImportFromState>,
    to_state: EconomicsImportToState,
    external_side_effect: bool,
    reversible: bool,
    expected_outcome: String,
}

impl EconomicsImportEffect {
    fn validate(&self, operation: &EconomicsImportOperationV1) -> Result<(), ServiceError> {
        let exact_from_state = self.from_state.as_option().as_ref().is_some_and(|state| {
            state.aggregate == EconomicsImportAggregate::EconomicsImport
                && state.state == EconomicsImportSourceState::Unrecorded
        });
        let exact_to_aggregate =
            self.to_state.aggregate == EconomicsImportAggregate::EconomicsImport;
        if self.effect_class != EconomicsImportEffectClass::InternalMaterialization
            || !exact_from_state
            || !exact_to_aggregate
            || self.external_side_effect
            || !operation.allows_disposition(self.to_state.state)
            || !(1..=4_000).contains(&self.expected_outcome.len())
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _reviewed_reversibility = self.reversible;
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct EconomicsImportDraftScaffold {
    schema_version: ActionPayloadSchemaVersion,
    kind: EconomicsImportActionKind,
    target: EconomicsImportTarget,
    rationale: EconomicsImportRationale,
    effect: EconomicsImportEffect,
    operation: EconomicsImportOperationV1,
    source_evidence_digests: Vec<Sha256Digest>,
    import_policy_digest: Sha256Digest,
    as_of: DateTimeText,
}

impl EconomicsImportDraftScaffold {
    pub(super) fn validate(&self) -> Result<(), ServiceError> {
        self.target.validate()?;
        self.rationale.validate()?;
        self.effect.validate(&self.operation)?;
        self.operation.validate()?;
        // The public digest array is a canonical distinct set. The database
        // locks the ID set, derives ID-ordered positional pairs, and compares
        // their distinct digest set before persisting those derived pairs.
        if self.source_evidence_digests.is_empty()
            || self.source_evidence_digests.len() > self.rationale.evidence_segment_ids.len()
            || self
                .source_evidence_digests
                .windows(2)
                .any(|pair| pair[0] >= pair[1])
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _closed_bindings = (
            self.schema_version,
            self.kind,
            &self.import_policy_digest,
            self.as_of.as_str(),
        );
        Ok(())
    }

    pub(super) const fn operation(&self) -> &EconomicsImportOperationV1 {
        &self.operation
    }
}

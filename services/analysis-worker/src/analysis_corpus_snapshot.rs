use super::{Failure, ProviderTurnIdentity, database, required};
use gurine_agent_orchestration::runtime::{
    AgencyProfileRecord, ContractCorpusRecord, RelationshipKind, RelationshipNeighborRecord,
    SupplierIdentityStatus, SupplierProfileRecord,
};
use serde_json::Value;
use sqlx::{Postgres, Transaction};
use std::collections::BTreeMap;
use uuid::Uuid;

pub(super) struct CorpusSnapshot {
    pub contracts: Vec<ContractCorpusRecord>,
    pub supplier_profiles: Vec<SupplierProfileRecord>,
    pub agency_profiles: Vec<AgencyProfileRecord>,
    pub relationships: Vec<RelationshipNeighborRecord>,
}

pub(super) async fn load(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    dataset_snapshot_id: Uuid,
) -> Result<CorpusSnapshot, Failure> {
    let rows = sqlx::query!(
        "SELECT m.object_type,m.object_id,m.canonical_payload,m.id AS snapshot_member_id,
                btrim(m.member_digest::text) AS snapshot_member_digest,
                su.source_use_id AS \"source_use_id?: Uuid\"
           FROM core.dataset_snapshot_members m
           LEFT JOIN LATERAL (
             SELECT s.source_use_id FROM ops.agent_source_uses s
              WHERE s.agent_run_id=$2 AND s.use_kind='TOOL_QUERY'
                AND s.source_kind='DATASET_MEMBER'
                AND s.dataset_snapshot_id=m.dataset_snapshot_id
                AND s.snapshot_member_id=m.id
                AND s.snapshot_member_digest=m.member_digest
              ORDER BY s.source_use_id LIMIT 1
           ) su ON true
          WHERE m.dataset_snapshot_id=$1
            AND m.object_type IN ('CONTRACT','SUPPLIER','AGENCY')
          ORDER BY m.member_ordinal,m.id",
        dataset_snapshot_id,
        turn.run_id,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?;

    let mut contracts = Vec::new();
    let mut suppliers = Vec::new();
    let mut agencies = Vec::new();
    for row in rows {
        let member_digest = required(row.snapshot_member_digest).map_err(database)?;
        match row.object_type.as_str() {
            "CONTRACT" => contracts.push(contract_record(
                row.object_id,
                row.snapshot_member_id,
                member_digest,
                required(row.source_use_id).map_err(database)?,
                &row.canonical_payload,
            )?),
            "SUPPLIER" => suppliers.push(supplier_record(
                row.object_id,
                row.snapshot_member_id,
                member_digest,
                required(row.source_use_id).map_err(database)?,
                &row.canonical_payload,
            )?),
            "AGENCY" => agencies.push(agency_record(
                row.object_id,
                row.snapshot_member_id,
                member_digest,
                required(row.source_use_id).map_err(database)?,
                &row.canonical_payload,
            )?),
            _ => {
                return Err(Failure::Terminal(
                    "AGENT_CORPUS_SNAPSHOT_INVALID",
                    row.object_type,
                ));
            }
        }
    }
    apply_contract_counts(&contracts, &mut suppliers, &mut agencies)?;
    let relationships = load_relationships(executor, turn, dataset_snapshot_id).await?;
    Ok(CorpusSnapshot {
        contracts,
        supplier_profiles: suppliers,
        agency_profiles: agencies,
        relationships,
    })
}

fn contract_record(
    contract_id: Uuid,
    member_id: Uuid,
    member_digest: String,
    source_use_id: Uuid,
    payload: &Value,
) -> Result<ContractCorpusRecord, Failure> {
    Ok(ContractCorpusRecord {
        contract_id,
        title: string(payload, "title")?,
        agency_id: uuid(payload, "agencyId")?,
        supplier_id: optional_uuid(payload, "supplierId")?,
        status: string(payload, "status")?,
        procurement_method: optional_string(payload, "procurementMethod")?,
        signed_at: optional_string(payload, "signedAt")?,
        currency: string(payload, "currency")?,
        amount: scalar_string(payload, "currentAmount")
            .or_else(|| scalar_string(payload, "originalAmount")),
        snapshot_member_id: member_id,
        snapshot_member_digest: member_digest,
        source_use_id,
    })
}

fn supplier_record(
    supplier_id: Uuid,
    member_id: Uuid,
    member_digest: String,
    source_use_id: Uuid,
    payload: &Value,
) -> Result<SupplierProfileRecord, Failure> {
    Ok(SupplierProfileRecord {
        supplier_id,
        canonical_name: string(payload, "canonicalName")?,
        business_status: optional_string(payload, "businessStatus")?,
        identity_status: supplier_identity_status(payload)?,
        contract_count: 0,
        snapshot_member_id: member_id,
        snapshot_member_digest: member_digest,
        source_use_id,
    })
}

fn supplier_identity_status(value: &Value) -> Result<SupplierIdentityStatus, Failure> {
    match string(value, "identityStatus")?.as_str() {
        "UNVERIFIED" => Ok(SupplierIdentityStatus::Unverified),
        "CANDIDATE" => Ok(SupplierIdentityStatus::Candidate),
        "VERIFIED" => Ok(SupplierIdentityStatus::Verified),
        "AMBIGUOUS" => Ok(SupplierIdentityStatus::Ambiguous),
        "CONFLICTED" => Ok(SupplierIdentityStatus::Conflicted),
        "REJECTED" => Ok(SupplierIdentityStatus::Rejected),
        _ => Err(invalid("identityStatus")),
    }
}

fn agency_record(
    agency_id: Uuid,
    member_id: Uuid,
    member_digest: String,
    source_use_id: Uuid,
    payload: &Value,
) -> Result<AgencyProfileRecord, Failure> {
    Ok(AgencyProfileRecord {
        agency_id,
        canonical_name: string(payload, "canonicalName")?,
        agency_type: string(payload, "agencyType")?,
        jurisdiction: optional_string(payload, "jurisdiction")?,
        active: payload
            .get("active")
            .and_then(Value::as_bool)
            .ok_or_else(|| invalid("active"))?,
        contract_count: 0,
        snapshot_member_id: member_id,
        snapshot_member_digest: member_digest,
        source_use_id,
    })
}

fn apply_contract_counts(
    contracts: &[ContractCorpusRecord],
    suppliers: &mut [SupplierProfileRecord],
    agencies: &mut [AgencyProfileRecord],
) -> Result<(), Failure> {
    let mut supplier_counts = BTreeMap::<Uuid, usize>::new();
    let mut agency_counts = BTreeMap::<Uuid, usize>::new();
    for contract in contracts {
        *agency_counts.entry(contract.agency_id).or_default() += 1;
        if let Some(id) = contract.supplier_id {
            *supplier_counts.entry(id).or_default() += 1;
        }
    }
    for supplier in suppliers {
        supplier.contract_count = u32::try_from(
            supplier_counts
                .get(&supplier.supplier_id)
                .copied()
                .unwrap_or_default(),
        )
        .map_err(|_| invalid("supplier.contractCount"))?;
    }
    for agency in agencies {
        agency.contract_count = u32::try_from(
            agency_counts
                .get(&agency.agency_id)
                .copied()
                .unwrap_or_default(),
        )
        .map_err(|_| invalid("agency.contractCount"))?;
    }
    Ok(())
}

async fn load_relationships(
    executor: &mut Transaction<'_, Postgres>,
    turn: &ProviderTurnIdentity,
    dataset_snapshot_id: Uuid,
) -> Result<Vec<RelationshipNeighborRecord>, Failure> {
    sqlx::query!(
        "WITH cutoff AS (
           SELECT ready_at FROM core.dataset_snapshots
            WHERE id=$1 AND state='READY'
         ), latest AS (
           SELECT DISTINCT ON (a.assertion_id)
             a.assertion_id,a.assertion_revision,a.assertion_digest,a.relationship_kind,
             a.subject_candidate_id,a.subject_candidate_revision,a.subject_candidate_digest,
             a.object_candidate_id,a.object_candidate_revision,a.object_candidate_digest,
             a.valid_from::text AS valid_from,a.valid_to::text AS valid_to,
             a.evidence_set_digest,a.verification_status,a.public_use_status,
             a.verified_by,a.verified_at,a.verification_reason_digest
           FROM core.supplier_relationship_assertions a CROSS JOIN cutoff c
          WHERE a.created_at<=c.ready_at
          ORDER BY a.assertion_id,a.assertion_revision DESC
         )
         SELECT a.assertion_id,a.assertion_revision,btrim(a.assertion_digest::text) assertion_digest,
                a.relationship_kind,subject.canonical_supplier_id AS subject_supplier_id,
                object.canonical_supplier_id AS object_supplier_id,a.valid_from,a.valid_to,
                btrim(a.evidence_set_digest::text) evidence_set_digest,
                subject_use.source_use_id AS \"subject_source_use_id?: Uuid\",
                object_use.source_use_id AS \"object_source_use_id?: Uuid\"
           FROM latest a
           JOIN core.supplier_identity_candidates subject
             ON subject.candidate_id=a.subject_candidate_id
            AND subject.candidate_revision=a.subject_candidate_revision
            AND subject.candidate_digest=a.subject_candidate_digest
            AND subject.canonical_supplier_id IS NOT NULL
           JOIN core.supplier_identity_candidates object
             ON object.candidate_id=a.object_candidate_id
            AND object.candidate_revision=a.object_candidate_revision
            AND object.candidate_digest=a.object_candidate_digest
            AND object.canonical_supplier_id IS NOT NULL
           JOIN core.dataset_snapshot_members subject_member
             ON subject_member.dataset_snapshot_id=$1
            AND subject_member.object_type='SUPPLIER'
            AND subject_member.object_id=subject.canonical_supplier_id
           JOIN core.dataset_snapshot_members object_member
             ON object_member.dataset_snapshot_id=$1
            AND object_member.object_type='SUPPLIER'
            AND object_member.object_id=object.canonical_supplier_id
           LEFT JOIN LATERAL (
             SELECT s.source_use_id FROM ops.agent_source_uses s
              WHERE s.agent_run_id=$2 AND s.use_kind='TOOL_QUERY'
                AND s.source_kind='DATASET_MEMBER' AND s.dataset_snapshot_id=$1
                AND s.snapshot_member_id=subject_member.id
                AND s.snapshot_member_digest=subject_member.member_digest
              ORDER BY s.source_use_id LIMIT 1
           ) subject_use ON true
           LEFT JOIN LATERAL (
             SELECT s.source_use_id FROM ops.agent_source_uses s
              WHERE s.agent_run_id=$2 AND s.use_kind='TOOL_QUERY'
                AND s.source_kind='DATASET_MEMBER' AND s.dataset_snapshot_id=$1
                AND s.snapshot_member_id=object_member.id
                AND s.snapshot_member_digest=object_member.member_digest
              ORDER BY s.source_use_id LIMIT 1
           ) object_use ON true
          WHERE a.verification_status='VERIFIED' AND a.public_use_status='APPROVED'
            AND a.verified_by IS NOT NULL AND a.verified_at IS NOT NULL
            AND a.verification_reason_digest IS NOT NULL
          ORDER BY a.relationship_kind,subject.canonical_supplier_id,
                   object.canonical_supplier_id,a.assertion_id,a.assertion_revision",
        dataset_snapshot_id,
        turn.run_id,
    )
    .fetch_all(&mut **executor)
    .await
    .map_err(database)?
    .into_iter()
    .map(|row| {
        Ok(RelationshipNeighborRecord {
            subject_supplier_id: required(row.subject_supplier_id).map_err(database)?,
            object_supplier_id: required(row.object_supplier_id).map_err(database)?,
            relationship_kind: relationship_kind(&row.relationship_kind)?,
            assertion_id: row.assertion_id,
            assertion_revision: u64::try_from(row.assertion_revision)
                .map_err(|_| invalid("assertionRevision"))?,
            assertion_digest: required(row.assertion_digest).map_err(database)?,
            valid_from: row.valid_from,
            valid_to: row.valid_to,
            evidence_set_digest: required(row.evidence_set_digest).map_err(database)?,
            subject_source_use_id: required(row.subject_source_use_id).map_err(database)?,
            object_source_use_id: required(row.object_source_use_id).map_err(database)?,
        })
    })
    .collect()
}

fn relationship_kind(value: &str) -> Result<RelationshipKind, Failure> {
    match value {
        "OWNERSHIP" => Ok(RelationshipKind::Ownership),
        "BENEFICIAL_OWNERSHIP" => Ok(RelationshipKind::BeneficialOwnership),
        "CONTROL" => Ok(RelationshipKind::Control),
        "MANAGEMENT_ROLE" => Ok(RelationshipKind::ManagementRole),
        "LEGAL_REPRESENTATIVE" => Ok(RelationshipKind::LegalRepresentative),
        "CONTRACTUAL_RELATIONSHIP" => Ok(RelationshipKind::ContractualRelationship),
        _ => Err(invalid("relationshipKind")),
    }
}

fn string(value: &Value, key: &str) -> Result<String, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| invalid(key))
}

fn optional_string(value: &Value, key: &str) -> Result<Option<String>, Failure> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) if !text.trim().is_empty() => Ok(Some(text.clone())),
        _ => Err(invalid(key)),
    }
}

fn uuid(value: &Value, key: &str) -> Result<Uuid, Failure> {
    Uuid::parse_str(&string(value, key)?).map_err(|_| invalid(key))
}

fn optional_uuid(value: &Value, key: &str) -> Result<Option<Uuid>, Failure> {
    optional_string(value, key)?
        .map(|text| Uuid::parse_str(&text).map_err(|_| invalid(key)))
        .transpose()
}

fn scalar_string(value: &Value, key: &str) -> Option<String> {
    match value.get(key) {
        Some(Value::String(text)) if !text.is_empty() => Some(text.clone()),
        Some(Value::Number(number)) => Some(number.to_string()),
        _ => None,
    }
}

fn invalid(field: &str) -> Failure {
    Failure::Terminal("AGENT_CORPUS_SNAPSHOT_INVALID", field.to_owned())
}

use serde_json::Value;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{Failure, database};

pub(super) fn agency_id_from_payload(payload: &Value) -> Option<Uuid> {
    payload
        .get("agencyId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
}

pub(super) async fn upsert_public_agency(
    tx: &mut Transaction<'_, Postgres>,
    agency_id: Uuid,
) -> Result<(), Failure> {
    sqlx::query!(
        "SELECT 1 AS \"locked!\" FROM pg_catalog.pg_advisory_xact_lock(\
         pg_catalog.hashtextextended(($1::uuid)::text,0))",
        agency_id,
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query!(
        r#"
        WITH linked_cases AS MATERIALIZED (
          SELECT
            public_case.id,
            public_case.public_state::text AS publication_state,
            public_case.published_at,
            public_case.updated_at,
            editorial_case.investigation_state::text AS investigation_state,
            editorial_case.resolution_code::text AS resolution_code
          FROM public.cases AS public_case
          JOIN public.case_revisions AS revision
            ON revision.case_id = public_case.id
           AND revision.revision = public_case.latest_revision
          JOIN editorial.cases AS editorial_case ON editorial_case.id = public_case.id
          WHERE revision.payload ->> 'agencyId' = ($1::uuid)::text
        ), rollup AS (
          SELECT
            count(*)::bigint AS total,
            min(published_at)::date AS first_published,
            max(published_at)::date AS last_published,
            max(updated_at) AS last_updated,
            count(*) FILTER (WHERE publication_state = 'NEVER_PUBLISHED')::bigint AS never_published,
            count(*) FILTER (WHERE publication_state = 'PUBLISHED_ANOMALY')::bigint AS published_anomaly,
            count(*) FILTER (WHERE publication_state = 'PUBLISHED_EXPLAINED')::bigint AS published_explained,
            count(*) FILTER (WHERE publication_state = 'OFFICIALLY_CONFIRMED')::bigint AS officially_confirmed,
            count(*) FILTER (WHERE publication_state = 'CORRECTED')::bigint AS corrected,
            count(*) FILTER (WHERE publication_state = 'RETRACTED')::bigint AS retracted,
            count(*) FILTER (WHERE publication_state = 'TEMPORARILY_RESTRICTED')::bigint AS temporarily_restricted,
            count(*) FILTER (WHERE investigation_state = 'SIGNAL_DETECTED')::bigint AS signal_detected,
            count(*) FILTER (WHERE investigation_state = 'TRIAGE')::bigint AS triage,
            count(*) FILTER (WHERE investigation_state = 'INVESTIGATING')::bigint AS investigating,
            count(*) FILTER (WHERE investigation_state = 'AWAITING_RESPONSE')::bigint AS awaiting_response,
            count(*) FILTER (WHERE investigation_state = 'EDITORIAL_REVIEW')::bigint AS editorial_review,
            count(*) FILTER (WHERE investigation_state = 'LEGAL_REVIEW')::bigint AS legal_review,
            count(*) FILTER (WHERE investigation_state = 'READY_TO_PUBLISH')::bigint AS ready_to_publish,
            count(*) FILTER (WHERE investigation_state = 'CLOSED')::bigint AS closed,
            count(*) FILTER (WHERE resolution_code = 'NONE')::bigint AS resolution_none,
            count(*) FILTER (WHERE resolution_code = 'DATA_ERROR')::bigint AS data_error,
            count(*) FILTER (WHERE resolution_code = 'DUPLICATE')::bigint AS duplicate,
            count(*) FILTER (WHERE resolution_code = 'EXPLAINED')::bigint AS explained,
            count(*) FILTER (WHERE resolution_code = 'INSUFFICIENT_EVIDENCE')::bigint AS insufficient_evidence,
            count(*) FILTER (WHERE resolution_code = 'REFERRED_CONFIDENTIAL')::bigint AS referred_confidential,
            count(*) FILTER (WHERE resolution_code = 'ARCHIVED')::bigint AS archived
          FROM linked_cases
        )
        INSERT INTO public.agencies (
          id, name, agency_type, jurisdiction,
          sido_code, sigungu_code, region_code_version,
          coverage, descriptive_metrics, case_counts, updated_at
        )
        SELECT
          agency.id,
          agency.canonical_name,
          agency.agency_type,
          agency.jurisdiction,
          agency.sido_code,
          agency.sigungu_code,
          agency.region_code_version,
          jsonb_build_object(
            'dateRange', jsonb_build_object(
              'from', rollup.first_published,
              'to', rollup.last_published,
              'label', '공개 사건 게시 기간'
            ),
            'sourceIds', '[]'::jsonb,
            'recordCount', rollup.total,
            'knownGaps', '[]'::jsonb,
            'freshness', jsonb_build_object(
              'asOf', coalesce(rollup.last_updated, clock_timestamp()),
              'status', 'UNKNOWN'
            )
          ),
          '[]'::jsonb,
          jsonb_build_object(
            'total', rollup.total,
            'publication', jsonb_build_object(
              'neverPublished', rollup.never_published,
              'publishedAnomaly', rollup.published_anomaly,
              'publishedExplained', rollup.published_explained,
              'officiallyConfirmed', rollup.officially_confirmed,
              'corrected', rollup.corrected,
              'retracted', rollup.retracted,
              'temporarilyRestricted', rollup.temporarily_restricted
            ),
            'investigation', jsonb_build_object(
              'signalDetected', rollup.signal_detected,
              'triage', rollup.triage,
              'investigating', rollup.investigating,
              'awaitingResponse', rollup.awaiting_response,
              'editorialReview', rollup.editorial_review,
              'legalReview', rollup.legal_review,
              'readyToPublish', rollup.ready_to_publish,
              'closed', rollup.closed
            ),
            'resolution', jsonb_build_object(
              'none', rollup.resolution_none,
              'dataError', rollup.data_error,
              'duplicate', rollup.duplicate,
              'explained', rollup.explained,
              'insufficientEvidence', rollup.insufficient_evidence,
              'referredConfidential', rollup.referred_confidential,
              'archived', rollup.archived
            )
          ),
          clock_timestamp()
        FROM core.agencies AS agency
        CROSS JOIN rollup
        WHERE agency.id = $1::uuid
        ON CONFLICT (id) DO UPDATE SET
          name = EXCLUDED.name,
          agency_type = EXCLUDED.agency_type,
          jurisdiction = EXCLUDED.jurisdiction,
          sido_code = EXCLUDED.sido_code,
          sigungu_code = EXCLUDED.sigungu_code,
          region_code_version = EXCLUDED.region_code_version,
          coverage = EXCLUDED.coverage,
          descriptive_metrics = EXCLUDED.descriptive_metrics,
          case_counts = EXCLUDED.case_counts,
          updated_at = EXCLUDED.updated_at
        "#,
        agency_id,
    )
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

use std::collections::BTreeMap;

use actix_web::HttpRequest;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use rust_decimal::Decimal;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row, postgres::PgRow};
use thiserror::Error;
use time::{Date, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::state::AppState;

const PUBLIC_OPENAPI: &str = include_str!("../../../../specs/generated/public-api.openapi.json");

pub struct Output {
    pub status: u16,
    pub media_type: &'static str,
    pub body: Value,
}

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("request parameters are invalid")]
    InvalidRequest,
    #[error("public record was not found")]
    NotFound,
    #[error("public projection is unavailable")]
    Persistence,
}

pub async fn execute(
    operation: &str,
    request: &HttpRequest,
    state: &AppState,
) -> Result<Output, ServiceError> {
    let query = Query::parse(request)?;
    let body = match operation {
        "downloadPublicOpenApi" => {
            serde_json::from_str(PUBLIC_OPENAPI).map_err(|_| ServiceError::Persistence)?
        }
        "getAboutContent" => content(
            "about",
            "구린네 소개",
            "공공조달 기록의 근거와 한계를 함께 공개하는 독립 검증 서비스입니다.",
            &["근거 우선", "인간 승인", "정정과 철회 이력 보존"],
        ),
        "getAccessibilityStatement" => content(
            "accessibility",
            "접근성 선언",
            "WCAG 2.2 AA를 기준으로 키보드, 보조기술, 확대와 고대비 사용을 지원합니다.",
            &["접근성 오류 신고", "대체 형식 요청", "지속적 수동 검수"],
        ),
        "getPublicApiDocumentation" => content(
            "api",
            "공개 API 안내",
            "공개 projection만 제공하며 cursor pagination과 안정적인 revision URL을 사용합니다.",
            &["OpenAPI 문서", "요청 제한", "출처와 freshness 필드"],
        ),
        "getContactContent" => content(
            "contact",
            "문의 안내",
            "일반 문의와 정정 요청을 분리하여 접수하며 민감정보는 최소화합니다.",
            &["일반 문의", "정정 요청", "보안 신고"],
        ),
        "getEditorialPolicy" => content(
            "editorial-policy",
            "편집 정책",
            "확인된 사실, 핵심 미확인 사항, 당사자 소명과 반대 근거를 구분합니다.",
            &["독립 검토", "무응답은 인정이 아님", "revision 고정 근거"],
        ),
        "getFundingContent" => content(
            "funding",
            "재원 공개",
            "후원과 비용 지원은 편집 판단 및 분석 규칙에 영향을 주지 않습니다.",
            &["이해충돌 공개", "후원자 비개입", "연간 투명성 보고"],
        ),
        "getGovernanceContent" => content(
            "governance",
            "거버넌스",
            "역할 분리와 고위험 작업의 단계 인증, 감사 추적을 운영 원칙으로 둡니다.",
            &["권한 최소화", "고위험 이중 검토", "감사 이벤트 불변성"],
        ),
        "getMethodologyOverview" => content(
            "methodology",
            "방법론",
            "규칙 버전, 입력 digest, 포함·제외 cohort와 계산 한계를 함께 공개합니다.",
            &["결정적 계산", "재현 payload", "사람의 최종 판단"],
        ),
        "getPrivacyPolicy" => content(
            "privacy",
            "개인정보 처리방침",
            "제출 경로의 개인정보는 필드 단위 암호화하고 목적 달성 후 보존 정책에 따라 삭제합니다.",
            &["최소 수집", "접근 통제", "보존 및 삭제"],
        ),
        "getTerms" => content(
            "terms",
            "이용약관",
            "공개 자료는 출처, 시점, 한계와 함께 사용해야 하며 단독 범죄 판단 근거가 아닙니다.",
            &["책임 있는 재사용", "자동화 요청 제한", "변경 이력"],
        ),
        "listAgencies" => list_agencies(&state.pool, &query).await?,
        "getAgency" => get_agency(&state.pool, path_uuid(request, "agencyId")?).await?,
        "listAgencyCases" => {
            list_related_cases(
                &state.pool,
                &query,
                "agency",
                path_uuid(request, "agencyId")?,
            )
            .await?
        }
        "listAgencyContracts" => {
            list_contracts(
                &state.pool,
                &query,
                Some(("agency", path_uuid(request, "agencyId")?)),
            )
            .await?
        }
        "listSuppliers" => list_suppliers(&state.pool, &query).await?,
        "getSupplier" => get_supplier(&state.pool, path_uuid(request, "supplierId")?).await?,
        "listSupplierCases" => {
            list_related_cases(
                &state.pool,
                &query,
                "supplier",
                path_uuid(request, "supplierId")?,
            )
            .await?
        }
        "listSupplierContracts" => {
            list_contracts(
                &state.pool,
                &query,
                Some(("supplier", path_uuid(request, "supplierId")?)),
            )
            .await?
        }
        "listContracts" => list_contracts(&state.pool, &query, None).await?,
        "getContract" => get_contract(&state.pool, path_uuid(request, "contractId")?).await?,
        "listContractChanges" => {
            list_contract_changes(&state.pool, &query, path_uuid(request, "contractId")?).await?
        }
        "downloadContracts" => download_contracts(&state.pool, &query).await?,
        "listPublicCases" => list_cases(&state.pool, &query, None).await?,
        "getPublicCase" => get_case(&state.pool, path(request, "caseSlug")?).await?,
        "listCaseRevisions" => {
            list_revisions(&state.pool, &query, path(request, "caseSlug")?).await?
        }
        "getPublicCaseRevision" => {
            get_revision(
                &state.pool,
                path(request, "caseSlug")?,
                path(request, "revision")?
                    .parse()
                    .map_err(|_| ServiceError::InvalidRequest)?,
            )
            .await?
        }
        "getCaseReproducibility" => {
            reproducibility(&state.pool, path(request, "caseSlug")?).await?
        }
        "downloadCaseReproducibility" => {
            download_reproducibility(&state.pool, path(request, "caseSlug")?, &query).await?
        }
        "listCorrections" => list_corrections(&state.pool, &query).await?,
        "getCorrection" => get_correction(&state.pool, path_uuid(request, "correctionId")?).await?,
        "getCoverage" => coverage(&state.pool).await?,
        "listPublicDatasets" => list_datasets(&state.pool, &query).await?,
        "listRules" => list_rules(&state.pool, &query).await?,
        "getRule" => get_rule(&state.pool, path(request, "ruleId")?).await?,
        "listRuleCases" => {
            list_cases(
                &state.pool,
                &query,
                Some(("rule", path(request, "ruleId")?)),
            )
            .await?
        }
        "listSourceStatus" => list_sources(&state.pool, &query).await?,
        "getSource" => get_source(&state.pool, path(request, "sourceId")?).await?,
        "searchPublicRecords" => search(&state.pool, &query).await?,
        "getPublicSystemStatus" => system_status(&state.pool).await?,
        "listTransparencyReports" => list_reports(&state.pool, &query).await?,
        _ => return Err(ServiceError::InvalidRequest),
    };
    Ok(Output {
        status: 200,
        media_type: "application/json",
        body,
    })
}

#[derive(Default)]
struct Query {
    values: BTreeMap<String, Vec<String>>,
    offset: i64,
    limit: i64,
}

impl Query {
    fn parse(request: &HttpRequest) -> Result<Self, ServiceError> {
        let mut values = BTreeMap::<String, Vec<String>>::new();
        for (name, value) in url::form_urlencoded::parse(request.query_string().as_bytes()) {
            values.entry(name.into_owned()).or_default().extend(
                value
                    .split(',')
                    .filter(|item| !item.is_empty())
                    .map(str::to_owned),
            );
        }
        let limit = values
            .get("limit")
            .and_then(|items| items.first())
            .map_or(Ok(20), |value| value.parse::<i64>())
            .map_err(|_| ServiceError::InvalidRequest)?;
        if !(1..=200).contains(&limit) {
            return Err(ServiceError::InvalidRequest);
        }
        let offset = values
            .get("cursor")
            .and_then(|items| items.first())
            .map_or(Ok(0), |value| {
                let bytes = URL_SAFE_NO_PAD
                    .decode(value)
                    .map_err(|_| ServiceError::InvalidRequest)?;
                std::str::from_utf8(&bytes)
                    .map_err(|_| ServiceError::InvalidRequest)?
                    .parse::<i64>()
                    .map_err(|_| ServiceError::InvalidRequest)
            })?;
        if offset < 0 {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(Self {
            values,
            offset,
            limit,
        })
    }

    fn first(&self, name: &str) -> Option<&str> {
        self.values
            .get(name)
            .and_then(|items| items.first())
            .map(String::as_str)
    }

    fn many(&self, name: &str) -> Vec<String> {
        self.values.get(name).cloned().unwrap_or_default()
    }
}

fn optional_uuid(query: &Query, name: &str) -> Result<Option<Uuid>, ServiceError> {
    query
        .first(name)
        .map(|value| Uuid::parse_str(value).map_err(|_| ServiceError::InvalidRequest))
        .transpose()
}

fn optional_date(query: &Query, name: &str) -> Result<Option<Date>, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    query
        .first(name)
        .map(|value| Date::parse(value, &format).map_err(|_| ServiceError::InvalidRequest))
        .transpose()
}

fn optional_decimal(query: &Query, name: &str) -> Result<Option<Decimal>, ServiceError> {
    query
        .first(name)
        .map(|value| {
            if !decimal_syntax(value) {
                return Err(ServiceError::InvalidRequest);
            }
            value.parse().map_err(|_| ServiceError::InvalidRequest)
        })
        .transpose()
}

fn decimal_syntax(value: &str) -> bool {
    let unsigned = value.strip_prefix('-').unwrap_or(value);
    let mut parts = unsigned.split('.');
    let integer = parts.next().unwrap_or_default();
    let fraction = parts.next();
    !integer.is_empty()
        && integer.bytes().all(|byte| byte.is_ascii_digit())
        && fraction.is_none_or(|digits| {
            !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit())
        })
        && parts.next().is_none()
}

fn optional_bool(query: &Query, name: &str) -> Result<Option<bool>, ServiceError> {
    query
        .first(name)
        .map(|value| value.parse().map_err(|_| ServiceError::InvalidRequest))
        .transpose()
}

fn requested_sort<'a>(
    query: &'a Query,
    allowed: &[&str],
    default: &'static str,
) -> Result<&'a str, ServiceError> {
    let value = query.first("sort").unwrap_or(default);
    if allowed.contains(&value) {
        Ok(value)
    } else {
        Err(ServiceError::InvalidRequest)
    }
}

fn validate_range<T: PartialOrd>(lower: Option<&T>, upper: Option<&T>) -> Result<(), ServiceError> {
    if lower.zip(upper).is_some_and(|(lower, upper)| lower > upper) {
        Err(ServiceError::InvalidRequest)
    } else {
        Ok(())
    }
}

fn path<'a>(request: &'a HttpRequest, name: &str) -> Result<&'a str, ServiceError> {
    request
        .match_info()
        .get(name)
        .filter(|value| !value.trim().is_empty() && value.len() <= 256)
        .ok_or(ServiceError::InvalidRequest)
}

fn path_uuid(request: &HttpRequest, name: &str) -> Result<Uuid, ServiceError> {
    Uuid::parse_str(path(request, name)?).map_err(|_| ServiceError::InvalidRequest)
}

fn now() -> Result<String, ServiceError> {
    let unix_minute = OffsetDateTime::now_utc().unix_timestamp() / 60 * 60;
    OffsetDateTime::from_unix_timestamp(unix_minute)
        .map_err(|_| ServiceError::Persistence)?
        .format(&Rfc3339)
        .map_err(|_| ServiceError::Persistence)
}

fn timestamp(value: OffsetDateTime) -> Result<String, ServiceError> {
    value
        .format(&Rfc3339)
        .map_err(|_| ServiceError::Persistence)
}

fn page(
    mut items: Vec<Value>,
    query: &Query,
    applied_filters: Value,
) -> Result<Value, ServiceError> {
    let has_more = items.len() > query.limit as usize;
    if has_more {
        items.truncate(query.limit as usize);
    }
    let mut value = json!({
        "items": items,
        "appliedFilters": applied_filters,
        "asOf": now()?,
    });
    if has_more {
        value["nextCursor"] = Value::String(
            URL_SAFE_NO_PAD.encode((query.offset + query.limit).to_string().as_bytes()),
        );
    }
    Ok(value)
}

fn content(id: &str, title: &str, summary: &str, sections: &[&str]) -> Value {
    json!({
        "id": {"id":id,"status":"PUBLISHED","version":1},
        "version": 1,
        "status": "PUBLISHED",
        "updatedAt": "2026-07-12T00:00:00Z",
        "title": title,
        "summary": summary,
        "data": {
            "version": "1.0",
            "title": title,
            "updatedAt": "2026-07-12T00:00:00Z",
            "sections": sections.iter().enumerate().map(|(index, text)| json!({
                "id": format!("section-{}", index + 1),
                "heading": text,
                "body": text,
            })).collect::<Vec<_>>(),
            "sourceLinks": [],
        },
        "links": [],
    })
}

fn case_card(row: &PgRow) -> Result<Value, ServiceError> {
    let slug: String = row.try_get("slug").map_err(db)?;
    Ok(json!({
        "slug": slug,
        "title": row.try_get::<String,_>("title").map_err(db)?,
        "publicState": row.try_get::<String,_>("public_state").map_err(db)?,
        "summary": row.try_get::<String,_>("summary").map_err(db)?,
        "revision": row.try_get::<i32,_>("latest_revision").map_err(db)?,
        "updatedAt": timestamp(row.try_get("updated_at").map_err(db)?)?,
        "href": format!("/cases/{slug}"),
    }))
}

fn contract_summary(row: &PgRow) -> Result<Value, ServiceError> {
    let id: Uuid = row.try_get("id").map_err(db)?;
    let agency_id: Option<Uuid> = row.try_get("agency_id").map_err(db)?;
    let supplier_id: Option<Uuid> = row.try_get("supplier_id").map_err(db)?;
    let mut value = json!({
        "id": id,
        "contractNumber": row.try_get::<Option<String>,_>("contract_number").map_err(db)?.unwrap_or_default(),
        "title": row.try_get::<String,_>("title").map_err(db)?,
        "agency": entity_ref(agency_id, row.try_get::<Option<String>,_>("agency_name").map_err(db)?, "AGENCY"),
        "status": row.try_get::<String,_>("status").map_err(db)?,
        "href": format!("/contracts/{id}"),
    });
    if let Some(supplier) = supplier_id {
        value["supplier"] = entity_ref(
            Some(supplier),
            row.try_get::<Option<String>, _>("supplier_name")
                .map_err(db)?,
            "SUPPLIER",
        );
    }
    if let Some(date) = row
        .try_get::<Option<time::Date>, _>("signed_at")
        .map_err(db)?
    {
        value["signedAt"] = Value::String(date.to_string());
    }
    if let Some(amount) = row.try_get::<Option<Value>, _>("amount").map_err(db)? {
        value["amount"] = amount;
    }
    Ok(value)
}

fn entity_ref(id: Option<Uuid>, name: Option<String>, kind: &str) -> Value {
    match id {
        Some(id) => json!({
            "id": id,
            "name": name.unwrap_or_else(|| "공개 식별자 미상".to_owned()),
            "entityType": kind,
            "href": if kind == "AGENCY" { format!("/agencies/{id}") } else { format!("/suppliers/{id}") },
        }),
        None => json!({
            "id": "unresolved",
            "name": name.unwrap_or_else(|| "미확인".to_owned()),
            "entityType": kind,
            "href": "",
        }),
    }
}

async fn list_agencies(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let q = query.first("q").unwrap_or("");
    let types = query.many("agencyType");
    let jurisdiction = query.first("jurisdiction").unwrap_or("");
    let sort = requested_sort(
        query,
        &["name_asc", "updated_desc", "contract_count_desc"],
        "name_asc",
    )?;
    let rows = sqlx::query(
        "SELECT a.id,a.name,a.agency_type,a.jurisdiction,a.coverage,a.case_counts,a.updated_at FROM public.agencies a WHERE ($1='' OR a.name ILIKE '%'||$1||'%') AND (cardinality($2::text[])=0 OR a.agency_type=ANY($2)) AND ($3='' OR a.jurisdiction=$3) ORDER BY CASE WHEN $4='name_asc' THEN a.name END ASC,CASE WHEN $4='updated_desc' THEN a.updated_at END DESC,CASE WHEN $4='contract_count_desc' THEN (SELECT count(*) FROM public.contracts c WHERE c.agency_id=a.id) END DESC,a.id LIMIT $5 OFFSET $6",
    )
        .bind(q)
        .bind(&types)
        .bind(jurisdiction)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let id: Uuid = row.try_get("id").map_err(db)?;
        items.push(json!({
            "id": id,
            "name": row.try_get::<String,_>("name").map_err(db)?,
            "agencyType": row.try_get::<String,_>("agency_type").map_err(db)?,
            "jurisdiction": row.try_get::<Option<String>,_>("jurisdiction").map_err(db)?,
            "caseCounts": row.try_get::<Value,_>("case_counts").map_err(db)?,
            "coverage": row.try_get::<Value,_>("coverage").map_err(db)?,
            "href": format!("/agencies/{id}"),
        }));
    }
    page(
        items,
        query,
        json!({"q":q,"agencyType":types,"jurisdiction":jurisdiction}),
    )
}

async fn get_agency(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row = sqlx::query("SELECT id,name,agency_type,jurisdiction,coverage,descriptive_metrics,case_counts,updated_at FROM public.agencies WHERE id=$1")
        .bind(id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let cases = recent_cases(pool, "agency", id).await?;
    let contracts = recent_contracts(pool, "agency", id).await?;
    Ok(json!({
        "id": id,
        "name": row.try_get::<String,_>("name").map_err(db)?,
        "agencyType": row.try_get::<String,_>("agency_type").map_err(db)?,
        "jurisdiction": row.try_get::<Option<String>,_>("jurisdiction").map_err(db)?,
        "identifiers": [],
        "coverage": row.try_get::<Value,_>("coverage").map_err(db)?,
        "metrics": row.try_get::<Value,_>("descriptive_metrics").map_err(db)?,
        "caseCountsByState": row.try_get::<Value,_>("case_counts").map_err(db)?,
        "recentCases": cases,
        "recentContracts": contracts,
        "identityWarnings": [],
        "freshness": {"asOf":timestamp(row.try_get("updated_at").map_err(db)?)?,"status":"CURRENT"},
    }))
}

async fn list_suppliers(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let q = query.first("q").unwrap_or("");
    let statuses = query.many("businessStatus");
    let identity_statuses = query.many("identityStatus");
    let sort = requested_sort(
        query,
        &["name_asc", "updated_desc", "contract_count_desc"],
        "name_asc",
    )?;
    let rows = sqlx::query(
        "SELECT s.id,s.name,s.business_status,s.coverage,s.case_counts,s.identity_warnings FROM public.suppliers s WHERE ($1='' OR s.name ILIKE '%'||$1||'%') AND (cardinality($2::text[])=0 OR s.business_status=ANY($2)) AND (cardinality($3::text[])=0 OR CASE WHEN jsonb_array_length(s.identity_warnings)=0 THEN 'VERIFIED' ELSE 'AMBIGUOUS' END=ANY($3)) ORDER BY CASE WHEN $4='name_asc' THEN s.name END ASC,CASE WHEN $4='updated_desc' THEN s.updated_at END DESC,CASE WHEN $4='contract_count_desc' THEN (SELECT count(*) FROM public.contracts c WHERE c.supplier_id=s.id) END DESC,s.id LIMIT $5 OFFSET $6",
    )
        .bind(q)
        .bind(&statuses)
        .bind(&identity_statuses)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let id: Uuid = row.try_get("id").map_err(db)?;
        items.push(json!({
            "id":id,"name":row.try_get::<String,_>("name").map_err(db)?,
            "businessStatus":row.try_get::<Option<String>,_>("business_status").map_err(db)?,
            "caseCounts":row.try_get::<Value,_>("case_counts").map_err(db)?,
            "coverage":row.try_get::<Value,_>("coverage").map_err(db)?,
            "identityWarnings":row.try_get::<Value,_>("identity_warnings").map_err(db)?,
            "href":format!("/suppliers/{id}")
        }));
    }
    page(
        items,
        query,
        json!({"q":q,"businessStatus":statuses,"identityStatus":identity_statuses}),
    )
}

async fn get_supplier(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row=sqlx::query("SELECT id,name,business_status,coverage,descriptive_metrics,case_counts,identity_warnings,updated_at FROM public.suppliers WHERE id=$1")
        .bind(id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"id":id,"name":row.try_get::<String,_>("name").map_err(db)?,
        "businessStatus":row.try_get::<Option<String>,_>("business_status").map_err(db)?,"identifiers":[],
        "coverage":row.try_get::<Value,_>("coverage").map_err(db)?,"metrics":row.try_get::<Value,_>("descriptive_metrics").map_err(db)?,
        "caseCountsByState":row.try_get::<Value,_>("case_counts").map_err(db)?,"recentCases":recent_cases(pool,"supplier",id).await?,
        "recentContracts":recent_contracts(pool,"supplier",id).await?,"identityWarnings":row.try_get::<Value,_>("identity_warnings").map_err(db)?,
        "freshness":{"asOf":timestamp(row.try_get("updated_at").map_err(db)?)?,"status":"CURRENT"}}),
    )
}

async fn recent_cases(pool: &PgPool, relation: &str, id: Uuid) -> Result<Vec<Value>, ServiceError> {
    let key = if relation == "agency" {
        "agencyId"
    } else {
        "supplierId"
    };
    let rows=sqlx::query("SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE r.payload->>$1=$2 ORDER BY c.updated_at DESC LIMIT 5")
        .bind(key).bind(id.to_string()).fetch_all(pool).await.map_err(db)?;
    rows.iter().map(case_card).collect()
}

async fn recent_contracts(
    pool: &PgPool,
    relation: &str,
    id: Uuid,
) -> Result<Vec<Value>, ServiceError> {
    let rows = if relation == "agency" {
        sqlx::query("SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE c.agency_id=$1 ORDER BY c.updated_at DESC LIMIT 5")
            .bind(id).fetch_all(pool).await.map_err(db)?
    } else {
        sqlx::query("SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE c.supplier_id=$1 ORDER BY c.updated_at DESC LIMIT 5")
            .bind(id).fetch_all(pool).await.map_err(db)?
    };
    rows.iter().map(contract_summary).collect()
}

async fn list_related_cases(
    pool: &PgPool,
    query: &Query,
    relation: &str,
    id: Uuid,
) -> Result<Value, ServiceError> {
    let key = if relation == "agency" {
        "agencyId"
    } else {
        "supplierId"
    };
    let sort = requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?;
    let rows = sqlx::query(
        "SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE r.payload->>$1=$2 ORDER BY CASE WHEN $3='updated_desc' THEN c.updated_at END DESC,CASE WHEN $3='created_asc' THEN c.published_at END ASC,c.id LIMIT $4 OFFSET $5",
    )
        .bind(key)
        .bind(id.to_string())
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    page(
        rows.iter().map(case_card).collect::<Result<_, _>>()?,
        query,
        json!({}),
    )
}

async fn list_contracts(
    pool: &PgPool,
    query: &Query,
    relation: Option<(&str, Uuid)>,
) -> Result<Value, ServiceError> {
    let q = query.first("q").unwrap_or("");
    let agency = relation
        .filter(|value| value.0 == "agency")
        .map(|value| value.1)
        .map_or_else(|| optional_uuid(query, "agencyId"), |value| Ok(Some(value)))?;
    let supplier = relation
        .filter(|value| value.0 == "supplier")
        .map(|value| value.1)
        .map_or_else(
            || optional_uuid(query, "supplierId"),
            |value| Ok(Some(value)),
        )?;
    let statuses = query.many("contractStatus");
    let procurement_methods = query.many("procurementMethod");
    let signed_from = optional_date(query, "signedFrom")?;
    let signed_to = optional_date(query, "signedTo")?;
    let amount_min = optional_decimal(query, "amountMin")?;
    let amount_max = optional_decimal(query, "amountMax")?;
    validate_range(signed_from.as_ref(), signed_to.as_ref())?;
    validate_range(amount_min.as_ref(), amount_max.as_ref())?;
    let sort = if relation.is_some() {
        requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?
    } else {
        requested_sort(
            query,
            &["signed_desc", "amount_desc", "amount_asc", "title_asc"],
            "signed_desc",
        )?
    };
    let rows = sqlx::query(
        "SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE ($1='' OR c.title ILIKE '%'||$1||'%' OR c.contract_number ILIKE '%'||$1||'%') AND ($2::uuid IS NULL OR c.agency_id=$2) AND ($3::uuid IS NULL OR c.supplier_id=$3) AND (cardinality($4::text[])=0 OR c.status=ANY($4)) AND (cardinality($5::text[])=0 OR COALESCE(c.detail->>'procurementMethod',c.detail->>'contractMethod')=ANY($5)) AND ($6::date IS NULL OR c.signed_at >= $6) AND ($7::date IS NULL OR c.signed_at <= $7) AND ($8::numeric IS NULL OR (c.amount->>'amount')::numeric >= $8) AND ($9::numeric IS NULL OR (c.amount->>'amount')::numeric <= $9) ORDER BY CASE WHEN $10='updated_desc' THEN c.updated_at END DESC,CASE WHEN $10='created_asc' THEN c.signed_at END ASC NULLS LAST,CASE WHEN $10='signed_desc' THEN c.signed_at END DESC NULLS LAST,CASE WHEN $10='amount_desc' THEN (c.amount->>'amount')::numeric END DESC NULLS LAST,CASE WHEN $10='amount_asc' THEN (c.amount->>'amount')::numeric END ASC NULLS LAST,CASE WHEN $10='title_asc' THEN c.title END ASC,c.id LIMIT $11 OFFSET $12",
    )
        .bind(q)
        .bind(agency)
        .bind(supplier)
        .bind(&statuses)
        .bind(&procurement_methods)
        .bind(signed_from)
        .bind(signed_to)
        .bind(amount_min)
        .bind(amount_max)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let applied_filters = if relation.is_some() {
        json!({})
    } else {
        let mut filters = Map::new();
        filters.insert("q".into(), json!(q));
        filters.insert("contractStatus".into(), json!(statuses));
        filters.insert("procurementMethod".into(), json!(procurement_methods));
        if let Some(value) = agency {
            filters.insert("agencyId".into(), json!(value));
        }
        if let Some(value) = supplier {
            filters.insert("supplierId".into(), json!(value));
        }
        for name in ["signedFrom", "signedTo", "amountMin", "amountMax"] {
            if let Some(value) = query.first(name) {
                filters.insert(name.into(), json!(value));
            }
        }
        Value::Object(filters)
    };
    page(
        rows.iter()
            .map(contract_summary)
            .collect::<Result<_, _>>()?,
        query,
        applied_filters,
    )
}

async fn get_contract(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row=sqlx::query("SELECT c.id,c.contract_number,c.title,c.agency_id,c.supplier_id,c.status,c.signed_at,c.amount,c.detail,a.name agency_name,s.name supplier_name FROM public.contracts c LEFT JOIN public.agencies a ON a.id=c.agency_id LEFT JOIN public.suppliers s ON s.id=c.supplier_id WHERE c.id=$1")
        .bind(id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let mut detail: Value = row.try_get("detail").map_err(db)?;
    let object = detail.as_object_mut().ok_or(ServiceError::Persistence)?;
    object.insert("id".into(), json!(id));
    object.insert(
        "contractNumber".into(),
        json!(
            row.try_get::<Option<String>, _>("contract_number")
                .map_err(db)?
                .unwrap_or_default()
        ),
    );
    object.insert(
        "title".into(),
        json!(row.try_get::<String, _>("title").map_err(db)?),
    );
    object.insert(
        "agency".into(),
        entity_ref(
            row.try_get("agency_id").map_err(db)?,
            row.try_get("agency_name").map_err(db)?,
            "AGENCY",
        ),
    );
    if let Some(supplier) = row.try_get::<Option<Uuid>, _>("supplier_id").map_err(db)? {
        object.insert(
            "supplier".into(),
            entity_ref(
                Some(supplier),
                row.try_get("supplier_name").map_err(db)?,
                "SUPPLIER",
            ),
        );
    }
    object.insert(
        "status".into(),
        json!(row.try_get::<String, _>("status").map_err(db)?),
    );
    object.entry("currency").or_insert(json!("KRW"));
    object.entry("lineItems").or_insert(json!([]));
    object.entry("changes").or_insert(json!([]));
    object.entry("sourceDocuments").or_insert(json!([]));
    object.entry("normalizationWarnings").or_insert(json!([]));
    object.entry("relatedCases").or_insert(json!([]));
    Ok(detail)
}

async fn list_contract_changes(
    pool: &PgPool,
    query: &Query,
    id: Uuid,
) -> Result<Value, ServiceError> {
    let detail: Value = sqlx::query_scalar("SELECT detail FROM public.contracts WHERE id=$1")
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(db)?
        .ok_or(ServiceError::NotFound)?;
    let mut all = detail
        .get("changes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    match requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")? {
        "updated_desc" => {
            all.sort_by(|left, right| contract_change_key(right).cmp(&contract_change_key(left)))
        }
        "created_asc" => {
            all.sort_by(|left, right| contract_change_key(left).cmp(&contract_change_key(right)))
        }
        _ => return Err(ServiceError::InvalidRequest),
    }
    let items = all
        .into_iter()
        .skip(query.offset as usize)
        .take((query.limit + 1) as usize)
        .collect();
    page(items, query, json!({}))
}

fn contract_change_key(value: &Value) -> (&str, i64) {
    (
        value.get("changedAt").and_then(Value::as_str).unwrap_or(""),
        value.get("sequence").and_then(Value::as_i64).unwrap_or(0),
    )
}

async fn download_contracts(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let format = query.first("format").ok_or(ServiceError::InvalidRequest)?;
    if !matches!(format, "CSV" | "JSONL") {
        return Err(ServiceError::InvalidRequest);
    }
    let agency = optional_uuid(query, "agencyId")?;
    let supplier = optional_uuid(query, "supplierId")?;
    let signed_from = optional_date(query, "signedFrom")?;
    let signed_to = optional_date(query, "signedTo")?;
    validate_range(signed_from.as_ref(), signed_to.as_ref())?;
    let count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM public.contracts c WHERE ($1::uuid IS NULL OR c.agency_id=$1) AND ($2::uuid IS NULL OR c.supplier_id=$2) AND ($3::date IS NULL OR c.signed_at >= $3) AND ($4::date IS NULL OR c.signed_at <= $4)",
    )
        .bind(agency)
        .bind(supplier)
        .bind(signed_from)
        .bind(signed_to)
        .fetch_one(pool)
        .await
        .map_err(db)?;
    let digest = Sha256::digest(format!("contracts:{}:{:?}", count, query.values).as_bytes());
    Ok(json!({"id":format!("contracts-{:x}",digest),"status":"READY","version":count}))
}

async fn list_cases(
    pool: &PgPool,
    query: &Query,
    relation: Option<(&str, &str)>,
) -> Result<Value, ServiceError> {
    let states = query.many("publicationState");
    let agency = relation
        .filter(|value| value.0 == "agency")
        .map(|value| value.1.to_owned())
        .map_or_else(
            || optional_uuid(query, "agencyId").map(|value| value.map(|id| id.to_string())),
            |value| Ok(Some(value)),
        )?;
    let supplier = relation
        .filter(|value| value.0 == "supplier")
        .map(|value| value.1.to_owned())
        .map_or_else(
            || optional_uuid(query, "supplierId").map(|value| value.map(|id| id.to_string())),
            |value| Ok(Some(value)),
        )?;
    let rule = relation
        .filter(|value| value.0 == "rule")
        .map(|value| value.1.to_owned())
        .or_else(|| query.first("ruleId").map(str::to_owned));
    let published_from = optional_date(query, "publishedFrom")?;
    let published_to = optional_date(query, "publishedTo")?;
    let has_response = optional_bool(query, "hasResponse")?;
    let has_correction = optional_bool(query, "hasCorrection")?;
    validate_range(published_from.as_ref(), published_to.as_ref())?;
    let sort = if relation.is_some() {
        requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?
    } else {
        requested_sort(
            query,
            &["updated_desc", "published_desc", "title_asc"],
            "updated_desc",
        )?
    };
    let rows = sqlx::query(
        "SELECT c.slug,c.title,c.public_state,c.summary,c.latest_revision,c.updated_at FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE (cardinality($1::text[])=0 OR c.public_state=ANY($1)) AND ($2::text IS NULL OR r.payload->>'agencyId'=$2) AND ($3::text IS NULL OR r.payload->>'supplierId'=$3) AND ($4::text IS NULL OR r.payload->>'ruleId'=$4) AND ($5::date IS NULL OR c.published_at::date >= $5) AND ($6::date IS NULL OR c.published_at::date <= $6) AND ($7::boolean IS NULL OR (jsonb_path_exists(r.payload,'$.responses[*]') OR jsonb_path_exists(r.payload,'$.partyResponses[*]'))=$7) AND ($8::boolean IS NULL OR EXISTS(SELECT 1 FROM public.corrections x WHERE x.case_id=c.id)=$8) ORDER BY CASE WHEN $9='updated_desc' THEN c.updated_at END DESC,CASE WHEN $9='created_asc' THEN c.published_at END ASC,CASE WHEN $9='published_desc' THEN c.published_at END DESC,CASE WHEN $9='title_asc' THEN c.title END ASC,c.id LIMIT $10 OFFSET $11",
    )
        .bind(&states)
        .bind(&agency)
        .bind(&supplier)
        .bind(&rule)
        .bind(published_from)
        .bind(published_to)
        .bind(has_response)
        .bind(has_correction)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let applied_filters = if relation.is_some() {
        json!({})
    } else {
        let mut filters = Map::new();
        filters.insert("publicationState".into(), json!(states));
        for name in [
            "agencyId",
            "supplierId",
            "ruleId",
            "publishedFrom",
            "publishedTo",
        ] {
            if let Some(value) = query.first(name) {
                filters.insert(name.into(), json!(value));
            }
        }
        for name in ["hasResponse", "hasCorrection"] {
            if let Some(value) = query.first(name) {
                filters.insert(
                    name.into(),
                    json!(
                        value
                            .parse::<bool>()
                            .map_err(|_| ServiceError::InvalidRequest)?
                    ),
                );
            }
        }
        Value::Object(filters)
    };
    page(
        rows.iter().map(case_card).collect::<Result<_, _>>()?,
        query,
        applied_filters,
    )
}

async fn get_case(pool: &PgPool, slug: &str) -> Result<Value, ServiceError> {
    let row=sqlx::query("SELECT c.slug,c.title,c.public_state,c.latest_revision,c.summary,c.published_at,c.updated_at,c.source_freshness,r.payload FROM public.cases c JOIN public.case_revisions r ON r.case_id=c.id AND r.revision=c.latest_revision WHERE c.slug=$1")
        .bind(slug).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let mut payload: Value = row.try_get("payload").map_err(db)?;
    let obj = payload.as_object_mut().ok_or(ServiceError::Persistence)?;
    obj.insert("slug".into(), json!(slug));
    obj.insert(
        "title".into(),
        json!(row.try_get::<String, _>("title").map_err(db)?),
    );
    obj.insert(
        "publicState".into(),
        json!(row.try_get::<String, _>("public_state").map_err(db)?),
    );
    obj.insert(
        "revision".into(),
        json!(row.try_get::<i32, _>("latest_revision").map_err(db)?),
    );
    obj.insert(
        "publishedAt".into(),
        json!(timestamp(row.try_get("published_at").map_err(db)?)?),
    );
    obj.insert(
        "updatedAt".into(),
        json!(timestamp(row.try_get("updated_at").map_err(db)?)?),
    );
    obj.insert(
        "summary".into(),
        json!(row.try_get::<String, _>("summary").map_err(db)?),
    );
    for key in [
        "confirmedFacts",
        "criticalUnknowns",
        "partyResponses",
        "signals",
        "counterEvidence",
        "claims",
        "evidence",
        "timeline",
        "corrections",
        "limitations",
    ] {
        obj.entry(key).or_insert(json!([]));
    }
    obj.entry("freshness")
        .or_insert(row.try_get::<Value, _>("source_freshness").map_err(db)?);
    obj.entry("seo").or_insert(json!({"title":row.try_get::<String,_>("title").map_err(db)?,"description":row.try_get::<String,_>("summary").map_err(db)?,"canonicalUrl":format!("/cases/{slug}"),"robots":"index,follow"}));
    obj.remove("reproducibility");
    obj.remove("content");
    obj.remove("agencyId");
    obj.remove("supplierId");
    obj.remove("ruleId");
    Ok(payload)
}

async fn list_revisions(pool: &PgPool, query: &Query, slug: &str) -> Result<Value, ServiceError> {
    let sort = requested_sort(query, &["updated_desc", "created_asc"], "updated_desc")?;
    let rows = sqlx::query(
        "SELECT r.revision,r.state::text state,r.published_at,r.payload FROM public.case_revisions r JOIN public.cases c ON c.id=r.case_id WHERE c.slug=$1 ORDER BY CASE WHEN $2='updated_desc' THEN r.revision END DESC,CASE WHEN $2='created_asc' THEN r.revision END ASC LIMIT $3 OFFSET $4",
    )
        .bind(slug)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    if rows.is_empty() && query.offset == 0 {
        return Err(ServiceError::NotFound);
    }
    let mut items = Vec::new();
    for row in rows {
        let rev: i32 = row.try_get("revision").map_err(db)?;
        let payload: Value = row.try_get("payload").map_err(db)?;
        items.push(json!({"revision":rev,"state":row.try_get::<String,_>("state").map_err(db)?,"publishedAt":timestamp(row.try_get("published_at").map_err(db)?)?,"summary":payload.get("summary").and_then(Value::as_str).unwrap_or("공개 revision"),"href":format!("/cases/{slug}/revisions/{rev}")}));
    }
    page(items, query, json!({}))
}

async fn get_revision(pool: &PgPool, slug: &str, revision: i32) -> Result<Value, ServiceError> {
    let row=sqlx::query("SELECT c.latest_revision,r.revision,r.payload,r.payload_sha256,r.published_at,r.supersedes_revision FROM public.case_revisions r JOIN public.cases c ON c.id=r.case_id WHERE c.slug=$1 AND r.revision=$2")
        .bind(slug).bind(revision).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let payload: Value = row.try_get("payload").map_err(db)?;
    Ok(
        json!({"slug":slug,"revision":revision,"isLatest":row.try_get::<i32,_>("latest_revision").map_err(db)?==revision,"snapshotHash":row.try_get::<String,_>("payload_sha256").map_err(db)?.trim(),"publishedAt":timestamp(row.try_get("published_at").map_err(db)?)?,"content":payload.get("content").cloned().unwrap_or(payload),"diffFromPrevious":[]}),
    )
}

async fn reproducibility(pool: &PgPool, slug: &str) -> Result<Value, ServiceError> {
    let payload:Value=sqlx::query_scalar("SELECT r.payload FROM public.case_revisions r JOIN public.cases c ON c.id=r.case_id AND r.revision=c.latest_revision WHERE c.slug=$1").bind(slug).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    payload
        .get("reproducibility")
        .cloned()
        .ok_or(ServiceError::NotFound)
}

async fn download_reproducibility(
    pool: &PgPool,
    slug: &str,
    query: &Query,
) -> Result<Value, ServiceError> {
    let format = query.first("format").ok_or(ServiceError::InvalidRequest)?;
    if !matches!(format, "JSON" | "CSV") {
        return Err(ServiceError::InvalidRequest);
    }
    let value = reproducibility(pool, slug).await?;
    let bytes = serde_json::to_vec(&value).map_err(|_| ServiceError::Persistence)?;
    Ok(json!({"id":format!("repro-{}",hex(&Sha256::digest(bytes))),"status":"READY","version":1}))
}

async fn list_corrections(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let states = query.many("publicationState");
    let published_from = optional_date(query, "publishedFrom")?;
    let published_to = optional_date(query, "publishedTo")?;
    validate_range(published_from.as_ref(), published_to.as_ref())?;
    let sort = requested_sort(query, &["published_desc", "title_asc"], "published_desc")?;
    let rows = sqlx::query(
        "SELECT x.id,x.source_revision,x.target_revision,x.summary,x.reason,x.published_at,c.slug FROM public.corrections x JOIN public.cases c ON c.id=x.case_id WHERE (cardinality($1::text[])=0 OR c.public_state=ANY($1)) AND ($2::date IS NULL OR x.published_at::date >= $2) AND ($3::date IS NULL OR x.published_at::date <= $3) ORDER BY CASE WHEN $4='published_desc' THEN x.published_at END DESC,CASE WHEN $4='title_asc' THEN x.summary END ASC,x.id LIMIT $5 OFFSET $6",
    )
        .bind(&states)
        .bind(published_from)
        .bind(published_to)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::new();
    for row in rows {
        let id: Uuid = row.try_get("id").map_err(db)?;
        items.push(json!({"id":id,"sourceRevision":row.try_get::<i32,_>("source_revision").map_err(db)?,"targetRevision":row.try_get::<Option<i32>,_>("target_revision").map_err(db)?,"summary":row.try_get::<String,_>("summary").map_err(db)?,"reason":row.try_get::<String,_>("reason").map_err(db)?,"publishedAt":timestamp(row.try_get("published_at").map_err(db)?)?,"href":format!("/corrections/{id}")}));
    }
    let mut filters = Map::new();
    filters.insert("publicationState".into(), json!(states));
    for name in ["publishedFrom", "publishedTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page(items, query, Value::Object(filters))
}

async fn get_correction(pool: &PgPool, id: Uuid) -> Result<Value, ServiceError> {
    let row=sqlx::query("SELECT x.id,x.source_revision,x.target_revision,x.summary,x.reason,x.published_at,c.slug FROM public.corrections x JOIN public.cases c ON c.id=x.case_id WHERE x.id=$1").bind(id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"id":{"id":id,"status":"PUBLISHED","version":1},"status":"PUBLISHED","data":{"id":id,"caseSlug":row.try_get::<String,_>("slug").map_err(db)?,"sourceRevision":row.try_get::<i32,_>("source_revision").map_err(db)?,"targetRevision":row.try_get::<Option<i32>,_>("target_revision").map_err(db)?,"summary":row.try_get::<String,_>("summary").map_err(db)?,"reason":row.try_get::<String,_>("reason").map_err(db)?,"publishedAt":timestamp(row.try_get("published_at").map_err(db)?)?,"affectedClaims":[]},"links":[]}),
    )
}

async fn coverage(pool: &PgPool) -> Result<Value, ServiceError> {
    let counts=sqlx::query("SELECT (SELECT count(*) FROM public.contracts) contracts,(SELECT count(*) FROM public.agencies) agencies,(SELECT count(*) FROM public.suppliers) suppliers,(SELECT count(*) FROM public.cases) cases").fetch_one(pool).await.map_err(db)?;
    let source_status = list_source_values(pool, &[], 200, 0, "name_asc").await?;
    let coverage_as_of = now()?;
    let sources = source_status
        .into_iter()
        .map(|source| {
            json!({
                "sourceId":source["sourceId"],
                "displayName":source["displayName"],
                "status":source["status"],
                "dateRange":{"label":"공개 projection 기간"},
                "recordCount":0,
                "freshness":{
                    "asOf":coverage_as_of,
                    "lastSuccessfulFetchAt":source["lastSuccessAt"],
                    "lagSeconds":source["lagSeconds"],
                    "status":"CURRENT"
                },
                "knownGaps":[]
            })
        })
        .collect::<Vec<_>>();
    Ok(
        json!({"asOf":now()?,"sources":sources,"dateRange":{"label":"projection 전체 보유 기간"},"recordCounts":{"sourceDocuments":0,"contracts":counts.try_get::<i64,_>("contracts").map_err(db)?,"contractLineItems":0,"agencies":counts.try_get::<i64,_>("agencies").map_err(db)?,"suppliers":counts.try_get::<i64,_>("suppliers").map_err(db)?,"publicCases":counts.try_get::<i64,_>("cases").map_err(db)?},"knownGaps":[],"methodologyVersion":"v13.0.0"}),
    )
}

async fn list_datasets(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let formats = query.many("format");
    let sort = requested_sort(query, &["updated_desc", "title_asc"], "updated_desc")?;
    let rows = sqlx::query(
        "SELECT id,title,description,format,coverage,license,download_url,updated_at FROM public.datasets WHERE cardinality($1::text[])=0 OR format=ANY($1) ORDER BY CASE WHEN $2='updated_desc' THEN updated_at END DESC,CASE WHEN $2='title_asc' THEN title END ASC,id LIMIT $3 OFFSET $4",
    )
        .bind(&formats)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        items.push(json!({"id":r.try_get::<String,_>("id").map_err(db)?,"title":r.try_get::<String,_>("title").map_err(db)?,"description":r.try_get::<String,_>("description").map_err(db)?,"format":r.try_get::<String,_>("format").map_err(db)?,"coverage":r.try_get::<Value,_>("coverage").map_err(db)?,"license":r.try_get::<String,_>("license").map_err(db)?,"downloadUrl":r.try_get::<Option<String>,_>("download_url").map_err(db)?,"updatedAt":timestamp(r.try_get("updated_at").map_err(db)?)?}));
    }
    page(items, query, json!({"format":formats}))
}

async fn list_rules(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let statuses = query.many("status");
    let sort = requested_sort(query, &["name_asc", "updated_desc"], "name_asc")?;
    let rows = sqlx::query(
        "SELECT rule_id,name,active_version,public_description,requirements,exclusions,limitations,updated_at FROM public.rules WHERE cardinality($1::text[])=0 OR 'ACTIVE'::text=ANY($1) ORDER BY CASE WHEN $2='name_asc' THEN name END ASC,CASE WHEN $2='updated_desc' THEN updated_at END DESC,rule_id LIMIT $3 OFFSET $4",
    )
        .bind(&statuses)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        items.push(rule_value(&r)?)
    }
    page(items, query, json!({"status":statuses}))
}
fn rule_value(r: &PgRow) -> Result<Value, ServiceError> {
    Ok(
        json!({"ruleId":r.try_get::<String,_>("rule_id").map_err(db)?,"name":r.try_get::<String,_>("name").map_err(db)?,"activeVersion":r.try_get::<String,_>("active_version").map_err(db)?,"description":r.try_get::<String,_>("public_description").map_err(db)?,"requiredFields":r.try_get::<Value,_>("requirements").map_err(db)?,"exclusions":r.try_get::<Value,_>("exclusions").map_err(db)?,"limitations":r.try_get::<Value,_>("limitations").map_err(db)?,"formula":"authority-defined deterministic evaluation","updatedAt":timestamp(r.try_get("updated_at").map_err(db)?)?}),
    )
}
async fn get_rule(pool: &PgPool, id: &str) -> Result<Value, ServiceError> {
    let r=sqlx::query("SELECT rule_id,name,active_version,public_description,requirements,exclusions,limitations,updated_at FROM public.rules WHERE rule_id=$1").bind(id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    Ok(
        json!({"id":{"id":id,"status":"ACTIVE","version":1},"status":"ACTIVE","data":rule_value(&r)?,"links":[]}),
    )
}

async fn list_source_values(
    pool: &PgPool,
    statuses: &[String],
    limit: i64,
    offset: i64,
    sort: &str,
) -> Result<Vec<Value>, ServiceError> {
    if !matches!(sort, "status_asc" | "last_success_desc" | "name_asc") {
        return Err(ServiceError::InvalidRequest);
    }
    let rows = sqlx::query(
        "SELECT source_id,display_name,status,last_success_at,lag_seconds,affected_scope,public_message,updated_at FROM public.source_status WHERE cardinality($1::text[])=0 OR status=ANY($1) ORDER BY CASE WHEN $2='status_asc' THEN status END ASC,CASE WHEN $2='last_success_desc' THEN last_success_at END DESC NULLS LAST,CASE WHEN $2='name_asc' THEN display_name END ASC,source_id LIMIT $3 OFFSET $4",
    )
        .bind(statuses)
        .bind(sort)
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut values = Vec::new();
    for r in rows {
        values.push(json!({"sourceId":r.try_get::<String,_>("source_id").map_err(db)?,"displayName":r.try_get::<String,_>("display_name").map_err(db)?,"status":r.try_get::<String,_>("status").map_err(db)?,"lastSuccessAt":r.try_get::<Option<OffsetDateTime>,_>("last_success_at").map_err(db)?.map(timestamp).transpose()?,"lagSeconds":r.try_get::<Option<i64>,_>("lag_seconds").map_err(db)?,"publicMessage":r.try_get::<Option<String>,_>("public_message").map_err(db)?}));
    }
    Ok(values)
}
async fn list_sources(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let statuses = query.many("status");
    let sort = requested_sort(
        query,
        &["status_asc", "last_success_desc", "name_asc"],
        "name_asc",
    )?;
    let items = list_source_values(pool, &statuses, query.limit + 1, query.offset, sort).await?;
    page(items, query, json!({"status":statuses}))
}
async fn get_source(pool: &PgPool, id: &str) -> Result<Value, ServiceError> {
    let r=sqlx::query("SELECT source_id,display_name,status,last_success_at,lag_seconds,affected_scope,public_message,updated_at FROM public.source_status WHERE source_id=$1").bind(id).fetch_optional(pool).await.map_err(db)?.ok_or(ServiceError::NotFound)?;
    let status: String = r.try_get("status").map_err(db)?;
    Ok(
        json!({"id":{"id":id,"status":status,"version":1},"status":status,"data":{"sourceId":id,"displayName":r.try_get::<String,_>("display_name").map_err(db)?,"owner":"공개 데이터 제공기관","accessType":"PUBLIC","status":status,"coverage":{"dateRange":{"label":"공개 projection 기간"},"sourceIds":[id],"recordCount":0,"knownGaps":[],"freshness":{"asOf":timestamp(r.try_get("updated_at").map_err(db)?)?,"status":"CURRENT"}},"freshness":{"asOf":timestamp(r.try_get("updated_at").map_err(db)?)?,"status":"CURRENT"},"knownIssues":[]},"links":[]}),
    )
}

async fn search(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let q = query
        .first("q")
        .filter(|v| v.trim().len() >= 2)
        .ok_or(ServiceError::InvalidRequest)?;
    let pattern = format!("%{q}%");
    let types = query
        .many("types")
        .into_iter()
        .map(|value| value.to_ascii_uppercase())
        .collect::<Vec<_>>();
    let states = query.many("publicationState");
    let date_from = optional_date(query, "dateFrom")?;
    let date_to = optional_date(query, "dateTo")?;
    validate_range(date_from.as_ref(), date_to.as_ref())?;
    let sort = requested_sort(
        query,
        &["relevance", "updated_desc", "title_asc"],
        "relevance",
    )?;
    let rows = sqlx::query(
        "SELECT result_type,id,title,subtitle,status,summary,updated_at,href FROM (\
         SELECT 'CASE'::text result_type,id::text,title,slug subtitle,public_state status,summary,updated_at,'/cases/'||slug href FROM public.cases WHERE (title ILIKE $1 OR summary ILIKE $1) AND (cardinality($2::text[])=0 OR 'CASE'=ANY($2)) AND (cardinality($3::text[])=0 OR public_state=ANY($3)) AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) \
         UNION ALL SELECT 'AGENCY',id::text,name,jurisdiction,agency_type,NULL,updated_at,'/agencies/'||id::text FROM public.agencies WHERE name ILIKE $1 AND (cardinality($2::text[])=0 OR 'AGENCY'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) \
         UNION ALL SELECT 'SUPPLIER',id::text,name,business_status,business_status,NULL,updated_at,'/suppliers/'||id::text FROM public.suppliers WHERE name ILIKE $1 AND (cardinality($2::text[])=0 OR 'SUPPLIER'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) \
         UNION ALL SELECT 'CONTRACT',id::text,title,contract_number,status,NULL,updated_at,'/contracts/'||id::text FROM public.contracts WHERE (title ILIKE $1 OR contract_number ILIKE $1) AND (cardinality($2::text[])=0 OR 'CONTRACT'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) \
         UNION ALL SELECT 'RULE',rule_id,name,active_version,'ACTIVE',public_description,updated_at,'/methodology/rules/'||rule_id FROM public.rules WHERE (name ILIKE $1 OR public_description ILIKE $1) AND (cardinality($2::text[])=0 OR 'RULE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) \
         UNION ALL SELECT 'CORRECTION',x.id::text,x.summary,c.slug,c.public_state,x.reason,x.published_at,'/corrections/'||x.id::text FROM public.corrections x JOIN public.cases c ON c.id=x.case_id WHERE (x.summary ILIKE $1 OR x.reason ILIKE $1) AND (cardinality($2::text[])=0 OR 'CORRECTION'=ANY($2)) AND (cardinality($3::text[])=0 OR c.public_state=ANY($3)) AND ($4::date IS NULL OR x.published_at::date >= $4) AND ($5::date IS NULL OR x.published_at::date <= $5) \
         UNION ALL SELECT 'DATASET',id,title,format,'PUBLISHED',description,updated_at,'/data' FROM public.datasets WHERE (title ILIKE $1 OR description ILIKE $1) AND (cardinality($2::text[])=0 OR 'DATASET'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5) \
         UNION ALL SELECT 'SOURCE',source_id,display_name,status,status,public_message,updated_at,'/sources/'||source_id FROM public.source_status WHERE (display_name ILIKE $1 OR source_id ILIKE $1 OR public_message ILIKE $1) AND (cardinality($2::text[])=0 OR 'SOURCE'=ANY($2)) AND cardinality($3::text[])=0 AND ($4::date IS NULL OR updated_at::date >= $4) AND ($5::date IS NULL OR updated_at::date <= $5)\
         ) x ORDER BY CASE WHEN $6='relevance' THEN (title ILIKE $1) END DESC,CASE WHEN $6 IN ('relevance','updated_desc') THEN updated_at END DESC NULLS LAST,CASE WHEN $6='title_asc' THEN title END ASC,id LIMIT $7 OFFSET $8",
    )
        .bind(&pattern)
        .bind(&types)
        .bind(&states)
        .bind(date_from)
        .bind(date_to)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        let mut v = Map::new();
        for (k, c) in [
            ("resultType", "result_type"),
            ("id", "id"),
            ("title", "title"),
            ("href", "href"),
        ] {
            v.insert(k.into(), json!(r.try_get::<String, _>(c).map_err(db)?));
        }
        for (k, c) in [
            ("subtitle", "subtitle"),
            ("status", "status"),
            ("summary", "summary"),
        ] {
            if let Some(x) = r.try_get::<Option<String>, _>(c).map_err(db)? {
                v.insert(k.into(), json!(x));
            }
        }
        if let Some(x) = r
            .try_get::<Option<OffsetDateTime>, _>("updated_at")
            .map_err(db)?
        {
            v.insert("updatedAt".into(), json!(timestamp(x)?));
        }
        items.push(Value::Object(v));
    }
    let mut filters = Map::new();
    filters.insert("q".into(), json!(q));
    filters.insert("types".into(), json!(types));
    filters.insert("publicationState".into(), json!(states));
    for name in ["dateFrom", "dateTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page(items, query, Value::Object(filters))
}

async fn system_status(pool: &PgPool) -> Result<Value, ServiceError> {
    let sources = list_source_values(pool, &[], 200, 0, "name_asc").await?;
    let incident = sources.iter().any(|v| {
        v.get("status")
            .and_then(Value::as_str)
            .is_some_and(|s| matches!(s, "FAILED" | "INCIDENT"))
    });
    let degraded = sources.iter().any(|v| {
        v.get("status")
            .and_then(Value::as_str)
            .is_some_and(|s| matches!(s, "DEGRADED" | "STALE"))
    });
    Ok(
        json!({"status":if incident{"incident"}else if degraded{"degraded"}else{"operational"},"asOf":now()?,"affectedCapabilities":if incident||degraded{json!(["source freshness"])}else{json!([])},"sourceStatus":sources}),
    )
}

async fn list_reports(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let period_from = optional_date(query, "periodFrom")?;
    let period_to = optional_date(query, "periodTo")?;
    validate_range(period_from.as_ref(), period_to.as_ref())?;
    let sort = requested_sort(query, &["published_desc", "period_desc"], "published_desc")?;
    let rows = sqlx::query(
        "SELECT id,period_start,period_end,title,summary,published_at FROM public.transparency_reports WHERE ($1::date IS NULL OR period_end >= $1) AND ($2::date IS NULL OR period_start <= $2) ORDER BY CASE WHEN $3='published_desc' THEN published_at END DESC,CASE WHEN $3='period_desc' THEN period_end END DESC,CASE WHEN $3='period_desc' THEN period_start END DESC,id LIMIT $4 OFFSET $5",
    )
        .bind(period_from)
        .bind(period_to)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        let id: Uuid = r.try_get("id").map_err(db)?;
        items.push(json!({"id":id,"periodStart":r.try_get::<time::Date,_>("period_start").map_err(db)?.to_string(),"periodEnd":r.try_get::<time::Date,_>("period_end").map_err(db)?.to_string(),"title":r.try_get::<String,_>("title").map_err(db)?,"summary":r.try_get::<String,_>("summary").map_err(db)?,"publishedAt":timestamp(r.try_get("published_at").map_err(db)?)?,"href":format!("/transparency-reports/{id}")}));
    }
    let mut filters = Map::new();
    for name in ["periodFrom", "periodTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page(items, query, Value::Object(filters))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn db(_: sqlx::Error) -> ServiceError {
    ServiceError::Persistence
}

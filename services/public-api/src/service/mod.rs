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
    let body = match dispatch_content(operation)? {
        Some(body) => body,
        None => dispatch_query(operation, request, state, &query).await?,
    };
    Ok(Output {
        status: 200,
        media_type: "application/json",
        body,
    })
}

fn dispatch_content(operation: &str) -> Result<Option<Value>, ServiceError> {
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
        _ => return Ok(None),
    };
    Ok(Some(body))
}

async fn dispatch_query(
    operation: &str,
    request: &HttpRequest,
    state: &AppState,
    query: &Query,
) -> Result<Value, ServiceError> {
    match operation {
        "listAgencies"
        | "getAgency"
        | "listAgencyCases"
        | "listAgencyContracts"
        | "listSuppliers"
        | "getSupplier"
        | "listSupplierCases"
        | "listSupplierContracts"
        | "listContracts"
        | "getContract"
        | "listContractChanges"
        | "downloadContracts" => dispatch_entities(operation, request, state, query).await,
        "listPublicCases"
        | "getPublicCase"
        | "listCaseRevisions"
        | "getPublicCaseRevision"
        | "getCaseReproducibility"
        | "downloadCaseReproducibility"
        | "listCorrections"
        | "getCorrection"
        | "getCoverage" => dispatch_cases(operation, request, state, query).await,
        "listPublicDatasets" | "listRules" | "getRule" | "listRuleCases" => {
            dispatch_rules(operation, request, state, query).await
        }
        "listSourceStatus"
        | "getSource"
        | "searchPublicRecords"
        | "getPublicSystemStatus"
        | "listTransparencyReports" => dispatch_public(operation, request, state, query).await,
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn dispatch_entities(
    operation: &str,
    request: &HttpRequest,
    state: &AppState,
    query: &Query,
) -> Result<Value, ServiceError> {
    match operation {
        "listAgencies" => list_agencies(&state.pool, query).await,
        "getAgency" => get_agency(&state.pool, path_uuid(request, "agencyId")?).await,
        "listAgencyCases" => {
            list_related_cases(
                &state.pool,
                query,
                "agency",
                path_uuid(request, "agencyId")?,
            )
            .await
        }
        "listAgencyContracts" => {
            list_contracts(
                &state.pool,
                query,
                Some(("agency", path_uuid(request, "agencyId")?)),
            )
            .await
        }
        "listSuppliers" => list_suppliers(&state.pool, query).await,
        "getSupplier" => get_supplier(&state.pool, path_uuid(request, "supplierId")?).await,
        "listSupplierCases" => {
            list_related_cases(
                &state.pool,
                query,
                "supplier",
                path_uuid(request, "supplierId")?,
            )
            .await
        }
        "listSupplierContracts" => {
            list_contracts(
                &state.pool,
                query,
                Some(("supplier", path_uuid(request, "supplierId")?)),
            )
            .await
        }
        "listContracts" => list_contracts(&state.pool, query, None).await,
        "getContract" => get_contract(&state.pool, path_uuid(request, "contractId")?).await,
        "listContractChanges" => {
            list_contract_changes(&state.pool, query, path_uuid(request, "contractId")?).await
        }
        "downloadContracts" => download_contracts(&state.pool, query).await,
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn dispatch_cases(
    operation: &str,
    request: &HttpRequest,
    state: &AppState,
    query: &Query,
) -> Result<Value, ServiceError> {
    match operation {
        "listPublicCases" => list_cases(&state.pool, query, None).await,
        "getPublicCase" => get_case(&state.pool, path(request, "caseSlug")?).await,
        "listCaseRevisions" => list_revisions(&state.pool, query, path(request, "caseSlug")?).await,
        "getPublicCaseRevision" => {
            let revision = path(request, "revision")?
                .parse()
                .map_err(|_| ServiceError::InvalidRequest)?;
            get_revision(&state.pool, path(request, "caseSlug")?, revision).await
        }
        "getCaseReproducibility" => reproducibility(&state.pool, path(request, "caseSlug")?).await,
        "downloadCaseReproducibility" => {
            download_reproducibility(&state.pool, path(request, "caseSlug")?, query).await
        }
        "listCorrections" => list_corrections(&state.pool, query).await,
        "getCorrection" => get_correction(&state.pool, path_uuid(request, "correctionId")?).await,
        "getCoverage" => coverage(&state.pool).await,
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn dispatch_rules(
    operation: &str,
    request: &HttpRequest,
    state: &AppState,
    query: &Query,
) -> Result<Value, ServiceError> {
    match operation {
        "listPublicDatasets" => list_datasets(&state.pool, query).await,
        "listRules" => list_rules(&state.pool, query).await,
        "getRule" => get_rule(&state.pool, path(request, "ruleId")?).await,
        "listRuleCases" => {
            list_cases(&state.pool, query, Some(("rule", path(request, "ruleId")?))).await
        }
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn dispatch_public(
    operation: &str,
    request: &HttpRequest,
    state: &AppState,
    query: &Query,
) -> Result<Value, ServiceError> {
    match operation {
        "listSourceStatus" => list_sources(&state.pool, query).await,
        "getSource" => get_source(&state.pool, path(request, "sourceId")?).await,
        "searchPublicRecords" => search(&state.pool, query).await,
        "getPublicSystemStatus" => system_status(&state.pool).await,
        "listTransparencyReports" => list_reports(&state.pool, query).await,
        _ => Err(ServiceError::InvalidRequest),
    }
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

include!("entities.rs");
include!("cases.rs");
include!("public_tail.rs");

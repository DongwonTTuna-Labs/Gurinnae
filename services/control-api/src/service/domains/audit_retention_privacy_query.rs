use super::*;

#[path = "audit_retention_privacy_validation.rs"]
mod validation;

const REQUEST_TYPES: &[&str] = &["ACCESS", "CORRECTION", "DELETION", "RESTRICTION"];
const REQUEST_STATES: &[&str] = &["RECEIVED", "REVIEW", "APPROVED", "REJECTED", "COMPLETED"];
const FILTER_KEYS: &[&str] = &[
    "requestType",
    "state",
    "dueBefore",
    "legalHoldBlocked",
    "cursor",
    "limit",
    "sort",
];

pub(super) async fn get(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    if parameters.len() != 1 {
        return Err(ServiceError::InvalidRequest);
    }
    let request_id = parameters
        .get("retentionRequestId")
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)?;
    let workspace = sqlx::query_scalar!(
        "SELECT ops.read_privacy_retention_request_workspace_v2($1)",
        request_id,
    )
    .fetch_optional(pool)
    .await
    .map_err(map_privacy_reader_error)?
    .flatten()
    .ok_or(ServiceError::NotFound)?;
    validation::validate_workspace(&workspace)?;
    Ok(workspace)
}

pub(super) async fn list(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let filters = RetentionQueueFilters::parse(parameters)?;
    let owner_filters = filters.owner_payload();
    let page = sqlx::query_scalar!(
        "SELECT ops.read_privacy_retention_request_queue_v2($1::jsonb)",
        &owner_filters,
    )
    .fetch_one(pool)
    .await
    .map_err(map_privacy_reader_error)?
    .ok_or(ServiceError::Persistence)?;
    validation::validate_queue_page(&page, &filters.applied_filters(), filters.sort)?;
    Ok(page)
}

fn map_privacy_reader_error(error: sqlx::Error) -> ServiceError {
    let sqlstate = error
        .as_database_error()
        .and_then(sqlx::error::DatabaseError::code)
        .map(|code| code.into_owned());
    if let Some(classification) = privacy_reader_error(sqlstate.as_deref()) {
        tracing::error!(
            sql_state = "55000",
            classification = ?classification,
            "privacy request safe-reader authority is unavailable"
        );
        classification
    } else {
        db(error)
    }
}

fn privacy_reader_error(sqlstate: Option<&str>) -> Option<ServiceError> {
    match sqlstate {
        Some("55000") => Some(ServiceError::DependencyUnavailable),
        _ => None,
    }
}

struct RetentionQueueFilters {
    request_types: Vec<String>,
    states: Vec<String>,
    due_before: Option<String>,
    legal_hold_blocked: Option<bool>,
    cursor: Option<String>,
    limit: i64,
    sort: &'static str,
}

impl RetentionQueueFilters {
    fn parse(parameters: &BTreeMap<String, String>) -> Result<Self, ServiceError> {
        if parameters
            .keys()
            .any(|key| !FILTER_KEYS.contains(&key.as_str()))
        {
            return Err(ServiceError::InvalidRequest);
        }
        let request_types = parse_enum_list(parameters.get("requestType"), REQUEST_TYPES)?;
        let states = parse_enum_list(parameters.get("state"), REQUEST_STATES)?;
        let due_before = parameters
            .get("dueBefore")
            .map(|value| {
                OffsetDateTime::parse(value, &Rfc3339)
                    .map(|_| value.clone())
                    .map_err(|_| ServiceError::InvalidRequest)
            })
            .transpose()?;
        let legal_hold_blocked = parameters
            .get("legalHoldBlocked")
            .map(|value| match value.as_str() {
                "true" => Ok(true),
                "false" => Ok(false),
                _ => Err(ServiceError::InvalidRequest),
            })
            .transpose()?;
        let cursor = parameters
            .get("cursor")
            .map(|value| {
                let length = value.chars().count();
                if value.trim() == value && (1..=4_096).contains(&length) {
                    Ok(value.clone())
                } else {
                    Err(ServiceError::InvalidRequest)
                }
            })
            .transpose()?;
        let limit = parameters.get("limit").map_or(Ok(20_i64), |value| {
            value
                .parse::<i64>()
                .ok()
                .filter(|value| (1..=100).contains(value))
                .ok_or(ServiceError::InvalidRequest)
        })?;
        let sort = match parameters.get("sort").map(String::as_str) {
            None | Some("DUE_ASC") => "DUE_ASC",
            Some("CREATED_DESC") => "CREATED_DESC",
            Some(_) => return Err(ServiceError::InvalidRequest),
        };
        Ok(Self {
            request_types,
            states,
            due_before,
            legal_hold_blocked,
            cursor,
            limit,
            sort,
        })
    }

    fn owner_payload(&self) -> Value {
        json!({
            "requestType": self.request_types,
            "state": self.states,
            "dueBefore": self.due_before,
            "legalHoldBlocked": self.legal_hold_blocked,
            "cursor": self.cursor,
            "limit": self.limit,
            "sort": self.sort,
        })
    }

    fn applied_filters(&self) -> Value {
        json!({
            "requestType": self.request_types,
            "state": self.states,
            "dueBefore": self.due_before,
            "legalHoldBlocked": self.legal_hold_blocked,
            "sort": self.sort,
        })
    }
}

fn parse_enum_list(raw: Option<&String>, allowed: &[&str]) -> Result<Vec<String>, ServiceError> {
    let Some(raw) = raw else {
        return Ok(Vec::new());
    };
    let values = raw.split(',').collect::<Vec<_>>();
    if values.is_empty()
        || values.len() > allowed.len()
        || values
            .iter()
            .any(|value| value.is_empty() || !allowed.contains(value))
    {
        return Err(ServiceError::InvalidRequest);
    }
    let unique = values
        .iter()
        .copied()
        .collect::<std::collections::BTreeSet<_>>();
    if unique.len() != values.len() {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(values.into_iter().map(str::to_owned).collect())
}

#[cfg(test)]
#[path = "audit_retention_privacy_query_tests.rs"]
mod tests;

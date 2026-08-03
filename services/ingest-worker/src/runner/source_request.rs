use std::collections::BTreeMap;

use gurine_source_connectors::ConnectorOperation;
use reqwest::{Client, StatusCode, Url};
use serde_json::Value;

use super::{Failure, SourceResponse, sha256};

pub(super) fn with_operation_parameters(
    target: &str,
    operation: &ConnectorOperation,
    configuration: &Value,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
) -> Result<String, Failure> {
    let mut url = Url::parse(target)
        .map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", operation.id.into()))?;
    let mut parameters = url.query_pairs().into_owned().collect::<BTreeMap<_, _>>();
    append_configured_parameters(&mut parameters, operation, configuration)?;
    reject_credential_parameters(&parameters, operation)?;
    parameters.insert("operationId".to_owned(), operation.id.to_owned());
    append_pagination_parameters(&mut parameters, operation);
    match operation.connector_id {
        "koneps-contracts" | "koneps-notices" | "koneps-bid-results" => {
            append_koneps_window(&mut parameters, operation, requested_from, requested_to)?;
        }
        "open-dart" => {
            append_open_dart_parameters(&mut parameters, operation, requested_from, requested_to)?
        }
        _ => append_generic_date_range(&mut parameters, requested_from, requested_to),
    }
    url.set_query(None);
    url.query_pairs_mut().extend_pairs(parameters);
    Ok(url.to_string())
}

fn append_configured_parameters(
    parameters: &mut BTreeMap<String, String>,
    operation: &ConnectorOperation,
    configuration: &Value,
) -> Result<(), Failure> {
    let Some(values) = configuration
        .pointer(&format!("/parameters/{}", operation.id))
        .and_then(Value::as_object)
    else {
        return Ok(());
    };
    for (key, value) in values {
        let value = value.as_str().ok_or_else(|| {
            Failure::Terminal(
                "SOURCE_REQUEST_PARAMETERS_INVALID",
                format!("{}:{key}", operation.id),
            )
        })?;
        if value.trim().is_empty() {
            return Err(Failure::Terminal(
                "SOURCE_REQUEST_PARAMETERS_INVALID",
                format!("{}:{key}", operation.id),
            ));
        }
        parameters.insert(key.to_owned(), value.to_owned());
    }
    Ok(())
}

fn reject_credential_parameters(
    parameters: &BTreeMap<String, String>,
    operation: &ConnectorOperation,
) -> Result<(), Failure> {
    for credential in ["serviceKey", "crtfc_key"] {
        if parameters.contains_key(credential) {
            return Err(invalid_parameters(operation, credential));
        }
    }
    Ok(())
}

fn append_pagination_parameters(
    parameters: &mut BTreeMap<String, String>,
    operation: &ConnectorOperation,
) {
    if operation.pagination != "page-number" {
        return;
    }
    if operation.connector_id == "open-dart" {
        parameters.insert("page_no".to_owned(), "1".to_owned());
        parameters.insert("page_count".to_owned(), "100".to_owned());
    } else {
        parameters.insert("pageNo".to_owned(), "1".to_owned());
        parameters.insert("numOfRows".to_owned(), "1000".to_owned());
        parameters.insert("type".to_owned(), "json".to_owned());
    }
}

fn append_koneps_window(
    parameters: &mut BTreeMap<String, String>,
    operation: &ConnectorOperation,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
) -> Result<(), Failure> {
    let from = requested_from.filter(|from| requested_to.is_some_and(|to| *from <= to));
    let (Some(from), Some(to)) = (from, requested_to) else {
        return Err(Failure::Terminal(
            "SOURCE_REQUEST_PARAMETERS_INVALID",
            format!("{}:date-window", operation.id),
        ));
    };
    parameters.insert("inqryDiv".to_owned(), "1".to_owned());
    parameters.insert("inqryBgnDt".to_owned(), koneps_datetime(from, "0000"));
    parameters.insert("inqryEndDt".to_owned(), koneps_datetime(to, "2359"));
    Ok(())
}

fn koneps_datetime(date: time::Date, clock: &str) -> String {
    format!("{}{clock}", date.to_string().replace('-', ""))
}

fn append_generic_date_range(
    parameters: &mut BTreeMap<String, String>,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
) {
    if let Some(value) = requested_from {
        parameters.insert("from".to_owned(), value.to_string());
    }
    if let Some(value) = requested_to {
        parameters.insert("to".to_owned(), value.to_string());
    }
}

struct OpenDartReportParameters<'a> {
    corporation_code: &'a str,
    business_year: &'a str,
    report_code: &'a str,
}

impl<'a> OpenDartReportParameters<'a> {
    fn parse(
        operation: &ConnectorOperation,
        parameters: &'a BTreeMap<String, String>,
    ) -> Result<Self, Failure> {
        let required = |name: &str| {
            parameters.get(name).map(String::as_str).ok_or_else(|| {
                Failure::Terminal(
                    "SOURCE_REQUEST_PARAMETERS_INVALID",
                    format!("{}:{name}", operation.id),
                )
            })
        };
        let parsed = Self {
            corporation_code: required("corp_code")?,
            business_year: required("bsns_year")?,
            report_code: required("reprt_code")?,
        };
        if !ascii_digits(parsed.corporation_code, 8)
            || !ascii_digits(parsed.business_year, 4)
            || !matches!(parsed.report_code, "11011" | "11012" | "11013" | "11014")
        {
            return Err(Failure::Terminal(
                "SOURCE_REQUEST_PARAMETERS_INVALID",
                operation.id.to_owned(),
            ));
        }
        Ok(parsed)
    }
}

fn validate_open_dart_parameters(
    operation: &ConnectorOperation,
    parameters: &BTreeMap<String, String>,
) -> Result<(), Failure> {
    match operation.id {
        "dart-corp-code" | "dart-disclosures" => {}
        "dart-company" => validate_corporation_code(operation, parameters)?,
        "dart-financial-statements" => {
            let _ = OpenDartReportParameters::parse(operation, parameters)?;
            let statement = required_parameter(operation, parameters, "fs_div")?;
            if !matches!(statement, "CFS" | "OFS") {
                return Err(invalid_parameters(operation, "fs_div"));
            }
        }
        "dart-executive-status" | "dart-major-shareholder-status" => {
            let _ = OpenDartReportParameters::parse(operation, parameters)?;
        }
        _ => return Err(invalid_parameters(operation, "operation")),
    }
    Ok(())
}

fn append_open_dart_parameters(
    parameters: &mut BTreeMap<String, String>,
    operation: &ConnectorOperation,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
) -> Result<(), Failure> {
    if operation.id == "dart-disclosures" {
        let from = requested_from.filter(|from| requested_to.is_some_and(|to| *from <= to));
        let (Some(from), Some(to)) = (from, requested_to) else {
            return Err(invalid_parameters(operation, "date-window"));
        };
        parameters.insert("bgn_de".to_owned(), compact_date(from));
        parameters.insert("end_de".to_owned(), compact_date(to));
        if parameters.contains_key("corp_code") {
            validate_corporation_code(operation, parameters)?;
        }
    }
    validate_open_dart_parameters(operation, parameters)
}

fn validate_corporation_code(
    operation: &ConnectorOperation,
    parameters: &BTreeMap<String, String>,
) -> Result<(), Failure> {
    let corporation_code = required_parameter(operation, parameters, "corp_code")?;
    if !ascii_digits(corporation_code, 8) {
        return Err(invalid_parameters(operation, "corp_code"));
    }
    Ok(())
}

fn required_parameter<'a>(
    operation: &ConnectorOperation,
    parameters: &'a BTreeMap<String, String>,
    name: &str,
) -> Result<&'a str, Failure> {
    parameters
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| invalid_parameters(operation, name))
}

fn invalid_parameters(operation: &ConnectorOperation, field: &str) -> Failure {
    Failure::Terminal(
        "SOURCE_REQUEST_PARAMETERS_INVALID",
        format!("{}:{field}", operation.id),
    )
}

fn compact_date(date: time::Date) -> String {
    date.to_string().replace('-', "")
}

fn ascii_digits(value: &str, length: usize) -> bool {
    value.len() == length && value.bytes().all(|byte| byte.is_ascii_digit())
}

pub(super) struct SourceFetchRequest<'a> {
    source_id: &'a str,
    target: &'a str,
    request_sha256: String,
}

impl<'a> SourceFetchRequest<'a> {
    pub(super) fn get(source_id: &'a str, target: &'a str) -> Self {
        Self {
            source_id,
            target,
            // Source connector fetches are GET requests with an exact empty body. The gateway
            // receipt separately binds this body digest and the complete credential-free target.
            request_sha256: sha256(b""),
        }
    }
}

pub(super) async fn fetch_source(
    client: &Client,
    gateway: &Url,
    request: &SourceFetchRequest<'_>,
) -> Result<SourceResponse, Failure> {
    let response = source_fetch_request(client, gateway, request)
        .send()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_UNAVAILABLE", error.to_string()))?;
    let status = response.status();
    if status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
        return Err(Failure::Retryable("SOURCE_UNAVAILABLE", status.to_string()));
    }
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        return Err(Failure::Terminal(
            "SOURCE_AUTHORIZATION_FAILED",
            status.to_string(),
        ));
    }
    if !status.is_success() {
        return Err(Failure::Terminal(
            "SOURCE_REQUEST_REJECTED",
            status.to_string(),
        ));
    }
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("application/octet-stream")
        .split(';')
        .next()
        .unwrap_or("application/octet-stream")
        .to_owned();
    let bytes = response
        .bytes()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_UNAVAILABLE", error.to_string()))?;
    if bytes.len() > 67_108_864 {
        return Err(Failure::Terminal(
            "SOURCE_PAYLOAD_TOO_LARGE",
            bytes.len().to_string(),
        ));
    }
    Ok(SourceResponse {
        bytes: bytes.to_vec(),
        content_type,
        http_status: status.as_u16(),
    })
}

fn source_fetch_request(
    client: &Client,
    gateway: &Url,
    request: &SourceFetchRequest<'_>,
) -> reqwest::RequestBuilder {
    client
        .get(gateway.clone())
        .header("x-gurine-egress-caller", "ingest-worker")
        .header("x-gurine-source-id", request.source_id)
        .header("x-gurine-egress-target", request.target)
        .header(
            "x-gurine-source-fetch-request-sha256",
            &request.request_sha256,
        )
}

#[cfg(test)]
#[path = "tests/source_request.rs"]
mod tests;

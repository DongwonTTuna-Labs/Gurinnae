use std::collections::BTreeMap;

use reqwest::{Client, Url};
use serde_json::{Value, json};
use time::{Date, Month};

use super::super::{ConnectorOperation, Failure, operation_target, operations};
use super::{SourceFetchRequest, source_fetch_request, with_operation_parameters};

fn operation(id: &str) -> &'static ConnectorOperation {
    operations()
        .find(|operation| operation.id == id)
        .expect("operation must remain in the closed connector catalog")
}

fn date(day: u8) -> Date {
    Date::from_calendar_date(2026, Month::July, day).expect("valid fixture date")
}

fn query(target: &str) -> BTreeMap<String, String> {
    Url::parse(target)
        .expect("valid target")
        .query_pairs()
        .into_owned()
        .collect()
}

fn success<T>(result: Result<T, Failure>) -> T {
    match result {
        Ok(value) => value,
        Err(_) => panic!("request fixture must satisfy the closed contract"),
    }
}

#[test]
fn operation_target_preserves_the_complete_base_service_path() {
    let contract_target = success(operation_target(
        operation("contract-goods-list"),
        Some("https://apis.data.go.kr/1230000/ao/CntrctInfoService"),
        &json!({}),
    ));
    assert_eq!(
        contract_target,
        "https://apis.data.go.kr/1230000/ao/CntrctInfoService/getCntrctInfoListThng"
    );
    let dart_target = success(operation_target(
        operation("dart-executive-status"),
        Some("https://opendart.fss.or.kr/api"),
        &json!({}),
    ));
    assert_eq!(
        dart_target,
        "https://opendart.fss.or.kr/api/exctvSttus.json"
    );
}

#[test]
fn koneps_request_uses_the_declared_calendar_window_parameters() {
    let target = success(with_operation_parameters(
        "https://nopenapi.g2b.go.kr/as/ScsbidInfoService/getOpengResultListInfoThngPPSSrch",
        operation("opening-goods-search"),
        &json!({"parameters":{"opening-goods-search":{"inqryDiv":"2"}}}),
        Some(date(1)),
        Some(date(12)),
    ));
    let parameters = query(&target);
    assert_eq!(parameters.get("inqryDiv").map(String::as_str), Some("1"));
    assert_eq!(
        parameters.get("inqryBgnDt").map(String::as_str),
        Some("202607010000")
    );
    assert_eq!(
        parameters.get("inqryEndDt").map(String::as_str),
        Some("202607122359")
    );
    assert!(!parameters.contains_key("from"));
    assert!(!parameters.contains_key("to"));
}

#[test]
fn koneps_request_rejects_missing_or_reversed_windows() {
    let operation = operation("opening-goods-search");
    let invalid = |from, to| {
        with_operation_parameters(
            "https://nopenapi.g2b.go.kr/as/ScsbidInfoService/getOpengResultListInfoThngPPSSrch",
            operation,
            &json!({}),
            from,
            to,
        )
    };
    assert!(matches!(
        invalid(None, Some(date(12))),
        Err(Failure::Terminal("SOURCE_REQUEST_PARAMETERS_INVALID", _))
    ));
    assert!(matches!(
        invalid(Some(date(12)), Some(date(1))),
        Err(Failure::Terminal("SOURCE_REQUEST_PARAMETERS_INVALID", _))
    ));
}

#[test]
fn dart_context_requests_require_closed_report_parameters() {
    let configuration = json!({
        "parameters": {
            "dart-executive-status": {
                "corp_code": "00990001", "bsns_year": "2026", "reprt_code": "11011"
            },
            "dart-major-shareholder-status": {
                "corp_code": "00990001", "bsns_year": "2026", "reprt_code": "11014"
            }
        }
    });
    for operation_id in ["dart-executive-status", "dart-major-shareholder-status"] {
        let target = success(with_operation_parameters(
            "https://opendart.fss.or.kr/api/context.json",
            operation(operation_id),
            &configuration,
            Some(date(1)),
            Some(date(12)),
        ));
        let parameters = query(&target);
        assert_eq!(
            parameters.get("corp_code").map(String::as_str),
            Some("00990001")
        );
        assert_eq!(
            parameters.get("bsns_year").map(String::as_str),
            Some("2026")
        );
        assert!(matches!(
            parameters.get("reprt_code").map(String::as_str),
            Some("11011" | "11014")
        ));
    }
}

#[test]
fn dart_context_requests_fail_closed_on_missing_or_invalid_parameters() {
    for configuration in [
        json!({}),
        json!({"parameters":{"dart-executive-status":{
            "corp_code":"short","bsns_year":"2026","reprt_code":"11011"
        }}}),
        json!({"parameters":{"dart-executive-status":{
            "corp_code":"00990001","bsns_year":"2026","reprt_code":"99999"
        }}}),
    ] {
        assert!(matches!(
            with_operation_parameters(
                "https://opendart.fss.or.kr/api/exctvSttus.json",
                operation("dart-executive-status"),
                &configuration,
                Some(date(1)),
                Some(date(12)),
            ),
            Err(Failure::Terminal("SOURCE_REQUEST_PARAMETERS_INVALID", _))
        ));
    }
}

#[test]
fn all_open_dart_operations_close_their_required_caller_parameters() {
    let configuration = json!({"parameters":{
        "dart-company":{"corp_code":"00990001"},
        "dart-financial-statements":{
            "corp_code":"00990001","bsns_year":"2026","reprt_code":"11011","fs_div":"CFS"
        }
    }});
    let company = success(with_operation_parameters(
        "https://opendart.fss.or.kr/api/company.json",
        operation("dart-company"),
        &configuration,
        Some(date(1)),
        Some(date(12)),
    ));
    assert_eq!(
        query(&company).get("corp_code").map(String::as_str),
        Some("00990001")
    );
    let disclosures = success(with_operation_parameters(
        "https://opendart.fss.or.kr/api/list.json",
        operation("dart-disclosures"),
        &json!({}),
        Some(date(1)),
        Some(date(12)),
    ));
    assert_eq!(
        query(&disclosures).get("bgn_de").map(String::as_str),
        Some("20260701")
    );
    let financial = success(with_operation_parameters(
        "https://opendart.fss.or.kr/api/fnlttSinglAcntAll.json",
        operation("dart-financial-statements"),
        &configuration,
        Some(date(1)),
        Some(date(12)),
    ));
    assert_eq!(
        query(&financial).get("fs_div").map(String::as_str),
        Some("CFS")
    );
    for (id, configuration, from) in [
        ("dart-company", json!({}), Some(date(1))),
        (
            "dart-financial-statements",
            json!({"parameters":{"dart-financial-statements":{"corp_code":"00990001"}}}),
            Some(date(1)),
        ),
        ("dart-disclosures", json!({}), None),
    ] {
        assert!(matches!(
            with_operation_parameters(
                "https://opendart.fss.or.kr/api/operation.json",
                operation(id),
                &configuration,
                from,
                Some(date(12)),
            ),
            Err(Failure::Terminal("SOURCE_REQUEST_PARAMETERS_INVALID", _))
        ));
    }
}

#[test]
fn source_get_request_binds_the_empty_body_digest_header() {
    let target = "https://opendart.fss.or.kr/api/exctvSttus.json?corp_code=00990001";
    let request = SourceFetchRequest::get("open-dart", target);
    assert_eq!(
        request.request_sha256,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    let gateway = Url::parse("http://127.0.0.1:24567/source").expect("gateway URL");
    let built = source_fetch_request(&Client::new(), &gateway, &request)
        .build()
        .expect("request build");
    assert_eq!(
        built
            .headers()
            .get("x-gurine-source-fetch-request-sha256")
            .and_then(|value| value.to_str().ok()),
        Some(request.request_sha256.as_str())
    );
    assert_eq!(
        built
            .headers()
            .get("x-gurine-egress-target")
            .and_then(|value| value.to_str().ok()),
        Some(target)
    );
}

#[test]
fn configured_parameters_must_be_non_empty_strings() {
    for value in [Value::Null, json!(1), json!(" ")] {
        let configuration = json!({
            "parameters": {"dart-executive-status": {"corp_code": value}}
        });
        assert!(matches!(
            with_operation_parameters(
                "https://opendart.fss.or.kr/api/exctvSttus.json",
                operation("dart-executive-status"),
                &configuration,
                Some(date(1)),
                Some(date(12)),
            ),
            Err(Failure::Terminal("SOURCE_REQUEST_PARAMETERS_INVALID", _))
        ));
    }
}

#[test]
fn source_targets_never_accept_caller_supplied_credentials() {
    for (target, operation_id, configuration) in [
        (
            "https://apis.data.go.kr/1230000/ao/CntrctInfoService/getCntrctInfoListThng?serviceKey=leaked",
            "contract-goods-list",
            json!({}),
        ),
        (
            "https://opendart.fss.or.kr/api/company.json",
            "dart-company",
            json!({"parameters":{"dart-company":{
                "corp_code":"00990001","crtfc_key":"leaked"
            }}}),
        ),
    ] {
        assert!(matches!(
            with_operation_parameters(
                target,
                operation(operation_id),
                &configuration,
                Some(date(1)),
                Some(date(12)),
            ),
            Err(Failure::Terminal("SOURCE_REQUEST_PARAMETERS_INVALID", _))
        ));
    }
}

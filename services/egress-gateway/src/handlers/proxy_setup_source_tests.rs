use std::collections::{BTreeMap, BTreeSet};

use actix_web::test::TestRequest;

use super::*;
use crate::config::Config;

fn state() -> GatewayState {
    GatewayState {
        config: Config {
            bind: "127.0.0.1:0".to_owned(),
            environment: "production".to_owned(),
            oidc_issuer_host: "issuer.example".to_owned(),
            source_hosts: BTreeSet::from([
                "nopenapi.g2b.go.kr".to_owned(),
                "opendart.fss.or.kr".to_owned(),
            ]),
            source_host_bindings: BTreeMap::from([
                (
                    "koneps-bid-results".to_owned(),
                    "nopenapi.g2b.go.kr".to_owned(),
                ),
                ("open-dart".to_owned(), "opendart.fss.or.kr".to_owned()),
            ]),
            public_research_hosts: BTreeSet::new(),
            ai_hosts: BTreeSet::new(),
            challenge_hosts: BTreeSet::new(),
            communication_hosts: BTreeSet::new(),
            object_store: None,
            smtp_url: None,
            data_go_kr_service_key: Some("koneps-key".to_owned()),
            open_dart_api_key: Some("dart-key".to_owned()),
            brave_search_api_key: None,
            ai_relay_host: "relay-ai.dongwontuna.net".to_owned(),
            ai_relay_api_key: None,
            openai_api_key: None,
            anthropic_api_key: None,
            google_api_key: None,
            database_url: None,
        },
        object_store: None,
        smtp: None,
        database: None,
    }
}

fn request(source_id: &str) -> HttpRequest {
    TestRequest::default()
        .insert_header(("x-gurine-source-id", source_id))
        .to_http_request()
}

#[test]
fn koneps_bid_results_binds_the_data_go_kr_key_on_the_exact_host() -> Result<(), String> {
    let state = state();
    let mut target = Url::parse(
        "https://nopenapi.g2b.go.kr/as/ScsbidInfoService/getScsbidListSttusThngPPSSrch?pageNo=1",
    )
    .map_err(|error| error.to_string())?;

    let credential = bind_source_credential(
        &request("koneps-bid-results"),
        &mut target,
        &state,
        "nopenapi.g2b.go.kr",
    )?;

    assert!(credential.is_none());
    let query = target.query_pairs().collect::<BTreeMap<_, _>>();
    assert_eq!(
        query.get("serviceKey").map(|value| value.as_ref()),
        Some("koneps-key")
    );
    assert_eq!(query.get("pageNo").map(|value| value.as_ref()), Some("1"));
    Ok(())
}

#[test]
fn source_connectors_reject_caller_supplied_query_credentials() -> Result<(), String> {
    let state = state();
    for (source_id, host, target) in [
        (
            "koneps-bid-results",
            "nopenapi.g2b.go.kr",
            "https://nopenapi.g2b.go.kr/as/ScsbidInfoService/getScsbidListSttusThngPPSSrch?serviceKey=caller-value",
        ),
        (
            "open-dart",
            "opendart.fss.or.kr",
            "https://opendart.fss.or.kr/api/company.json?crtfc_key=caller-value",
        ),
    ] {
        let mut target = Url::parse(target).map_err(|error| error.to_string())?;
        assert!(matches!(
            reject_caller_source_query_secret(&request(source_id), &target),
            Err("EGRESS_CALLER_CREDENTIAL_DENIED")
        ));
        assert!(matches!(
            bind_source_credential(&request(source_id), &mut target, &state, host),
            Err("EGRESS_CALLER_CREDENTIAL_DENIED")
        ));
    }
    Ok(())
}

#[test]
fn bid_results_rejects_other_hosts_and_sanctions_stays_unbound() -> Result<(), String> {
    let state = state();
    let mut target =
        Url::parse("https://data.g2b.go.kr/other").map_err(|error| error.to_string())?;

    assert!(matches!(
        bind_source_credential(
            &request("koneps-bid-results"),
            &mut target,
            &state,
            "data.g2b.go.kr"
        ),
        Err("EGRESS_SOURCE_HOST_MISMATCH")
    ));
    assert!(matches!(
        bind_source_credential(
            &request("pps-sanctions"),
            &mut target,
            &state,
            "data.g2b.go.kr"
        ),
        Err("EGRESS_SOURCE_ID_DENIED")
    ));
    Ok(())
}

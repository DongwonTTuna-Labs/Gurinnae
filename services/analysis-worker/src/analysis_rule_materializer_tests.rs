use super::*;

fn member(ordinal: i64, object_type: &str, object_id: Uuid, payload: Value) -> SnapshotMember {
    let mut canonical_payload = payload.as_object().cloned().unwrap_or_default();
    canonical_payload.insert(
        "objectType".to_owned(),
        Value::String(object_type.to_owned()),
    );
    canonical_payload.insert("objectId".to_owned(), Value::String(object_id.to_string()));
    canonical_payload.insert("objectVersion".to_owned(), Value::from(1));
    SnapshotMember {
        ordinal,
        member_digest: format!("{ordinal:064x}"),
        object_type: object_type.to_owned(),
        object_id,
        object_version: 1,
        canonical_payload: Value::Object(canonical_payload),
    }
}

#[test]
fn same_snapshot_materializes_same_canonical_input_regardless_of_query_order() {
    let first_id = Uuid::from_u128(1);
    let second_id = Uuid::from_u128(2);
    let first = member(
        0,
        "CONTRACT",
        first_id,
        json!({
            "agencyId": Uuid::from_u128(10),
            "supplierId": Uuid::from_u128(20),
            "normalizedCategory": "OFFICE",
            "signedAt": "2026-01-02",
            "currentAmount": "10000000",
            "procurementMethod": "SINGLE_SOURCE",
            "legitimatePhase": false,
        }),
    );
    let second = member(
        1,
        "CONTRACT",
        second_id,
        json!({
            "agencyId": Uuid::from_u128(10),
            "supplierId": Uuid::from_u128(20),
            "normalizedCategory": "OFFICE",
            "signedAt": "2026-01-03",
            "currentAmount": "11000000",
            "procurementMethod": "SINGLE_SOURCE",
            "legitimatePhase": false,
        }),
    );
    let configuration = json!({"windowDays": 30});
    let forward = materialize_rule_input(
        "REPEATED_SINGLE_SOURCE",
        &configuration,
        &[first.clone(), second.clone()],
        &[],
    );
    let reverse = materialize_rule_input(
        "REPEATED_SINGLE_SOURCE",
        &configuration,
        &[second, first],
        &[],
    );
    assert!(
        matches!((&forward, &reverse), (Ok(left), Ok(right)) if left.input_sha256 == right.input_sha256 && left.value == right.value)
    );
    let evaluated = forward.as_ref().ok().and_then(|input| {
        gurine_detection::engine::evaluate("REPEATED_SINGLE_SOURCE", &input.value).ok()
    });
    assert!(
        matches!((forward, evaluated), (Ok(input), Some(result)) if result.get("input_hash").and_then(Value::as_str) == Some(input.input_sha256.as_str()))
    );
}

#[test]
fn shared_identity_uses_only_proven_verified_strong_identifier_facts() {
    let supplier_id = Uuid::from_u128(30);
    let contracts = [member(
        0,
        "CONTRACT",
        Uuid::from_u128(32),
        json!({
            "agencyId": Uuid::from_u128(33),
            "supplierId": supplier_id,
        }),
    )];
    let facts = shared_identity_facts(supplier_id);
    let result = materialize_rule_input("SHARED_SUPPLIER_IDENTITY", &json!({}), &contracts, &facts);
    assert!(
        matches!(result, Ok(materialized) if materialized.value.pointer("/suppliers") == Some(&json!([{
            "id": supplier_id,
            "strong_identifier_hashes": [format!("KOREAN_BUSINESS_NUMBER:{}", "a".repeat(64))],
        }])) && materialized.value.pointer("/contracts/0/supplier_id") == Some(&json!(supplier_id)))
    );
}

fn shared_identity_facts(supplier_id: Uuid) -> [StrongIdentifierFact; 6] {
    [
        StrongIdentifierFact {
            supplier_id,
            scheme: "KOREAN_BUSINESS_NUMBER".to_owned(),
            value_hash: "a".repeat(64),
            verification_status: "VERIFIED".to_owned(),
            proof_state: "PROVEN_V1".to_owned(),
        },
        StrongIdentifierFact {
            supplier_id,
            scheme: "DART_CORP_CODE".to_owned(),
            value_hash: "b".repeat(64),
            verification_status: "UNVERIFIED".to_owned(),
            proof_state: "PROVEN_V1".to_owned(),
        },
        StrongIdentifierFact {
            supplier_id: Uuid::from_u128(31),
            scheme: "KONEPS_PARTY_KEY".to_owned(),
            value_hash: "c".repeat(64),
            verification_status: "VERIFIED".to_owned(),
            proof_state: "LEGACY_UNPROVEN".to_owned(),
        },
        StrongIdentifierFact {
            supplier_id,
            scheme: "PHONE".to_owned(),
            value_hash: "d".repeat(64),
            verification_status: "VERIFIED".to_owned(),
            proof_state: "PROVEN_V1".to_owned(),
        },
        StrongIdentifierFact {
            supplier_id,
            scheme: "BUSINESS_NUMBER".to_owned(),
            value_hash: "e".repeat(64),
            verification_status: "VERIFIED".to_owned(),
            proof_state: "LEGACY_UNPROVEN".to_owned(),
        },
        StrongIdentifierFact {
            supplier_id,
            scheme: "KONEPS_PARTY_KEY".to_owned(),
            value_hash: "NOT-A-LOWERCASE-SHA256".to_owned(),
            verification_status: "VERIFIED".to_owned(),
            proof_state: "PROVEN_V1".to_owned(),
        },
    ]
}

#[test]
fn ambiguous_line_item_category_is_not_invented_for_contract_input() {
    let contract_id = Uuid::from_u128(40);
    let members = [
        member(
            0,
            "CONTRACT",
            contract_id,
            json!({"agencyId":Uuid::from_u128(41),"supplierId":Uuid::from_u128(42)}),
        ),
        member(
            1,
            "CONTRACT_LINE_ITEM",
            Uuid::from_u128(43),
            json!({"contractId":contract_id,"normalizedCategory":"OFFICE"}),
        ),
        member(
            2,
            "CONTRACT_LINE_ITEM",
            Uuid::from_u128(44),
            json!({"contractId":contract_id,"normalizedCategory":"VEHICLE"}),
        ),
    ];
    let result = materialize_rule_input(
        "REPEATED_SINGLE_SOURCE",
        &json!({"windowDays":30}),
        &members,
        &[],
    );
    assert!(
        matches!(result, Ok(materialized) if materialized.value.pointer("/contracts/0/category") == Some(&Value::Null))
    );
}

#[test]
fn amendment_materializer_does_not_infer_authority_fields_from_change_reason() {
    let contract_id = Uuid::from_u128(50);
    let members = [
        member(
            0,
            "CONTRACT",
            contract_id,
            json!({"originalAmount":"100","currentAmount":"120"}),
        ),
        member(
            1,
            "CONTRACT_CHANGE",
            Uuid::from_u128(51),
            json!({"contractId":contract_id,"reason":"범위 변경"}),
        ),
    ];
    let result = materialize_rule_input("CONTRACT_AMENDMENT_ESCALATION", &json!({}), &members, &[]);
    assert!(
        matches!(&result, Ok(materialized) if materialized.value.pointer("/contract/amendment_count") == Some(&Value::Null) && materialized.value.pointer("/contract/scope_change_explained") == Some(&Value::Null))
    );
    let evaluation = result.ok().and_then(|materialized| {
        gurine_detection::engine::evaluate("CONTRACT_AMENDMENT_ESCALATION", &materialized.value)
            .ok()
    });
    assert!(matches!(evaluation, Some(value) if value["outcome"] == "BLOCKED"));
}

#[test]
fn krw_numbers_and_strings_normalize_to_the_same_canonical_input() {
    let parsed = serde_json::from_str::<Value>(
        r#"{
            "originalAmount": 20000000.0000,
            "currentAmount": 32000000.0000,
            "amendmentCount": 2,
            "scopeChangeExplained": false
        }"#,
    );
    assert!(parsed.is_ok());
    let contract_id = Uuid::from_u128(52);
    let numeric_member = member(0, "CONTRACT", contract_id, parsed.unwrap_or(Value::Null));
    let string_member = member(
        0,
        "CONTRACT",
        contract_id,
        json!({
            "originalAmount": "20000000",
            "currentAmount": "32000000.0000",
            "amendmentCount": 2,
            "scopeChangeExplained": false,
        }),
    );
    let numeric = materialize_rule_input(
        "CONTRACT_AMENDMENT_ESCALATION",
        &json!({}),
        &[numeric_member],
        &[],
    );
    let string = materialize_rule_input(
        "CONTRACT_AMENDMENT_ESCALATION",
        &json!({}),
        &[string_member],
        &[],
    );

    assert!(matches!(
        (&numeric, &string),
        (Ok(numeric), Ok(string))
            if numeric.value == string.value
                && numeric.input_sha256 == string.input_sha256
                && numeric.value.pointer("/contract/original_amount")
                    == Some(&Value::String("20000000".to_owned()))
                && numeric.value.pointer("/contract/final_amount")
                    == Some(&Value::String("32000000".to_owned()))
                && numeric.value.pointer("/contract/amendment_count") == Some(&json!(2))
                && canonical_bytes(&numeric.value).is_ok()
    ));
    let evaluation = numeric.as_ref().ok().and_then(|materialized| {
        gurine_detection::engine::evaluate("CONTRACT_AMENDMENT_ESCALATION", &materialized.value)
            .ok()
    });
    assert!(matches!(
        (&numeric, evaluation),
        (Ok(materialized), Some(value))
            if value["outcome"] == "SIGNAL"
                && value.get("input_hash").and_then(Value::as_str)
                    == Some(materialized.input_sha256.as_str())
    ));
}

#[test]
fn fractional_krw_amount_fails_closed_before_hashing() {
    let result = materialize_rule_input(
        "CONTRACT_AMENDMENT_ESCALATION",
        &json!({}),
        &[member(
            0,
            "CONTRACT",
            Uuid::from_u128(53),
            json!({
                "originalAmount": "20000000.5",
                "currentAmount": "32000000",
                "amendmentCount": 2,
                "scopeChangeExplained": false,
            }),
        )],
        &[],
    );
    assert!(matches!(
        result,
        Err(Failure::Terminal("RULE_INPUT_MATERIALIZATION_INVALID", detail))
            if detail == "originalAmount"
    ));
}

#[test]
fn single_target_rules_reject_ambiguous_snapshot_members() {
    let cases = [
        ("PRICE_OUTLIER", "PRICE_OBSERVATION"),
        ("LOW_BID_COMPETITION", "CONTRACT"),
        ("CONTRACT_AMENDMENT_ESCALATION", "CONTRACT"),
        ("NEW_SUPPLIER_DEPENDENCE", "SUPPLIER"),
        ("RESTRICTIVE_SPECIFICATION", "CONTRACT_LINE_ITEM"),
    ];
    for (rule_id, object_type) in cases {
        let members = [
            member(0, object_type, Uuid::new_v4(), json!({})),
            member(1, object_type, Uuid::new_v4(), json!({})),
        ];
        let result = materialize_rule_input(rule_id, &json!({}), &members, &[]);
        assert!(matches!(
            result,
            Err(Failure::Terminal("RULE_INPUT_MATERIALIZATION_INVALID", detail))
                if detail.contains("ambiguous")
        ));
    }
}

#[test]
fn month_index_accepts_only_real_iso_calendar_dates() {
    assert_eq!(month_index("2026-12-31"), Some(11));
    assert_eq!(month_index("x-12-31"), None);
    assert_eq!(month_index("2026-02-31"), None);
}

use gurine_source_connectors::ConnectorOperation;
use serde_json::Value;

pub(super) struct StructuredRecord {
    pub value: Value,
    pub locator: String,
}

pub(super) fn extract(
    source_id: &str,
    operation: &ConnectorOperation,
    value: &Value,
) -> Vec<StructuredRecord> {
    let (candidate, locator) = if source_id.starts_with("koneps-") {
        value.pointer("/response/body/items/item").map_or_else(
            || {
                (
                    value.pointer("/response/body/items"),
                    "/response/body/items",
                )
            },
            |candidate| (Some(candidate), "/response/body/items/item"),
        )
    } else if source_id == "open-dart" {
        value
            .get("list")
            .map_or((Some(value), ""), |candidate| (Some(candidate), "/list"))
    } else if operation.kind == "manifest" {
        (value.get("documents"), "/documents")
    } else {
        value
            .get("records")
            .map_or((Some(value), ""), |candidate| (Some(candidate), "/records"))
    };
    match candidate {
        Some(Value::Array(values)) => values
            .iter()
            .enumerate()
            .map(|(index, value)| StructuredRecord {
                value: value.clone(),
                locator: format!("{locator}/{index}"),
            })
            .collect(),
        Some(Value::Object(values)) if !values.is_empty() => vec![StructuredRecord {
            value: Value::Object(values.clone()),
            locator: locator.to_owned(),
        }],
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use gurine_source_connectors::operations;
    use serde_json::json;

    use super::extract;

    #[test]
    fn extraction_retains_the_exact_array_locator() {
        let operation = operations()
            .find(|operation| operation.connector_id == "koneps-contracts")
            .expect("the frozen connector catalog must contain a KONEPS contract operation");
        let value = json!({"response":{"body":{"items":{"item":[{"corpNm":"가상 공급사"}]}}}});
        let records = extract("koneps-contracts", operation, &value);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].locator, "/response/body/items/item/0");
    }

    #[test]
    fn bid_result_metadata_uses_the_same_closed_data_go_kr_item_locator() {
        let operation = operations()
            .find(|operation| operation.id == "opening-goods-search")
            .expect("connector catalog must contain KONEPS opening metadata");
        let value = json!({"response":{"body":{"items":{"item":[{"bidNtceNo":"SYN-1","opengCorpInfo":"opaque"}]}}}});
        let records = extract("koneps-bid-results", operation, &value);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].locator, "/response/body/items/item/0");
        assert_eq!(records[0].value["opengCorpInfo"], "opaque");
    }

    #[test]
    fn dart_person_context_keeps_the_exact_disclosure_list_locator() {
        let operation = operations()
            .find(|operation| operation.id == "dart-executive-status")
            .expect("connector catalog must contain OpenDART executive status");
        let value = json!({"status":"000","list":[{"nm":"가상 임원"}]});
        let records = extract("open-dart", operation, &value);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].locator, "/list/0");
    }
}

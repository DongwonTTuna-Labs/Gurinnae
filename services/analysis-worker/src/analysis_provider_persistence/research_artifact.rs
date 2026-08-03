use super::*;

/// `source.fetch` returns immutable discovery/artifact metadata only. Raw
/// research bytes never become provider input directly; a human promotion
/// must create a classified Evidence segment, which then follows the existing
/// snapshot/source-use provider gate.
pub(super) fn ensure_source_fetch_result_is_metadata_only(
    prior_tool_result: Option<&Value>,
) -> Result<(), Failure> {
    let Some(result) = prior_tool_result else {
        return Ok(());
    };
    let response = result.get("response").unwrap_or(result);
    if response.get("schemaVersion").and_then(Value::as_str) != Some("source.fetch.response.v2") {
        return Ok(());
    }
    for result in response
        .get("searchResults")
        .and_then(Value::as_array)
        .map_or(&[][..], Vec::as_slice)
    {
        reject_fields(result, &["title", "snippet", "path", "body", "content"])?;
    }
    for artifact in response
        .get("artifacts")
        .and_then(Value::as_array)
        .map_or(&[][..], Vec::as_slice)
    {
        if artifact.get("reviewTier").and_then(Value::as_str) != Some("OFFICIAL_UNREVIEWED") {
            return Err(invalid_metadata("reviewTier"));
        }
        for field in [
            "researchArtifactId",
            "assetId",
            "sourceFetchId",
            "sourceUseId",
        ] {
            if artifact
                .get(field)
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .is_none()
            {
                return Err(invalid_metadata(field));
            }
        }
        for field in ["artifactSha256", "contentSha256", "sourceUseSha256"] {
            if artifact
                .get(field)
                .and_then(Value::as_str)
                .is_none_or(|value| !is_sha256_text(value))
            {
                return Err(invalid_metadata(field));
            }
        }
        reject_fields(
            artifact,
            &[
                "body",
                "content",
                "bytes",
                "contentBytesBase64",
                "selectedContentBytesBase64",
                "selectedContentText",
            ],
        )?;
    }
    Ok(())
}

fn reject_fields(value: &Value, forbidden: &[&str]) -> Result<(), Failure> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_metadata("object"))?;
    if let Some(field) = object
        .keys()
        .find(|field| forbidden.contains(&field.as_str()))
    {
        return Err(invalid_metadata(field));
    }
    Ok(())
}

fn invalid_metadata(field: &str) -> Failure {
    Failure::Terminal("AGENT_RESEARCH_ARTIFACT_METADATA_INVALID", field.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fetch_result() -> Value {
        json!({
            "callId": "source-call",
            "response": {
                "schemaVersion": "source.fetch.response.v2",
                "requestKind": "FETCH_URL",
                "searchResults": [],
                "artifacts": [{
                    "researchArtifactId": "00000000-0000-0000-0000-000000000001",
                    "assetId": "00000000-0000-0000-0000-000000000002",
                    "sourceFetchId": "00000000-0000-0000-0000-000000000003",
                    "sourceUseId": "00000000-0000-0000-0000-000000000004",
                    "artifactSha256": "1".repeat(64),
                    "contentSha256": "2".repeat(64),
                    "sourceUseSha256": "3".repeat(64),
                    "reviewTier": "OFFICIAL_UNREVIEWED"
                }]
            }
        })
    }

    #[test]
    fn raw_artifact_bytes_never_enter_provider_prior_result() {
        assert!(ensure_source_fetch_result_is_metadata_only(Some(&fetch_result())).is_ok());
        for field in [
            "content",
            "body",
            "bytes",
            "contentBytesBase64",
            "selectedContentBytesBase64",
            "selectedContentText",
        ] {
            let mut leaked = fetch_result();
            leaked["response"]["artifacts"][0][field] = json!("PERSON secret bytes");
            assert!(ensure_source_fetch_result_is_metadata_only(Some(&leaked)).is_err());
        }

        let mut promoted_artifact = fetch_result();
        promoted_artifact["response"]["artifacts"][0]["reviewTier"] = json!("HUMAN_PROMOTED");
        assert!(
            ensure_source_fetch_result_is_metadata_only(Some(&promoted_artifact)).is_err(),
            "promotion creates Evidence; it never changes the source.fetch artifact wire"
        );
    }

    #[test]
    fn unclassified_search_text_never_enters_provider_prior_result() {
        for field in ["title", "snippet", "path", "body", "content"] {
            let mut result = json!({
                "response": {
                    "schemaVersion": "source.fetch.response.v2",
                    "requestKind": "SEARCH_PUBLIC_WEB",
                    "searchResults": [{
                        "rank": 1,
                        "origin": "https://official.example",
                        "discoveredUrlSha256": "4".repeat(64),
                        "artifactId": null
                    }],
                    "artifacts": []
                }
            });
            result["response"]["searchResults"][0][field] = json!("홍길동 개인 정보");
            assert!(ensure_source_fetch_result_is_metadata_only(Some(&result)).is_err());
        }
    }
}

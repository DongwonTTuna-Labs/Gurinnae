use super::*;

#[expect(
    clippy::too_many_arguments,
    reason = "pending source receipt binds all immutable fetch evidence"
)]
pub(super) async fn build_pending_source_fetch(
    state: &State,
    turn: &ProviderTurnIdentity,
    call: &gurine_agent_orchestration::runtime::ToolCall,
    target: reqwest::Url,
    source_id: &'static str,
    request_kind: &'static str,
    status: u16,
    content_type: Option<String>,
    bytes: Vec<u8>,
    response_sha256: String,
    safe_headers: Value,
    redirects: Value,
    policy_version: &'static str,
    receipt_digest: String,
    rights: Value,
) -> Result<(PendingSourceFetch, String, String), Failure> {
    let object_key =
        persist_fetched_content(state, turn, request_kind, &bytes, &response_sha256).await?;
    let (locator, fetch_id, asset_id, artifact_id, source_use_id) =
        fetch_identity(turn, &target, &response_sha256);
    let artifact_sha256 = artifact_identity_sha256(
        artifact_id,
        asset_id,
        fetch_id,
        source_id,
        &locator,
        status,
        content_type.as_deref(),
        bytes.len(),
        &response_sha256,
        &safe_headers,
        &receipt_digest,
    )?;
    let rights_projection = project_rights(
        &rights,
        artifact_id,
        asset_id,
        &response_sha256,
        policy_version,
        source_id,
    )?;
    let source_use_root = build_source_use_root(&SourceUseRootInput {
        source_use_id,
        turn,
        call,
        artifact_id,
        asset_id,
        fetch_id,
        artifact_sha256: &artifact_sha256,
        content_sha256: &response_sha256,
        locator: &locator,
        rights: &rights_projection,
    });
    let source_use_sha256 = sha256(&canonical_bytes(&source_use_root)?);
    let retrieved_at = rights_projection.occurred_at.clone();
    let is_url = request_kind == "FETCH_URL";
    let pending = PendingSourceFetch {
        request_kind,
        source_id,
        external_locator: locator.clone(),
        source_url_redacted: is_url.then(|| locator.clone()),
        final_url_redacted: is_url.then(|| locator.clone()),
        http_status: status as i32,
        content_media_type: content_type,
        request_sha256: call.request_sha256.clone(),
        content: bytes,
        object_key,
        policy_version,
        fetch_id,
        asset_id,
        artifact_id,
        source_use_id,
        source_use_sha256,
        safe_headers,
        redirects,
        content_safety_receipt_sha256: receipt_digest.clone(),
    };
    Ok((pending, retrieved_at, receipt_digest))
}

async fn persist_fetched_content(
    state: &State,
    turn: &ProviderTurnIdentity,
    request_kind: &str,
    bytes: &[u8],
    response_sha256: &str,
) -> Result<String, Failure> {
    let object_key = format!(
        "research/{}/{}/{}",
        turn.run_id, turn.turn_id, response_sha256
    );
    if request_kind != "FETCH_URL" {
        return Ok(object_key);
    }
    let store = state
        .object_store
        .as_ref()
        .ok_or_else(|| Failure::Terminal("OBJECT_STORE_MISSING", turn.run_id.to_string()))?;
    store
        .put(&object_key, bytes.to_vec(), response_sha256)
        .await
        .map_err(|_| Failure::Terminal("OBJECT_STORE_WRITE_FAILED", object_key.clone()))?;
    Ok(object_key)
}

fn fetch_identity(
    turn: &ProviderTurnIdentity,
    target: &reqwest::Url,
    response_sha256: &str,
) -> (String, Uuid, Uuid, Uuid, Uuid) {
    let locator = format!(
        "{}://{}{}",
        target.scheme(),
        target.host_str().unwrap_or_default(),
        target.path()
    );
    let fetch_id =
        stable_uuid(format!("source-fetch:{}:{response_sha256}", turn.turn_id).as_bytes());
    let asset_id = stable_uuid(format!("source-asset:{fetch_id}").as_bytes());
    let artifact_id = stable_uuid(format!("source-artifact:{fetch_id}").as_bytes());
    let source_use_id = stable_uuid(format!("source-use:{fetch_id}").as_bytes());
    (locator, fetch_id, asset_id, artifact_id, source_use_id)
}

#[expect(
    clippy::too_many_arguments,
    reason = "artifact identity is the immutable source-use root"
)]
fn artifact_identity_sha256(
    artifact_id: Uuid,
    asset_id: Uuid,
    fetch_id: Uuid,
    source_id: &str,
    locator: &str,
    status: u16,
    content_type: Option<&str>,
    byte_count: usize,
    response_sha256: &str,
    safe_headers: &Value,
    receipt_digest: &str,
) -> Result<String, Failure> {
    let identity = json!({"schemaVersion":"research-artifact.v2","researchArtifactId":artifact_id,"assetId":asset_id,"assetRevision":1,"sourceFetchId":fetch_id,"artifactOrdinal":0,"fetchOutcome":"STORED","sourceAuthority":source_id,"finalOrigin":locator,"httpStatus":status,"contentMediaType":content_type.unwrap_or("application/octet-stream"),"contentSizeBytes":byte_count,"contentSha256":response_sha256,"responseHeadersSha256":sha256(&canonical_bytes(safe_headers)?),"contentSafetyState":"CLEAN","contentSafetyReceiptSha256":receipt_digest});
    Ok(sha256(&canonical_bytes(&identity)?))
}

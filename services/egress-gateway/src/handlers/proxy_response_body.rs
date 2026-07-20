{
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return problem("EGRESS_RESPONSE_TOO_LARGE", 502);
    }
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let compressed_bytes = response.content_length().unwrap_or(0);
    let mut body = Vec::new();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) if body.len() + chunk.len() <= limit => body.extend_from_slice(&chunk),
            Ok(Some(_)) => return problem("EGRESS_RESPONSE_TOO_LARGE", 502),
            Ok(None) => break,
            Err(_) => return problem("EGRESS_UPSTREAM_UNAVAILABLE", 502),
        }
    }
    let body_sha256 = format!("{:x}", Sha256::digest(&body));
    if compressed_bytes > 0 && body.len() as u64 > compressed_bytes.saturating_mul(100) {
        return problem("EGRESS_COMPRESSION_RATIO_EXCEEDED", 502);
    }
    let receipt_id = sha256_hex(
        format!("egress-receipt-v1:{idempotency_key}:{target}:{status}:{body_sha256}").as_bytes(),
    );
    let receipt_sha256 =
        sha256_hex(format!("egress-receipt:{receipt_id}:{body_sha256}").as_bytes());
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut output = HttpResponse::build(status);
    for (name, value) in &headers {
        if !hop_or_internal(name.as_str()) && name.as_str() != "set-cookie" {
            let name = actix_web::http::header::HeaderName::try_from(name.as_str());
            let value = actix_web::http::header::HeaderValue::from_bytes(value.as_bytes());
            if let (Ok(name), Ok(value)) = (name, value) {
                output.insert_header((name, value));
            }
        }
    }
    output.insert_header(("x-gurine-source-fetch-payload-sha256", body_sha256.clone()));
    output.insert_header(("x-gurine-egress-receipt-id", receipt_id.clone()));
    output.insert_header(("x-gurine-egress-receipt-sha256", receipt_sha256.clone()));
    output.insert_header((
        "x-gurine-source-fetch-receipt-version",
        "source.fetch.receipt.v2",
    ));
    output.insert_header(("x-gurine-source-fetch-policy", "source-policy-v2"));
    output.insert_header((
        "x-gurine-source-fetch-compressed-bytes",
        compressed_bytes.to_string(),
    ));
    output.insert_header((
        "x-gurine-source-fetch-expanded-bytes",
        body.len().to_string(),
    ));
    output.insert_header((
        "x-gurine-source-fetch-redirect-chain",
        redirect_chain.to_owned(),
    ));
    if body.len() <= REPLAY_CACHE_LIMIT {
        let cached = CachedReplay {
            status: status.as_u16(),
            headers: vec![
                (
                    "x-gurine-source-fetch-payload-sha256".to_owned(),
                    body_sha256.clone(),
                ),
                ("x-gurine-egress-receipt-id".to_owned(), receipt_id.clone()),
                (
                    "x-gurine-egress-receipt-sha256".to_owned(),
                    receipt_sha256.clone(),
                ),
                (
                    "x-gurine-source-fetch-receipt-version".to_owned(),
                    "source.fetch.receipt.v2".to_owned(),
                ),
                (
                    "x-gurine-source-fetch-policy".to_owned(),
                    "source-policy-v2".to_owned(),
                ),
                (
                    "x-gurine-source-fetch-redirect-chain".to_owned(),
                    redirect_chain.to_owned(),
                ),
            ],
            body: body.clone(),
        };
        let persisted = {
            let Ok(mut cache) = REPLAY_CACHE
                .get_or_init(|| Mutex::new(BTreeMap::new()))
                .lock()
            else {
                return HttpResponse::InternalServerError().finish();
            };
            if cache.len() >= 128
                && let Some(key) = cache.keys().next().cloned()
            {
                cache.remove(&key);
            }
            cache.insert(idempotency_key.to_owned(), cached.clone());
            match serde_json::to_vec(&cached) {
                Ok(bytes) => bytes,
                Err(_) => return HttpResponse::InternalServerError().finish(),
            }
        };
        if let Some(store) = state.object_store.as_ref() {
            let digest = sha256_hex(&persisted);
            if store.put(&replay_object_key(idempotency_key), persisted, &digest).await.is_err() {
                return HttpResponse::InternalServerError().finish();
            }
        }
    }
    output.body(body)
}

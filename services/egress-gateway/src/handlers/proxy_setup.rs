
async fn proxy(
    channel: Channel,
    request: HttpRequest,
    body: web::Bytes,
    state: &GatewayState,
) -> HttpResponse {
    if !caller_allowed(channel, caller(&request)) {
        return problem("EGRESS_CALLER_DENIED", 403);
    }
    if matches!(channel, Channel::Ai) && kill_switch_active(state, "AI", None).await {
        return problem("AI_EGRESS_KILL_SWITCH_ACTIVE", 503);
    }
    let Some(target) = header(&request, "x-gurine-egress-target") else {
        return problem("EGRESS_TARGET_REQUIRED", 400);
    };
    if !allowed_method(channel, request.method().as_str()) {
        return problem("EGRESS_METHOD_DENIED", 405);
    }
    let mut target = match validate_target(channel, target, state).await {
        Ok(value) => value,
        Err(code) => return problem(code, 403),
    };
    let target_for_receipt = target.to_string();
    let receipt_key = header(&request, "x-gurine-idempotency-key")
        .map(str::to_owned)
        .unwrap_or_else(|| format!("implicit:{}:{}", target_for_receipt, sha256_hex(&body)));
    if let Some(cached) = load_replay(state, &receipt_key).await {
        let mut replay = HttpResponse::build(
            StatusCode::from_u16(cached.status).unwrap_or(StatusCode::BAD_GATEWAY),
        );
        for (name, value) in cached.headers {
            replay.insert_header((name, value));
        }
        replay.insert_header(("x-gurine-egress-replayed", "true"));
        return replay.body(cached.body);
    }
    let mut redirects = 0_u8;
    let requested_limit = match header(&request, "x-gurine-source-fetch-max-bytes") {
        Some(value) => match value.parse::<usize>() { Ok(value) => value, Err(_) => return problem("EGRESS_LIMIT_INVALID", 400) },
        None => response_limit(channel),
    }.min(response_limit(channel));
    if requested_limit == 0 { return problem("EGRESS_LIMIT_INVALID", 400); }
    let expected_media_types: Vec<String> = match header(&request, "x-gurine-source-fetch-expected-media-types") {
        Some(value) => match serde_json::from_str(value) { Ok(value) => value, Err(_) => return problem("EGRESS_MEDIA_TYPES_INVALID", 400) },
        None => Vec::new(),
    };
    let request_digest = header(&request, "x-gurine-source-fetch-request-sha256")
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .unwrap_or("");
    if matches!(channel, Channel::Source | Channel::Ai) && request_digest.is_empty() {
        return problem("EGRESS_REQUEST_DIGEST_REQUIRED", 400);
    }
    let allow_redirects = header(&request, "x-gurine-allow-redirects")
        .is_some_and(|value| value.eq_ignore_ascii_case("true"));
    let mut redirect_chain: Vec<serde_json::Value> = Vec::new();
    let response = loop {
        let hop_from = target.to_string();
        let from_origin = origin_of(&target);
        let response = match send_upstream(channel, &request, &body, target.clone(), state).await {
            Ok(value) => value,
            Err(code) => return problem(code, if code == "EGRESS_UPSTREAM_UNAVAILABLE" { 502 } else { 403 }),
        };
        if !response.status().is_redirection() {
            if !expected_media_types.is_empty() {
                let actual = response.headers().get(reqwest::header::CONTENT_TYPE)
                    .and_then(|value| value.to_str().ok())
                    .map(|value| value.split(';').next().unwrap_or(value).trim().to_ascii_lowercase())
                    .unwrap_or_default();
                if !expected_media_types.iter().any(|expected| expected == &actual) {
                    return problem("EGRESS_MEDIA_TYPE_DENIED", 403);
                }
            }
            break response;
        }
        if !allow_redirects { return problem("EGRESS_REDIRECT_DENIED", 403); }
        if redirects >= 5 { return problem("EGRESS_REDIRECT_LIMIT", 502); }
        let Some(location) = response.headers().get(reqwest::header::LOCATION).and_then(|v| v.to_str().ok()) else {
            return problem("EGRESS_REDIRECT_INVALID", 502);
        };
        let next = match target.join(location) { Ok(value) => value, Err(_) => return problem("EGRESS_REDIRECT_INVALID", 502) };
        target = match validate_target(channel, next.as_str(), state).await { Ok(value) => value, Err(code) => return problem(code, 403) };
        let hop_to = target.to_string();
        let to_origin = origin_of(&target);
        let (from_dns, from_policy) = match target_decision_digests(&hop_from, channel).await {
            Ok(value) => value,
            Err(code) => return problem(code, 403),
        };
        let (to_dns, to_policy) = match target_decision_digests(&hop_to, channel).await {
            Ok(value) => value,
            Err(code) => return problem(code, 403),
        };
        redirect_chain.push(serde_json::json!({
            "ordinal": redirects as u16 + 1,
            "fromOrigin": from_origin,
            "toOrigin": to_origin,
            "status": response.status().as_u16(),
            "dnsDecisionSha256": sha256_hex(format!("{}:{}", from_dns, to_dns).as_bytes()),
            "policyDecisionSha256": sha256_hex(format!("{}:{}:{}", from_policy, to_policy, channel_name(channel)).as_bytes())
        }));
        redirects += 1;
    };
    proxy_response(
        response,
        requested_limit,
        &target_for_receipt,
        &receipt_key,
        request_digest,
        &serde_json::to_string(&redirect_chain).unwrap_or_else(|_| "[]".to_owned()),
        state,
    )
    .await
}

fn origin_of(url: &Url) -> String {
    let host = url.host_str().map_or_else(String::new, str::to_owned);
    match url.port() {
        Some(port) => format!("{}://{}:{}", url.scheme(), host, port),
        None => format!("{}://{}", url.scheme(), host),
    }
}

async fn target_decision_digests(
    target: &str,
    channel: Channel,
) -> Result<(String, String), &'static str> {
    let url = Url::parse(target).map_err(|_| "EGRESS_TARGET_INVALID")?;
    let host = url.host_str().ok_or("EGRESS_TARGET_INVALID")?;
    let port = url.port_or_known_default().ok_or("EGRESS_TARGET_INVALID")?;
    let mut addresses = lookup_host((host, port))
        .await
        .map_err(|_| "EGRESS_DNS_FAILED")?
        .map(|address| address.to_string())
        .collect::<Vec<_>>();
    addresses.sort();
    let dns = sha256_hex(format!("dns-v2:{}:{}", host, addresses.join(",")).as_bytes());
    let policy = sha256_hex(
        format!("egress-policy-v2:{}:{}:{}", channel_name(channel), url.scheme(), host).as_bytes(),
    );
    Ok((dns, policy))
}

fn channel_name(channel: Channel) -> &'static str {
    match channel {
        Channel::Source => "SOURCE",
        Channel::Ai => "AI",
        Channel::Oidc => "OIDC",
        Channel::Challenge => "CHALLENGE",
    }
}

async fn send_upstream(
    channel: Channel,
    request: &HttpRequest,
    body: &web::Bytes,
    mut target: Url,
    state: &GatewayState,
) -> Result<reqwest::Response, &'static str> {
    let credential = bind_credential(channel, request, &mut target, state)?;
    let client = pinned_client(&target, state).await?;
    let method = reqwest::Method::from_bytes(request.method().as_str().as_bytes()).map_err(|_| "EGRESS_METHOD_DENIED")?;
    let mut outbound = client.request(method, target);
    for (name, value) in request.headers() {
        if !hop_or_internal(name.as_str()) && !caller_credential_header(channel, name.as_str()) {
            outbound = outbound.header(name.as_str(), value.as_bytes());
        }
    }
    outbound = match credential {
        Some(Credential::Bearer(value)) => outbound.bearer_auth(value),
        Some(Credential::Header(name, value)) => outbound.header(name, value),
        None => outbound,
    };
    outbound.body(body.to_vec()).send().await.map_err(|_| "EGRESS_UPSTREAM_UNAVAILABLE")
}

async fn load_replay(state: &GatewayState, receipt_key: &str) -> Option<CachedReplay> {
    if let Some(cached) = REPLAY_CACHE
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
        .ok()
        .and_then(|cache| cache.get(receipt_key).cloned())
    {
        return Some(cached);
    }
    let store = state.object_store.as_ref()?;
    let bytes = store
        .get(&replay_object_key(receipt_key), None)
        .await
        .ok()?;
    let cached: CachedReplay = serde_json::from_slice(&bytes).ok()?;
    if let Ok(mut cache) = REPLAY_CACHE
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
    {
        cache.insert(receipt_key.to_owned(), cached.clone());
    }
    Some(cached)
}

fn replay_object_key(receipt_key: &str) -> String {
    format!("egress-replay/{}", sha256_hex(receipt_key.as_bytes()))
}

enum Credential<'a> {
    Bearer(&'a str),
    Header(&'static str, &'a str),
}

fn bind_credential<'a>(
    channel: Channel,
    request: &HttpRequest,
    target: &mut Url,
    state: &'a GatewayState,
) -> Result<Option<Credential<'a>>, &'static str> {
    let host = target.host_str().ok_or("EGRESS_TARGET_INVALID")?.to_owned();
    match channel {
        Channel::Source => bind_source_credential(request, target, state, &host),
        Channel::Ai => bind_ai_credential(request, state, &host),
        Channel::Oidc | Channel::Challenge => Ok(None),
    }
}

fn bind_source_credential<'a>(
    request: &HttpRequest,
    target: &mut Url,
    state: &'a GatewayState,
    host: &str,
) -> Result<Option<Credential<'a>>, &'static str> {
    let source_id = header(request, "x-gurine-source-id").ok_or("EGRESS_SOURCE_ID_REQUIRED")?;
    let expected_host = state
        .config
        .source_host_bindings
        .get(source_id)
        .ok_or("EGRESS_SOURCE_ID_DENIED")?;
    if !state.config.development()
        && expected_host != "*"
        && !host.eq_ignore_ascii_case(expected_host)
    {
        return Err("EGRESS_SOURCE_HOST_MISMATCH");
    }
    match source_id {
        "brave-search-web-v1" => {
            if !host.eq_ignore_ascii_case("api.search.brave.com") {
                return Err("EGRESS_SOURCE_HOST_MISMATCH");
            }
            let secret = state
                .config
                .brave_search_api_key
                .as_deref()
                .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED")?;
            Ok(Some(Credential::Header("X-Subscription-Token", secret)))
        }
        "koneps-contracts" | "koneps-notices" | "local-finance" => {
            let secret = state
                .config
                .data_go_kr_service_key
                .as_deref()
                .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED")?;
            replace_query_secret(target, &["serviceKey"], "serviceKey", secret);
            Ok(None)
        }
        "open-dart" => {
            let secret = state
                .config
                .open_dart_api_key
                .as_deref()
                .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED")?;
            replace_query_secret(target, &["crtfc_key"], "crtfc_key", secret);
            Ok(None)
        }
        "public-research" => {
            if !state.config.public_research_hosts.contains(host) {
                return Err("EGRESS_SOURCE_HOST_MISMATCH");
            }
            Ok(None)
        }
        "alio" | "audit-results" => Ok(None),
        _ => Err("EGRESS_SOURCE_ID_DENIED"),
    }
}

fn bind_ai_credential<'a>(
    request: &HttpRequest,
    state: &'a GatewayState,
    host: &str,
) -> Result<Option<Credential<'a>>, &'static str> {
    let provider = header(request, "x-gurine-ai-provider")
        .ok_or("EGRESS_AI_PROVIDER_REQUIRED")?
        .to_ascii_lowercase();
    let expected_host = match provider.as_str() {
        "openai" => "api.openai.com",
        "anthropic" => "api.anthropic.com",
        "google" => "generativelanguage.googleapis.com",
        _ => return Err("EGRESS_AI_PROVIDER_DENIED"),
    };
    if !state.config.development() && !host.eq_ignore_ascii_case(expected_host) {
        return Err("EGRESS_AI_HOST_MISMATCH");
    }
    let credential = match provider.as_str() {
        "openai" => state
            .config
            .openai_api_key
            .as_deref()
            .map(Credential::Bearer),
        "anthropic" => state
            .config
            .anthropic_api_key
            .as_deref()
            .map(|value| Credential::Header("x-api-key", value)),
        "google" => state
            .config
            .google_api_key
            .as_deref()
            .map(|value| Credential::Header("x-goog-api-key", value)),
        _ => return Err("EGRESS_AI_PROVIDER_DENIED"),
    }
    .ok_or("EGRESS_CREDENTIAL_NOT_CONFIGURED")?;
    Ok(Some(credential))
}

#[derive(Clone, Copy)]
enum PageNoticeAuthority {
    PublicationCollection,
    OperationalCollection,
    SearchCollection,
    RedistributionCollection,
}

fn page_with_notice_seo(
    items: Vec<Value>,
    query: &Query,
    applied_filters: Value,
    title: &str,
    canonical_url: String,
    notice_authority: PageNoticeAuthority,
) -> Result<Value, ServiceError> {
    let mut value = page(items, query, applied_filters)?;
    let response_items = value
        .get("items")
        .and_then(Value::as_array)
        .ok_or(ServiceError::Persistence)?;
    let description = page_seo_description(title, response_items, notice_authority)?;
    value["seo"] = seo_metadata(title, description, canonical_url);
    Ok(value)
}

fn page_seo_description(
    title: &str,
    items: &[Value],
    authority: PageNoticeAuthority,
) -> Result<String, ServiceError> {
    let mut notices = BTreeMap::<String, u8>::new();
    if items.is_empty() {
        let (order, notice) = match authority {
            PageNoticeAuthority::PublicationCollection | PageNoticeAuthority::SearchCollection => {
                (0, EMPTY_PUBLICATION_NOTICE)
            }
            PageNoticeAuthority::OperationalCollection => (10, OPERATIONAL_INTERPRETATION_NOTICE),
            PageNoticeAuthority::RedistributionCollection => (30, PUBLIC_REDISTRIBUTION_NOTICE),
        };
        insert_page_notice(&mut notices, order, notice);
    }
    for item in items {
        collect_page_item_notice(item, authority, &mut notices)?;
    }
    let mut ordered_notices = notices
        .into_iter()
        .map(|(notice, order)| (order, notice))
        .collect::<Vec<_>>();
    ordered_notices.sort();
    Ok(std::iter::once(title.to_owned())
        .chain(ordered_notices.into_iter().map(|(_, notice)| notice))
        .collect::<Vec<_>>()
        .join(" · "))
}

fn collect_page_item_notice(
    item: &Value,
    authority: PageNoticeAuthority,
    notices: &mut BTreeMap<String, u8>,
) -> Result<(), ServiceError> {
    match authority {
        PageNoticeAuthority::PublicationCollection => {
            collect_publication_page_notice(item, notices)
        }
        PageNoticeAuthority::OperationalCollection => {
            collect_operational_page_notice(item, notices)
        }
        PageNoticeAuthority::SearchCollection => collect_search_page_notice(item, notices),
        PageNoticeAuthority::RedistributionCollection => {
            let notice =
                exact_page_notice(item, "redistributionNotice", PUBLIC_REDISTRIBUTION_NOTICE)?;
            insert_page_notice(notices, 30, notice);
            Ok(())
        }
    }
}

fn collect_publication_page_notice(
    item: &Value,
    notices: &mut BTreeMap<String, u8>,
) -> Result<(), ServiceError> {
    let state = page_publication_state(item)?;
    let order = publication_state_order(Some(state));
    if order > 5 {
        return Err(ServiceError::Persistence);
    }
    let notice = nonempty_page_notice(item, "nonConclusion")?;
    insert_page_notice(notices, order, notice);
    Ok(())
}

fn collect_operational_page_notice(
    item: &Value,
    notices: &mut BTreeMap<String, u8>,
) -> Result<(), ServiceError> {
    let order = operational_kind_order(item);
    if order == 19 {
        return Err(ServiceError::Persistence);
    }
    let notice = exact_page_notice(
        item,
        "interpretationNotice",
        OPERATIONAL_INTERPRETATION_NOTICE,
    )?;
    insert_page_notice(notices, order, notice);
    Ok(())
}

fn collect_search_page_notice(
    item: &Value,
    notices: &mut BTreeMap<String, u8>,
) -> Result<(), ServiceError> {
    match item.get("resultType").and_then(Value::as_str) {
        Some("CASE" | "CORRECTION") => {
            require_null_page_notice(item, "interpretationNotice")?;
            collect_publication_page_notice(item, notices)
        }
        Some("AGENCY" | "SUPPLIER" | "CONTRACT" | "SOURCE") => {
            require_null_page_notice(item, "nonConclusion")?;
            collect_operational_page_notice(item, notices)
        }
        Some("RULE" | "DATASET") => {
            require_null_page_notice(item, "nonConclusion")?;
            require_null_page_notice(item, "interpretationNotice")
        }
        _ => Err(ServiceError::Persistence),
    }
}

fn page_publication_state(item: &Value) -> Result<&str, ServiceError> {
    item.get("publicState")
        .or_else(|| item.get("state"))
        .or_else(|| item.get("status"))
        .and_then(Value::as_str)
        .ok_or(ServiceError::Persistence)
}

fn nonempty_page_notice<'a>(item: &'a Value, key: &str) -> Result<&'a str, ServiceError> {
    item.get(key)
        .and_then(Value::as_str)
        .filter(|notice| !notice.trim().is_empty())
        .ok_or(ServiceError::Persistence)
}

fn exact_page_notice<'a>(
    item: &'a Value,
    key: &str,
    expected: &str,
) -> Result<&'a str, ServiceError> {
    let notice = nonempty_page_notice(item, key)?;
    if notice == expected {
        Ok(notice)
    } else {
        Err(ServiceError::Persistence)
    }
}

fn require_null_page_notice(item: &Value, key: &str) -> Result<(), ServiceError> {
    match item.get(key) {
        Some(Value::Null) => Ok(()),
        _ => Err(ServiceError::Persistence),
    }
}

fn insert_page_notice(notices: &mut BTreeMap<String, u8>, order: u8, notice: &str) {
    notices
        .entry(notice.to_owned())
        .and_modify(|existing_order| *existing_order = (*existing_order).min(order))
        .or_insert(order);
}

fn publication_state_order(state: Option<&str>) -> u8 {
    match state {
        Some("PUBLISHED_ANOMALY") => 0,
        Some("PUBLISHED_EXPLAINED") => 1,
        Some("OFFICIALLY_CONFIRMED") => 2,
        Some("CORRECTED") => 3,
        Some("RETRACTED") => 4,
        Some("TEMPORARILY_RESTRICTED") => 5,
        _ => 6,
    }
}

fn operational_kind_order(item: &Value) -> u8 {
    match item.get("resultType").and_then(Value::as_str) {
        Some("AGENCY") => 10,
        Some("SUPPLIER") => 11,
        Some("CONTRACT") => 12,
        Some("SOURCE") => 13,
        _ if item.get("agencyType").is_some() => 10,
        _ if item.get("businessStatus").is_some() => 11,
        _ if item.get("contractNumber").is_some() => 12,
        _ if item.get("sourceId").is_some() => 13,
        _ => 19,
    }
}

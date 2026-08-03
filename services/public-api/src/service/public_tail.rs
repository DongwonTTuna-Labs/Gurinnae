async fn list_reports(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let period_from = optional_date(query, "periodFrom")?;
    let period_to = optional_date(query, "periodTo")?;
    validate_range(period_from.as_ref(), period_to.as_ref())?;
    let sort = requested_sort(query, &["published_desc", "period_desc"], "published_desc")?;
    let rows = sqlx::query!(
        "SELECT id,period_start,period_end,title,summary,report,published_at FROM public.transparency_reports WHERE ($1::date IS NULL OR period_end >= $1) AND ($2::date IS NULL OR period_start <= $2) ORDER BY CASE WHEN $3='published_desc' THEN published_at END DESC,CASE WHEN $3='period_desc' THEN period_end END DESC,CASE WHEN $3='period_desc' THEN period_start END DESC,id LIMIT $4 OFFSET $5",
        period_from,
        period_to,
        sort,
        query.limit + 1,
        query.offset,
    )
    .fetch_all(pool)
    .await
    .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        let id = r.id;
        let summary = r.summary;
        let report = r.report;
        let detail = ["income", "expenses", "donors", "conflicts", "thresholds"]
            .into_iter()
            .filter_map(|key| report.get(key).and_then(|value| public_report_scalar(key, value)))
            .collect::<Vec<_>>();
        let summary = if detail.is_empty() {
            summary
        } else {
            format!("{summary} · {}", detail.join(" · "))
        };
        items.push(json!({"id":id,"periodStart":r.period_start.to_string(),"periodEnd":r.period_end.to_string(),"title":r.title,"summary":summary,"publishedAt":timestamp(r.published_at)?,"href":format!("/transparency-reports/{id}")}));
    }
    let mut filters = Map::new();
    for name in ["periodFrom", "periodTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page(items, query, Value::Object(filters))
}

/// `public.transparency_reports.report` is JSONB for storage compatibility,
/// but it is not a permission boundary.  Only the closed, public summary keys
/// above may cross this API, and only scalar values are rendered.  Objects and
/// arrays are deliberately omitted until a signed disclosure schema gives them
/// a public projection; text values remain UNKNOWN until that schema exists,
/// preventing private contacts or internal notes from being stringified into an
/// anonymous response.
fn public_report_scalar(key: &str, value: &serde_json::Value) -> Option<String> {
    let rendered = match value {
        serde_json::Value::Bool(value) => value.to_string(),
        serde_json::Value::Number(value) => value.to_string(),
        _ => return None,
    };
    Some(format!("{key}: {rendered}"))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn db(_: sqlx::Error) -> ServiceError {
    ServiceError::Persistence
}

#[cfg(test)]
mod tests {
    use super::public_report_scalar;
    use serde_json::json;

    #[test]
    fn public_report_scalar_rejects_nested_private_shapes() {
        assert_eq!(
            public_report_scalar("income", &json!({"contact": "private@example.test"})),
            None
        );
        assert_eq!(public_report_scalar("income", &json!(["internal note"])), None);
    }

    #[test]
    fn public_report_scalar_keeps_bounded_public_primitives() {
        assert_eq!(
            public_report_scalar("thresholds", &json!(15)),
            Some("thresholds: 15".to_owned())
        );
        assert_eq!(public_report_scalar("conflicts", &json!("NONE_DECLARED")), None);
    }
}

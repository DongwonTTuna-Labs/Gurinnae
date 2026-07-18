async fn list_reports(pool: &PgPool, query: &Query) -> Result<Value, ServiceError> {
    let period_from = optional_date(query, "periodFrom")?;
    let period_to = optional_date(query, "periodTo")?;
    validate_range(period_from.as_ref(), period_to.as_ref())?;
    let sort = requested_sort(query, &["published_desc", "period_desc"], "published_desc")?;
    let rows = sqlx::query(
        "SELECT id,period_start,period_end,title,summary,published_at FROM public.transparency_reports WHERE ($1::date IS NULL OR period_end >= $1) AND ($2::date IS NULL OR period_start <= $2) ORDER BY CASE WHEN $3='published_desc' THEN published_at END DESC,CASE WHEN $3='period_desc' THEN period_end END DESC,CASE WHEN $3='period_desc' THEN period_start END DESC,id LIMIT $4 OFFSET $5",
    )
        .bind(period_from)
        .bind(period_to)
        .bind(sort)
        .bind(query.limit + 1)
        .bind(query.offset)
        .fetch_all(pool)
        .await
        .map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        let id: Uuid = r.try_get("id").map_err(db)?;
        items.push(json!({"id":id,"periodStart":r.try_get::<time::Date,_>("period_start").map_err(db)?.to_string(),"periodEnd":r.try_get::<time::Date,_>("period_end").map_err(db)?.to_string(),"title":r.try_get::<String,_>("title").map_err(db)?,"summary":r.try_get::<String,_>("summary").map_err(db)?,"publishedAt":timestamp(r.try_get("published_at").map_err(db)?)?,"href":format!("/transparency-reports/{id}")}));
    }
    let mut filters = Map::new();
    for name in ["periodFrom", "periodTo"] {
        if let Some(value) = query.first(name) {
            filters.insert(name.into(), json!(value));
        }
    }
    page(items, query, Value::Object(filters))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn db(_: sqlx::Error) -> ServiceError {
    ServiceError::Persistence
}

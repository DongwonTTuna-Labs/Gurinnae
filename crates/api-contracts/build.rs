use std::{env, fs, path::PathBuf};

fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("manifest directory"))
        .join("../../specs/events");
    let catalog = fs::read_to_string(root.join("event-catalog.yaml")).expect("event catalog");
    println!("cargo:rerun-if-changed={}", root.display());
    let mut event_type: Option<String> = None;
    let mut entries = Vec::new();
    let mut producers = Vec::new();
    let mut outbox_events = Vec::new();
    let lines = catalog.lines().collect::<Vec<_>>();
    for (index, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("- event_type: ") {
            event_type = Some(value.to_owned());
        } else if trimmed == "producer_operations:" {
            let Some(current) = event_type.as_deref() else {
                continue;
            };
            for operation in lines
                .iter()
                .skip(index + 1)
                .take_while(|value| value.starts_with("  - "))
            {
                producers.push((
                    operation.trim_start_matches("  - ").to_owned(),
                    current.to_owned(),
                ));
            }
        } else if let Some(value) = trimmed.strip_prefix("payload_schema: ") {
            let name = event_type
                .as_ref()
                .expect("payload schema follows event type")
                .clone();
            let schema = fs::read_to_string(root.join(value)).expect("event payload schema");
            entries.push((name, schema));
        } else if trimmed == "delivery: OUTBOX_AT_LEAST_ONCE"
            && let Some(current) = event_type.as_deref()
        {
            outbox_events.push(current.to_owned());
        }
    }
    let source = format!(
        "&{:?}",
        entries
            .iter()
            .map(|(name, schema)| (name.as_str(), schema.as_str()))
            .collect::<Vec<_>>()
    );
    fs::write(
        PathBuf::from(env::var("OUT_DIR").expect("output directory")).join("event_schemas.rs"),
        source,
    )
    .expect("write embedded event schemas");
    fs::write(
        PathBuf::from(env::var("OUT_DIR").expect("output directory")).join("event_producers.rs"),
        format!(
            "&{:?}",
            producers
                .iter()
                .map(|(operation, event)| (operation.as_str(), event.as_str()))
                .collect::<Vec<_>>()
        ),
    )
    .expect("write embedded event producers");
    fs::write(
        PathBuf::from(env::var("OUT_DIR").expect("output directory")).join("outbox_events.rs"),
        format!("&{:?}", outbox_events),
    )
    .expect("write embedded outbox event set");
}

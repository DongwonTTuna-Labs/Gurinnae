use super::*;
use uuid::Uuid;

fn binding(bytes: &[u8]) -> AssetBinding {
    AssetBinding {
        asset_id: Uuid::new_v4(),
        asset_revision: 1,
        content_sha256: sha256_hex(bytes),
    }
}

#[test]
fn html_is_static_and_keeps_typed_table_and_link_locator() {
    let bytes = br#"<!doctype html><html lang="en"><head><title>Case</title></head><body><main><h1>Heading</h1><p>Body text</p><table><caption>Values</caption><tr><th>Key</th><th>Value</th></tr><tr><td>A</td><td>1</td></tr></table><a href="https://example.invalid/a">Official</a><script>throw 1</script></main></body></html>"#;
    let result = match parse_bytes(bytes, &binding(bytes)) {
        Ok(value) => value,
        Err(error) => std::panic::panic_any(error),
    };
    assert_eq!(result.status, MultimodalStatus::Extracted);
    assert!(
        result
            .warnings
            .iter()
            .any(|value| value == "ACTIVE_CONTENT_IGNORED")
    );
    assert_eq!(result.tables.len(), 1);
    assert_eq!(result.tables[0].rows.len(), 2);
    assert_eq!(result.tables[0].rows[0], vec!["Key", "Value"]);
    assert_eq!(result.links.len(), 1);
    assert!(
        result
            .segments
            .iter()
            .all(|segment| !segment.text.contains("throw"))
    );
}

#[test]
fn pcm_wav_silence_is_explicit_and_has_no_transcript() {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36u32).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&(16u32).to_le_bytes());
    bytes.extend_from_slice(&(1u16).to_le_bytes());
    bytes.extend_from_slice(&(1u16).to_le_bytes());
    bytes.extend_from_slice(&(8_000u32).to_le_bytes());
    bytes.extend_from_slice(&(16_000u32).to_le_bytes());
    bytes.extend_from_slice(&(2u16).to_le_bytes());
    bytes.extend_from_slice(&(16u16).to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(0u32).to_le_bytes());
    let result = match parse_bytes(&bytes, &binding(&bytes)) {
        Ok(value) => value,
        Err(error) => std::panic::panic_any(error),
    };
    let Some(MediaMetadata::Audio {
        silence_state,
        transcript_state,
        ..
    }) = result.metadata
    else {
        std::panic::panic_any("audio metadata missing");
    };
    assert_eq!(silence_state, "SILENCE_CONFIRMED");
    assert_eq!(transcript_state, "NOT_APPLICABLE_SILENCE");
    assert!(result.segments.is_empty());
}

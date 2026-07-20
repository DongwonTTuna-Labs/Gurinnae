use super::*;
use sha2::{Digest, Sha256};
use std::path::Path;

use super::super::super::common::{command_in_process_group, wait_with_timeout};

pub(super) fn transcribe_pcm(
    pcm: &[u8],
    rate: u32,
    channels: u16,
    duration: u64,
    binding: &AssetBinding,
) -> Result<Transcription, &'static str> {
    let executable =
        absolute_runtime_path("GURINNAE_WHISPER_PATH", "/opt/gurinnae/bin/whisper-cli")
            .ok_or("POLICY_BLOCKED")?;
    let model = absolute_runtime_path(
        "GURINNAE_WHISPER_MODEL",
        "/opt/gurinnae/models/ggml-large-v3-turbo.bin",
    )
    .ok_or("POLICY_BLOCKED")?;
    if !executable.is_file()
        || !model.is_file()
        || !runtime_hash_matches(&executable, "GURINNAE_WHISPER_SHA256")
        || !runtime_hash_matches(&model, "GURINNAE_WHISPER_MODEL_SHA256")
    {
        return Err("MEDIA_RUNTIME_NOT_ACTIVATED");
    }
    let canonical = canonical_pcm_16khz(pcm, rate, channels).ok_or("AUDIO_DURATION_LIMIT")?;
    let root =
        absolute_runtime_path("GURINNAE_ASR_WORKDIR", "/work/asr").ok_or("POLICY_BLOCKED")?;
    fs::create_dir_all(&root).map_err(|_| "MEDIA_RUNTIME_NOT_ACTIVATED")?;
    let directory = root.join(format!("job-{}", &binding.content_sha256[..24]));
    if directory.exists() {
        fs::remove_dir_all(&directory).map_err(|_| "MEDIA_RUNTIME_NOT_ACTIVATED")?;
    }
    fs::create_dir(&directory).map_err(|_| "MEDIA_RUNTIME_NOT_ACTIVATED")?;
    let input = directory.join("input.wav");
    let output_prefix = directory.join("output");
    fs::write(&input, canonical).map_err(|_| "MEDIA_RUNTIME_NOT_ACTIVATED")?;
    let parsed = run_whisper(&executable, &model, &input, &output_prefix, &directory)?;
    transcription_from_output(parsed, duration, binding)
}

fn runtime_hash_matches(path: &Path, variable: &str) -> bool {
    let Some(expected) = std::env::var(variable).ok() else {
        return false;
    };
    if expected.len() != 64 || !expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return false;
    }
    let Ok(bytes) = std::fs::read(path) else {
        return false;
    };
    let actual = Sha256::digest(bytes);
    format!("{actual:x}").eq_ignore_ascii_case(&expected)
}

fn run_whisper(
    executable: &Path,
    model: &Path,
    input: &Path,
    output_prefix: &Path,
    directory: &Path,
) -> Result<WhisperOutput, &'static str> {
    let input_value = input.to_str().ok_or("POLICY_BLOCKED")?;
    let output_value = output_prefix.to_str().ok_or("POLICY_BLOCKED")?;
    let mut command = Command::new(executable);
    command.args([
        "--model",
        model.to_str().ok_or("POLICY_BLOCKED")?,
        "--file",
        input_value,
        "--threads",
        "1",
        "--processors",
        "1",
        "--best-of",
        "1",
        "--beam-size",
        "1",
        "--temperature",
        "0.00",
        "--temperature-inc",
        "0.00",
        "--no-fallback",
        "--output-json-full",
        "--output-file",
        output_value,
        "--no-prints",
        "--language",
        "auto",
        "--no-gpu",
        "--no-flash-attn",
        "--suppress-nst",
    ]);
    let mut child = command_in_process_group(&mut command)
        .env_clear()
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "MEDIA_RUNTIME_NOT_ACTIVATED")?;
    let status = wait_with_timeout(&mut child, std::time::Duration::from_secs(120))
        .map_err(|_| "MEDIA_RUNTIME_NOT_ACTIVATED")?;
    if !status.success() {
        let _ = fs::remove_dir_all(directory);
        return Err("ASR_MALFORMED_OUTPUT");
    }
    let output_path = directory.join("output.json");
    let output = fs::read(&output_path).map_err(|_| "ASR_MALFORMED_OUTPUT")?;
    if u64::try_from(output.len()).map_or(true, |size| size > ASR_OUTPUT_LIMIT) {
        let _ = fs::remove_dir_all(directory);
        return Err("ASR_OUTPUT_LIMIT");
    }
    let parsed: WhisperOutput =
        serde_json::from_slice(&output).map_err(|_| "ASR_MALFORMED_OUTPUT")?;
    let _ = fs::remove_dir_all(directory);
    Ok(parsed)
}

fn transcription_from_output(
    parsed: WhisperOutput,
    duration: u64,
    binding: &AssetBinding,
) -> Result<Transcription, &'static str> {
    if !matches!(parsed.language.as_deref(), None | Some("ko") | Some("en")) {
        return Ok(Transcription {
            segments: Vec::new(),
            abstention: Some("UNSUPPORTED_LANGUAGE".to_owned()),
        });
    }
    let mut segments = Vec::new();
    let had_transcription = !parsed.transcription.is_empty();
    for item in &parsed.transcription {
        let text = item.text.trim();
        if text.is_empty() {
            continue;
        }
        let confidence = token_confidence(&item.tokens);
        if confidence.is_none_or(|value| value < 5500) {
            continue;
        }
        let start = item
            .offsets
            .as_ref()
            .and_then(|value| value.from.as_ref().and_then(WhisperTime::millis))
            .unwrap_or(0)
            .min(duration);
        let end = item
            .offsets
            .as_ref()
            .and_then(|value| value.to.as_ref().and_then(WhisperTime::millis))
            .unwrap_or(start.saturating_add(1))
            .min(duration);
        if end <= start {
            continue;
        }
        let locator = Locator {
            kind: LocatorKind::AudioTimeRange,
            value: format!("time-ms:start={start},end={end}"),
        };
        segments.push(segment(
            binding,
            "TRANSCRIPT",
            text,
            locator,
            parsed.language.clone(),
            confidence,
            MEDIA_VERSION,
        ));
    }
    let abstention = if segments.is_empty() {
        Some(
            if !had_transcription {
                "NON_SPEECH"
            } else {
                "LOW_CONFIDENCE"
            }
            .to_owned(),
        )
    } else {
        None
    };
    Ok(Transcription {
        segments,
        abstention,
    })
}

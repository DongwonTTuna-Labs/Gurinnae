pub(super) struct Transcription {
    pub(super) segments: Vec<ExtractionSegment>,
    pub(super) abstention: Option<String>,
}

#[path = "media_asr_transcribe.rs"]
mod transcribe_impl;

pub(super) fn transcribe_pcm(
    pcm: &[u8],
    rate: u32,
    channels: u16,
    duration: u64,
    binding: &AssetBinding,
) -> Result<Transcription, &'static str> {
    transcribe_impl::transcribe_pcm(pcm, rate, channels, duration, binding)
}

fn canonical_pcm_16khz(pcm: &[u8], rate: u32, channels: u16) -> Option<Vec<u8>> {
    if rate == 0 || channels == 0 || !pcm.len().is_multiple_of(usize::from(channels) * 2) {
        return None;
    }
    let source_frames = pcm.len() / (usize::from(channels) * 2);
    let output_frames = source_frames
        .checked_mul(16_000)?
        .checked_div(usize::try_from(rate).ok()?)?;
    let output_bytes = output_frames.checked_mul(2)?;
    if output_bytes > 900_000_000 {
        return None;
    }
    let mut mono = Vec::with_capacity(source_frames);
    for frame in 0..source_frames {
        let mut sum = 0i64;
        for channel in 0..usize::from(channels) {
            let offset = (frame * usize::from(channels) + channel) * 2;
            let sample = i16::from_le_bytes([pcm[offset], pcm[offset + 1]]);
            sum = sum.checked_add(i64::from(sample))?;
        }
        mono.push(i16::try_from(sum / i64::from(channels)).ok()?);
    }
    let mut data = Vec::with_capacity(output_bytes);
    for index in 0..output_frames {
        let source_position = index.checked_mul(usize::try_from(rate).ok()?)?;
        let source_index = source_position / 16_000;
        let sample = *mono.get(source_index.min(mono.len().saturating_sub(1)))?;
        data.extend_from_slice(&sample.to_le_bytes());
    }
    let byte_len = u32::try_from(data.len()).ok()?;
    let riff_size = byte_len.checked_add(36)?;
    let mut wav = Vec::with_capacity(data.len().saturating_add(44));
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&riff_size.to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&16_000u32.to_le_bytes());
    wav.extend_from_slice(&32_000u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&byte_len.to_le_bytes());
    wav.extend_from_slice(&data);
    Some(wav)
}

#[derive(Deserialize)]
struct WhisperOutput {
    language: Option<String>,
    #[serde(default)]
    transcription: Vec<WhisperSegment>,
}
#[derive(Deserialize)]
struct WhisperSegment {
    text: String,
    offsets: Option<WhisperOffsets>,
    #[serde(default)]
    tokens: Vec<WhisperToken>,
}
#[derive(Deserialize)]
struct WhisperOffsets {
    from: Option<WhisperTime>,
    to: Option<WhisperTime>,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum WhisperTime {
    Milliseconds(u64),
    Clock(String),
}

impl WhisperTime {
    fn millis(&self) -> Option<u64> {
        match self {
            Self::Milliseconds(value) => Some(*value),
            Self::Clock(value) => {
                let value = value.replace(',', ".");
                if let Some((hours, rest)) = value.split_once(':') {
                    let (minutes, seconds) = rest.split_once(':')?;
                    let hours = hours.parse::<u64>().ok()?;
                    let minutes = minutes.parse::<u64>().ok()?;
                    if minutes >= 60 {
                        return None;
                    }
                    let seconds_ms = parse_timestamp_ms_floor(seconds)?;
                    hours
                        .checked_mul(3_600_000)?
                        .checked_add(minutes.checked_mul(60_000)?)?
                        .checked_add(seconds_ms)
                } else {
                    parse_timestamp_ms_floor(&value)
                }
            }
        }
    }
}
#[derive(Deserialize)]
struct WhisperToken {
    p: Option<f64>,
}

fn token_confidence(tokens: &[WhisperToken]) -> Option<u16> {
    if tokens.is_empty() {
        return None;
    }
    let mut sum = 0.0f64;
    let mut count = 0u32;
    for token in tokens {
        let probability = token.p?;
        if !probability.is_finite() {
            return None;
        }
        sum += probability;
        count = count.checked_add(1)?;
    }
    let value = (sum / f64::from(count) * 10_000.0).round();
    (value.is_finite() && value >= 0.0 && value <= f64::from(u16::MAX)).then_some(value as u16)
}
use std::{
    fs,
    path::PathBuf,
    process::{Command, Stdio},
};

use serde::Deserialize;

use super::super::{AssetBinding, ExtractionSegment, Locator, LocatorKind, segment};

const MEDIA_VERSION: &str = "ffmpeg-8.0.1+gurinnae-ffmpeg-subprocess-media-v1";
const ASR_OUTPUT_LIMIT: u64 = 16_777_216;

fn absolute_runtime_path(variable: &str, fallback: &str) -> Option<PathBuf> {
    let value = std::env::var(variable).unwrap_or_else(|_| fallback.to_owned());
    let path = PathBuf::from(value);
    path.is_absolute().then_some(path)
}

fn parse_timestamp_ms_floor(value: &str) -> Option<u64> {
    if value.is_empty() || value.starts_with('-') || value.contains(['e', 'E', '+']) {
        return None;
    }
    let (whole, fractional) = value.split_once('.').map_or((value, ""), |parts| parts);
    if whole.is_empty() || !whole.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    if !fractional.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let seconds = whole.parse::<u64>().ok()?;
    let milliseconds = seconds.checked_mul(1000)?;
    let mut prefix = fractional.chars().take(3).collect::<String>();
    while prefix.len() < 3 {
        prefix.push('0');
    }
    milliseconds.checked_add(prefix.parse::<u64>().ok()?)
}

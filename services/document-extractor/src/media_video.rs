use std::{
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use image::{DynamicImage, ImageBuffer, Rgb};
use serde::Deserialize;

use super::super::common::{bounded_stdout, command_in_process_group, terminate_process_group};
use super::super::{
    AssetBinding, ExtractionShot, Locator, LocatorKind, MAX_AUDIO_CHANNELS, MAX_AUDIO_DURATION_MS,
    MAX_AUDIO_RATE, MediaMetadata, MultimodalExtractionResult, ParseError, base_result, segment,
    sha256_hex, stable_id,
};
use super::media_asr::{Transcription, transcribe_pcm};
use super::media_video_shots::{FrameTiming, build_shots, frame_slice};

const MEDIA_VERSION: &str = "ffmpeg-8.0.1+gurinnae-ffmpeg-subprocess-media-v1";
const MAX_CHILD_OUTPUT: u64 = 1_000_000_000;

pub(super) fn parse_webm(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    parse_impl::parse_webm_impl(bytes, binding)
}

#[path = "media_video_parse.rs"]
mod parse_impl;

fn append_video_ocr(
    result: &mut MultimodalExtractionResult,
    binding: &AssetBinding,
    ocr: &super::super::image::OcrOutput,
    shot_locator: &Locator,
    version: &str,
) {
    let time = shot_locator.value.as_str();
    for line in &ocr.lines {
        result.segments.push(segment(
            binding,
            "OCR_LINE",
            &line.text,
            Locator {
                kind: LocatorKind::VideoRegionTime,
                value: format!("{time};{}", line.locator),
            },
            Some("und".to_owned()),
            line.confidence,
            version,
        ));
    }
    for word in &ocr.words {
        result.segments.push(segment(
            binding,
            "OCR_WORD",
            &word.text,
            Locator {
                kind: LocatorKind::VideoRegionTime,
                value: format!("{time};{}", word.locator),
            },
            Some("und".to_owned()),
            word.confidence,
            version,
        ));
    }
}

fn absolute_runtime_path(variable: &str, fallback: &str) -> Option<PathBuf> {
    let value = std::env::var(variable).unwrap_or_else(|_| fallback.to_owned());
    let path = PathBuf::from(value);
    path.is_absolute().then_some(path)
}

enum ProbeError {
    Runtime,
    Corrupt,
}

fn run_ffprobe(bytes: &[u8], executable: &Path) -> Result<Ffprobe, ProbeError> {
    let mut command = Command::new(executable);
    command.args([
        "-v",
        "error",
        "-nostdin",
        "-protocol_whitelist",
        "pipe",
        "-show_error",
        "-show_format",
        "-show_streams",
        "-show_frames",
        "-of",
        "json=compact=1",
        "pipe:0",
    ]);
    let mut child = command_in_process_group(&mut command)
        .env_clear()
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ProbeError::Runtime)?;
    if let Some(mut stdin) = child.stdin.take()
        && stdin.write_all(bytes).is_err()
    {
        terminate_process_group(&mut child);
        return Err(ProbeError::Corrupt);
    }
    let (status, output) =
        bounded_stdout(&mut child, 16_777_216, std::time::Duration::from_secs(120))
            .map_err(|_| ProbeError::Corrupt)?;
    if !status.success() {
        return Err(ProbeError::Corrupt);
    }
    serde_json::from_slice(&output).map_err(|_| ProbeError::Corrupt)
}

enum ChildError {
    Runtime,
    Malformed,
}

fn run_ffmpeg_output(
    bytes: &[u8],
    executable: &Path,
    args: &[&str],
    max_output: u64,
) -> Result<Vec<u8>, ChildError> {
    let mut command = Command::new(executable);
    command.args(args);
    let mut child = command_in_process_group(&mut command)
        .env_clear()
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ChildError::Runtime)?;
    if let Some(mut stdin) = child.stdin.take()
        && stdin.write_all(bytes).is_err()
    {
        terminate_process_group(&mut child);
        return Err(ChildError::Malformed);
    }
    let (status, output) =
        bounded_stdout(&mut child, max_output, std::time::Duration::from_secs(120))
            .map_err(|_| ChildError::Malformed)?;
    if !status.success() {
        return Err(ChildError::Malformed);
    }
    Ok(output)
}

struct ValidatedWebm {
    width: u32,
    height: u32,
    duration: u64,
    frame_rate: u32,
    frame_count: u64,
    frames: Vec<FrameTiming>,
    audio: Option<AudioStream>,
}

#[derive(Deserialize)]
struct Ffprobe {
    streams: Vec<FfprobeStream>,
    frames: Option<Vec<FfprobeFrame>>,
}

#[derive(Deserialize)]
struct FfprobeStream {
    codec_type: Option<String>,
    codec_name: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    sample_rate: Option<String>,
    channels: Option<u16>,
}

#[derive(Deserialize)]
struct FfprobeFrame {
    media_type: Option<String>,
    best_effort_timestamp_time: Option<String>,
    pkt_duration_time: Option<String>,
    duration_time: Option<String>,
}

struct AudioStream {
    codec: String,
    sample_rate: u32,
    channels: u16,
}

fn parse_timestamp_ms_floor(value: &str) -> Option<u64> {
    parse_timestamp_ms(value, false)
}

fn parse_timestamp_ms_ceil(value: &str) -> Option<u64> {
    parse_timestamp_ms(value, true)
}

fn parse_timestamp_ms(value: &str, ceil: bool) -> Option<u64> {
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
    if fractional.is_empty() {
        return Some(milliseconds);
    }
    let mut prefix = fractional.chars().take(3).collect::<String>();
    while prefix.len() < 3 {
        prefix.push('0');
    }
    let fraction_ms = prefix.parse::<u64>().ok()?;
    let truncated = milliseconds.checked_add(fraction_ms)?;
    if ceil && fractional.chars().skip(3).any(|character| character != '0') {
        truncated.checked_add(1)
    } else {
        Some(truncated)
    }
}

fn validate_frame_timings(
    probe: &Ffprobe,
) -> Result<(Vec<FrameTiming>, u64, u64, u32), &'static str> {
    let mut frames = probe
        .frames
        .as_ref()
        .map(|items| {
            items
                .iter()
                .filter(|frame| frame.media_type.as_deref() == Some("video"))
                .map(|frame| {
                    let timestamp = frame
                        .best_effort_timestamp_time
                        .as_deref()
                        .and_then(parse_timestamp_ms_floor)
                        .ok_or("CORRUPT_VIDEO")?;
                    let duration = frame
                        .pkt_duration_time
                        .as_deref()
                        .or(frame.duration_time.as_deref())
                        .and_then(parse_timestamp_ms_ceil)
                        .unwrap_or(0);
                    Ok(FrameTiming {
                        timestamp,
                        end: timestamp.saturating_add(duration),
                    })
                })
                .collect::<Result<Vec<_>, &'static str>>()
        })
        .transpose()?
        .unwrap_or_default();
    if frames.is_empty() {
        return Err("CORRUPT_VIDEO");
    }
    frames.sort_by_key(|frame| (frame.timestamp, frame.end));
    for pair in frames.windows(2) {
        if pair[1].timestamp < pair[0].timestamp {
            return Err("CORRUPT_VIDEO");
        }
    }
    for index in 0..frames.len() {
        if frames[index].end <= frames[index].timestamp {
            frames[index].end = frames
                .get(index + 1)
                .map_or(frames[index].timestamp, |next| next.timestamp);
        }
        if frames[index].end <= frames[index].timestamp {
            return Err("CORRUPT_VIDEO");
        }
    }
    let duration = frames.iter().map(|frame| frame.end).max().unwrap_or(0);
    if duration == 0 || duration > MAX_AUDIO_DURATION_MS {
        return Err("VIDEO_DURATION_LIMIT");
    }
    let frame_count = u64::try_from(frames.len()).map_err(|_| "VIDEO_FRAME_LIMIT")?;
    let frame_rate = u32::try_from(
        frame_count
            .checked_mul(1_000_000)
            .ok_or("VIDEO_FRAME_LIMIT")?
            .checked_div(duration)
            .ok_or("CORRUPT_VIDEO")?,
    )
    .map_err(|_| "VIDEO_FRAME_LIMIT")?;
    Ok((frames, duration, frame_count, frame_rate))
}

fn validate_webm_probe(probe: &Ffprobe) -> Result<ValidatedWebm, &'static str> {
    let videos = probe
        .streams
        .iter()
        .filter(|s| s.codec_type.as_deref() == Some("video"))
        .collect::<Vec<_>>();
    let audios = probe
        .streams
        .iter()
        .filter(|s| s.codec_type.as_deref() == Some("audio"))
        .collect::<Vec<_>>();
    let unknown_stream = probe
        .streams
        .iter()
        .any(|s| !matches!(s.codec_type.as_deref(), Some("video") | Some("audio")));
    if videos.len() != 1 || audios.len() > 1 || unknown_stream {
        return Err("VIDEO_STREAM_LIMIT");
    }
    let stream = videos.first().copied().ok_or("VIDEO_STREAM_LIMIT")?;
    if stream.codec_name.as_deref() != Some("vp8") {
        return Err("VIDEO_CODEC_UNSUPPORTED");
    }
    let width = stream.width.unwrap_or(0);
    let height = stream.height.unwrap_or(0);
    if width == 0 || height == 0 || width > 7680 || height > 4320 {
        return Err("VIDEO_DIMENSION_LIMIT");
    }
    let (frames, duration, frame_count, frame_rate) = validate_frame_timings(probe)?;
    let audio = audios.first().map(|stream| {
        let codec = stream.codec_name.clone().unwrap_or_default();
        let sample_rate = stream
            .sample_rate
            .as_deref()
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(0);
        let channels = stream.channels.unwrap_or(0);
        (codec, sample_rate, channels)
    });
    if audio.as_ref().is_some_and(|(codec, rate, channels)| {
        !matches!(codec.as_str(), "opus" | "vorbis")
            || *rate == 0
            || *rate > MAX_AUDIO_RATE
            || *channels == 0
            || *channels > MAX_AUDIO_CHANNELS
    }) {
        return Err("AUDIO_CODEC_UNSUPPORTED");
    }
    Ok(ValidatedWebm {
        width,
        height,
        duration,
        frame_rate,
        frame_count,
        frames,
        audio: audio.map(|(codec, sample_rate, channels)| AudioStream {
            codec,
            sample_rate,
            channels,
        }),
    })
}

use std::{
    io::Write,
    process::{Command, Stdio},
};

use serde::Deserialize;

use super::common::{bounded_stdout, parse_rate_millihz, parse_seconds_ms};
use super::{
    AssetBinding, ExtractionShot, Locator, LocatorKind, MAX_AUDIO_CHANNELS, MAX_AUDIO_DURATION_MS,
    MAX_AUDIO_RATE, MediaMetadata, MultimodalExtractionResult, ParseError, base_result, rejected,
    stable_id,
};

pub(super) fn parse_wav(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    let version = "ffmpeg-8.0.1+gurinnae-ffmpeg-subprocess-media-v1";
    if bytes.len() < 12 || !bytes.starts_with(b"RIFF") || bytes.get(8..12) != Some(b"WAVE") {
        return Ok(corrupt_audio(binding, version));
    }
    let Some((fmt, data)) = scan_wav_chunks(bytes)? else {
        return Ok(corrupt_audio(binding, version));
    };
    if fmt.len() < 16 {
        return Ok(corrupt_audio(binding, version));
    }
    let audio_format = u16::from_le_bytes([fmt[0], fmt[1]]);
    let channels = u16::from_le_bytes([fmt[2], fmt[3]]);
    let rate = u32::from_le_bytes([fmt[4], fmt[5], fmt[6], fmt[7]]);
    let block = u16::from_le_bytes([fmt[12], fmt[13]]);
    let bits = u16::from_le_bytes([fmt[14], fmt[15]]);
    if audio_format != 1 || bits != 16 {
        return Ok(reject_audio(binding, version, "AUDIO_CODEC_UNSUPPORTED"));
    }
    if channels == 0 || channels > MAX_AUDIO_CHANNELS {
        return Ok(reject_audio(binding, version, "AUDIO_CHANNEL_LIMIT"));
    }
    if rate == 0 || rate > MAX_AUDIO_RATE {
        return Ok(reject_audio(binding, version, "AUDIO_SAMPLE_RATE_LIMIT"));
    }
    if block != channels.saturating_mul(2) || data.len() % usize::from(block) != 0 {
        return Ok(corrupt_audio(binding, version));
    }
    let samples = data.len() / usize::from(block);
    let duration = u64::try_from(samples)
        .map_or(u64::MAX, |value| value)
        .saturating_mul(1000)
        / u64::from(rate);
    if duration > MAX_AUDIO_DURATION_MS {
        return Ok(reject_audio(binding, version, "AUDIO_DURATION_LIMIT"));
    }
    let silence = data.chunks_exact(2).all(|pair| pair == [0, 0]);
    let mut result = base_result(binding, "audio/wav", "wav-media", version);
    result.metadata = Some(MediaMetadata::Audio {
        container: "RIFF_WAVE".to_owned(),
        codec: "PCM_S16LE".to_owned(),
        sample_rate_hz: rate,
        channel_count: channels,
        duration_ms: duration,
        silence_state: if silence {
            "SILENCE_CONFIRMED"
        } else {
            "NON_SILENT_UNCLASSIFIED"
        }
        .to_owned(),
        transcript_state: if silence {
            "NOT_APPLICABLE_SILENCE"
        } else {
            "NOT_ACTIVATED"
        }
        .to_owned(),
    });
    if silence {
        result.warnings.push("SILENCE_CONFIRMED".to_owned());
    } else {
        result.warnings.push("ASR_NOT_ACTIVATED".to_owned());
    }
    Ok(result)
}

fn corrupt_audio(binding: &AssetBinding, version: &str) -> MultimodalExtractionResult {
    rejected(binding, "audio/wav", "wav-media", version, "CORRUPT_AUDIO")
}

fn reject_audio(binding: &AssetBinding, version: &str, code: &str) -> MultimodalExtractionResult {
    rejected(binding, "audio/wav", "wav-media", version, code)
}

type WavChunks<'a> = Option<(&'a [u8], &'a [u8])>;

fn scan_wav_chunks(bytes: &[u8]) -> Result<WavChunks<'_>, ParseError> {
    let declared = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize;
    if declared.checked_add(8) != Some(bytes.len()) {
        return Ok(None);
    }
    let mut position = 12usize;
    let mut fmt = None;
    let mut data = None;
    while position
        .checked_add(8)
        .is_some_and(|end| end <= bytes.len())
    {
        let Some(header) = bytes.get(position..position + 8) else {
            return Ok(None);
        };
        let id = &header[..4];
        let size = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
        let start = position + 8;
        let end = start
            .checked_add(size)
            .ok_or(ParseError::Malformed("CORRUPT_AUDIO".to_owned()))?;
        if end > bytes.len() {
            return Ok(None);
        }
        match id {
            b"fmt " if fmt.is_none() => fmt = Some(&bytes[start..end]),
            b"data" if data.is_none() => data = Some(&bytes[start..end]),
            b"fmt " | b"data" => return Ok(None),
            _ => {}
        }
        let Some(next) = end.checked_add(size & 1) else {
            return Ok(None);
        };
        if next > bytes.len() {
            return Ok(None);
        }
        position = next;
    }
    if position != bytes.len() {
        return Ok(None);
    }
    Ok(fmt.zip(data))
}

pub(super) fn parse_webm(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    let version = "ffmpeg-8.0.1+gurinnae-ffmpeg-subprocess-media-v1";
    if bytes.len() < 4 || !bytes.starts_with(b"\x1a\x45\xdf\xa3") {
        return Ok(reject_video(binding, version, "CORRUPT_VIDEO"));
    }
    let configured = match std::env::var("GURINNAE_FFPROBE_PATH") {
        Ok(value) => value,
        Err(_) => "/opt/gurinnae/bin/ffprobe".to_owned(),
    };
    let ffprobe = configured.as_str();
    if !std::path::Path::new(ffprobe).is_absolute() {
        return Ok(reject_video(binding, version, "CORRUPT_VIDEO"));
    }
    if !std::path::Path::new(ffprobe).is_file() {
        return Ok(reject_video(
            binding,
            version,
            "MEDIA_RUNTIME_NOT_ACTIVATED",
        ));
    }
    let ffmpeg = match std::env::var("GURINNAE_FFMPEG_PATH") {
        Ok(value) => value,
        Err(_) => "/opt/gurinnae/bin/ffmpeg".to_owned(),
    };
    if !std::path::Path::new(&ffmpeg).is_absolute() || !std::path::Path::new(&ffmpeg).is_file() {
        return Ok(reject_video(
            binding,
            version,
            "MEDIA_RUNTIME_NOT_ACTIVATED",
        ));
    }
    let probe = match run_ffprobe(bytes, ffprobe) {
        Ok(value) => value,
        Err(ProbeError::Runtime) => {
            return Ok(reject_video(
                binding,
                version,
                "MEDIA_RUNTIME_NOT_ACTIVATED",
            ));
        }
        Err(ProbeError::Corrupt) => return Ok(reject_video(binding, version, "CORRUPT_VIDEO")),
    };
    let data = match validate_webm_probe(&probe) {
        Ok(value) => value,
        Err(code) => return Ok(reject_video(binding, version, code)),
    };
    let mut result = base_result(binding, "video/webm", "webm-media", version);
    result.metadata = Some(MediaMetadata::Video {
        container: "WEBM".to_owned(),
        duration_ms: data.duration,
        width_px: data.width,
        height_px: data.height,
        frame_rate_millihz: data.frame_rate,
        video_codec: "VP8".to_owned(),
        frame_count: data.frame_count,
        audio_stream_state: if data.audio_codec.is_some() {
            "DECODED"
        } else {
            "ABSENT"
        }
        .to_owned(),
        audio_codec: data.audio_codec.clone(),
        transcript_state: if data.audio_codec.is_some() {
            "NOT_ACTIVATED"
        } else {
            "NOT_APPLICABLE_NO_AUDIO"
        }
        .to_owned(),
    });
    if data.audio_codec.is_some() {
        result.warnings.push("ASR_NOT_ACTIVATED".to_owned());
    }
    let locator = Locator {
        kind: LocatorKind::VideoTimeRange,
        value: format!("time-ms:start=0,end={}", data.duration),
    };
    result.shots.push(ExtractionShot {
        shot_id: stable_id(binding, &locator.value, "shot"),
        locator,
        decoded_frame_count: data.frame_count,
        representative_frame_sha256: binding.content_sha256.clone(),
        source_asset_id: binding.asset_id,
        source_asset_revision: binding.asset_revision,
        source_content_sha256: binding.content_sha256.clone(),
        extraction_version: version.to_owned(),
        confidence_basis_points: None,
    });
    Ok(result)
}

fn reject_video(binding: &AssetBinding, version: &str, code: &str) -> MultimodalExtractionResult {
    rejected(binding, "video/webm", "webm-media", version, code)
}

enum ProbeError {
    Runtime,
    Corrupt,
}

fn run_ffprobe(bytes: &[u8], executable: &str) -> Result<Ffprobe, ProbeError> {
    let mut child = Command::new(executable)
        .args([
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
        ])
        .env("LC_ALL", "C")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ProbeError::Runtime)?;
    if let Some(mut stdin) = child.stdin.take()
        && stdin.write_all(bytes).is_err()
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ProbeError::Corrupt);
    }
    let (status, output) =
        bounded_stdout(&mut child, 16_777_216).map_err(|_| ProbeError::Corrupt)?;
    if !status.success() {
        return Err(ProbeError::Corrupt);
    }
    serde_json::from_slice(&output).map_err(|_| ProbeError::Corrupt)
}

struct ValidatedWebm {
    width: u32,
    height: u32,
    duration: u64,
    frame_rate: u32,
    frame_count: u64,
    audio_codec: Option<String>,
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
    let width = stream.width.map_or(0, |value| value);
    let height = stream.height.map_or(0, |value| value);
    if width == 0 || height == 0 || width > 7680 || height > 4320 {
        return Err("VIDEO_DIMENSION_LIMIT");
    }
    let duration = probe
        .format
        .as_ref()
        .and_then(|f| f.duration.as_deref())
        .and_then(parse_seconds_ms)
        .map_or(0, |value| value);
    if duration == 0 {
        return Err("CORRUPT_VIDEO");
    }
    if duration > MAX_AUDIO_DURATION_MS {
        return Err("VIDEO_DURATION_LIMIT");
    }
    let frame_count = probe.frames.as_ref().map_or(0, |frames| {
        frames
            .iter()
            .filter(|f| f.media_type.as_deref() == Some("video"))
            .count() as u64
    });
    if frame_count == 0 {
        return Err("CORRUPT_VIDEO");
    }
    let frame_rate = stream
        .r_frame_rate
        .as_deref()
        .and_then(parse_rate_millihz)
        .map_or(0, |value| value);
    let audio_codec = audios.first().and_then(|audio| audio.codec_name.clone());
    if audio_codec
        .as_deref()
        .is_some_and(|codec| !matches!(codec, "opus" | "vorbis"))
    {
        return Err("AUDIO_CODEC_UNSUPPORTED");
    }
    Ok(ValidatedWebm {
        width,
        height,
        duration,
        frame_rate,
        frame_count,
        audio_codec,
    })
}

#[derive(Deserialize)]
struct Ffprobe {
    streams: Vec<FfprobeStream>,
    format: Option<FfprobeFormat>,
    frames: Option<Vec<FfprobeFrame>>,
}
#[derive(Deserialize)]
struct FfprobeStream {
    codec_type: Option<String>,
    codec_name: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    r_frame_rate: Option<String>,
}
#[derive(Deserialize)]
struct FfprobeFormat {
    duration: Option<String>,
}
#[derive(Deserialize)]
struct FfprobeFrame {
    media_type: Option<String>,
}

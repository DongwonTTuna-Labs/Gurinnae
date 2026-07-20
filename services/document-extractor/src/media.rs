use super::{
    AssetBinding, ExtractionSegment, Locator, MAX_AUDIO_CHANNELS, MAX_AUDIO_DURATION_MS,
    MAX_AUDIO_RATE, MediaMetadata, MultimodalExtractionResult, ParseError, base_result, rejected,
};

const MEDIA_VERSION: &str = "ffmpeg-8.0.1+gurinnae-ffmpeg-subprocess-media-v1";

pub(super) fn parse_wav(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    if bytes.len() < 12 || !bytes.starts_with(b"RIFF") || bytes.get(8..12) != Some(b"WAVE") {
        return Ok(corrupt_audio(binding));
    }
    let Some((fmt, data)) = scan_wav_chunks(bytes)? else {
        return Ok(corrupt_audio(binding));
    };
    if fmt.len() < 16 {
        return Ok(corrupt_audio(binding));
    }
    let audio_format = u16::from_le_bytes([fmt[0], fmt[1]]);
    let channels = u16::from_le_bytes([fmt[2], fmt[3]]);
    let rate = u32::from_le_bytes([fmt[4], fmt[5], fmt[6], fmt[7]]);
    let block = u16::from_le_bytes([fmt[12], fmt[13]]);
    let bits = u16::from_le_bytes([fmt[14], fmt[15]]);
    if audio_format != 1 || bits != 16 {
        return Ok(reject_audio(binding, "AUDIO_CODEC_UNSUPPORTED"));
    }
    if channels == 0 || channels > MAX_AUDIO_CHANNELS {
        return Ok(reject_audio(binding, "AUDIO_CHANNEL_LIMIT"));
    }
    if rate == 0 || rate > MAX_AUDIO_RATE {
        return Ok(reject_audio(binding, "AUDIO_SAMPLE_RATE_LIMIT"));
    }
    if block != channels.saturating_mul(2) || data.len() % usize::from(block) != 0 {
        return Ok(corrupt_audio(binding));
    }
    let samples = data.len() / usize::from(block);
    let Some(duration) = u64::try_from(samples)
        .ok()
        .and_then(|value| value.checked_mul(1000))
        .and_then(|value| value.checked_div(u64::from(rate)))
    else {
        return Ok(corrupt_audio(binding));
    };
    if duration > MAX_AUDIO_DURATION_MS {
        return Ok(reject_audio(binding, "AUDIO_DURATION_LIMIT"));
    }
    let silence = data.chunks_exact(2).all(|pair| pair == [0, 0]);
    let mut result = audio_result(binding, rate, channels, duration, silence, None);
    if silence {
        result.warnings.push("SILENCE_CONFIRMED".to_owned());
        return Ok(result);
    }

    let transcription = match media_asr::transcribe_pcm(data, rate, channels, duration, binding) {
        Ok(value) => value,
        Err(code) => return Ok(reject_audio(binding, code)),
    };
    let transcript_state = if transcription.segments.is_empty() {
        transcription.abstention.as_deref().unwrap_or("NON_SPEECH")
    } else {
        "TRANSCRIBED"
    };
    result.metadata = Some(MediaMetadata::Audio {
        container: "RIFF_WAVE".to_owned(),
        codec: "PCM_S16LE".to_owned(),
        sample_rate_hz: rate,
        channel_count: channels,
        duration_ms: duration,
        silence_state: "NON_SILENT_UNCLASSIFIED".to_owned(),
        transcript_state: transcript_state.to_owned(),
    });
    result.segments = transcription.segments;
    if let Some(abstention) = transcription.abstention {
        result.warnings.push(abstention);
    }
    sort_segments(&mut result.segments);
    Ok(result)
}

fn audio_result(
    binding: &AssetBinding,
    rate: u32,
    channels: u16,
    duration: u64,
    silence: bool,
    transcript_state: Option<&str>,
) -> MultimodalExtractionResult {
    let mut result = base_result(binding, "audio/wav", "wav-media", MEDIA_VERSION);
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
        transcript_state: transcript_state
            .unwrap_or(if silence {
                "NOT_APPLICABLE_SILENCE"
            } else {
                "POLICY_BLOCKED"
            })
            .to_owned(),
    });
    result
}

fn corrupt_audio(binding: &AssetBinding) -> MultimodalExtractionResult {
    rejected(
        binding,
        "audio/wav",
        "wav-media",
        MEDIA_VERSION,
        "CORRUPT_AUDIO",
    )
}

fn reject_audio(binding: &AssetBinding, code: &str) -> MultimodalExtractionResult {
    rejected(binding, "audio/wav", "wav-media", MEDIA_VERSION, code)
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

fn sort_segments(segments: &mut [ExtractionSegment]) {
    segments.sort_by(|left, right| {
        locator_start(&left.locator)
            .cmp(&locator_start(&right.locator))
            .then_with(|| {
                format!("{:?}", left.locator.kind).cmp(&format!("{:?}", right.locator.kind))
            })
            .then_with(|| {
                left.normalized_text_sha256
                    .cmp(&right.normalized_text_sha256)
            })
    });
}

fn locator_start(locator: &Locator) -> u64 {
    locator
        .value
        .split("start=")
        .nth(1)
        .and_then(|value| {
            value
                .split(|character: char| !character.is_ascii_digit())
                .next()
        })
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(u64::MAX)
}

#[path = "media_asr.rs"]
mod media_asr;
#[path = "media_video.rs"]
mod media_video;
#[path = "media_video_shots.rs"]
mod media_video_shots;

pub(super) fn parse_webm(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    media_video::parse_webm(bytes, binding)
}

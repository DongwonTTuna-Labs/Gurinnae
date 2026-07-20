use super::super::media_video_shots::Shot;
use super::*;
use sha2::{Digest, Sha256};

pub(super) fn parse_webm_impl(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<MultimodalExtractionResult, ParseError> {
    let (ffmpeg, data) = load_video(bytes, binding)?;
    let (frames, shots) = decode_video_frames(bytes, &ffmpeg, &data, binding)?;
    let transcription = decode_audio(bytes, &ffmpeg, &data, binding)?;
    assemble_video(binding, data, frames, shots, transcription)
}

fn load_video(
    bytes: &[u8],
    binding: &AssetBinding,
) -> Result<(PathBuf, ValidatedWebm), ParseError> {
    if bytes.len() < 4 || !bytes.starts_with(b"\x1a\x45\xdf\xa3") {
        return Err(ParseError::Malformed("CORRUPT_VIDEO".to_owned()));
    }
    let ffprobe = absolute_runtime_path("GURINNAE_FFPROBE_PATH", "/opt/gurinnae/bin/ffprobe")
        .ok_or_else(|| ParseError::Malformed("CORRUPT_VIDEO".to_owned()))?;
    let ffmpeg = absolute_runtime_path("GURINNAE_FFMPEG_PATH", "/opt/gurinnae/bin/ffmpeg")
        .ok_or_else(|| ParseError::Malformed("CORRUPT_VIDEO".to_owned()))?;
    if !ffprobe.is_file()
        || !ffmpeg.is_file()
        || !runtime_hash_matches(&ffprobe, "GURINNAE_FFPROBE_SHA256")
        || !runtime_hash_matches(&ffmpeg, "GURINNAE_FFMPEG_SHA256")
    {
        return Err(ParseError::Malformed(
            "MEDIA_RUNTIME_NOT_ACTIVATED".to_owned(),
        ));
    }
    let probe = run_ffprobe(bytes, &ffprobe).map_err(|error| {
        ParseError::Malformed(
            match error {
                ProbeError::Runtime => "MEDIA_RUNTIME_NOT_ACTIVATED",
                ProbeError::Corrupt => "CORRUPT_VIDEO",
            }
            .to_owned(),
        )
    })?;
    let data =
        validate_webm_probe(&probe).map_err(|code| ParseError::Malformed(code.to_owned()))?;
    let _ = binding;
    Ok((ffmpeg, data))
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

fn decode_video_frames(
    bytes: &[u8],
    ffmpeg: &Path,
    data: &ValidatedWebm,
    binding: &AssetBinding,
) -> Result<(Vec<u8>, Vec<Shot>), ParseError> {
    let expected = usize::try_from(data.frame_count)
        .ok()
        .and_then(|count| count.checked_mul(usize::try_from(data.width).ok()?))
        .and_then(|value| value.checked_mul(usize::try_from(data.height).ok()?))
        .and_then(|value| value.checked_mul(3))
        .ok_or_else(|| ParseError::Malformed("VIDEO_FRAME_LIMIT".to_owned()))?;
    if u64::try_from(expected).map_or(true, |size| size > MAX_CHILD_OUTPUT) {
        return Err(ParseError::Malformed("VIDEO_FRAME_LIMIT".to_owned()));
    }
    let frames = run_ffmpeg_output(
        bytes,
        ffmpeg,
        &[
            "-v",
            "error",
            "-nostdin",
            "-threads",
            "1",
            "-protocol_whitelist",
            "pipe",
            "-i",
            "pipe:0",
            "-map",
            "0:v:0",
            "-fps_mode",
            "passthrough",
            "-pix_fmt",
            "rgb24",
            "-f",
            "rawvideo",
            "pipe:1",
        ],
        MAX_CHILD_OUTPUT,
    )
    .map_err(|error| {
        ParseError::Malformed(
            match error {
                ChildError::Runtime => "MEDIA_RUNTIME_NOT_ACTIVATED",
                ChildError::Malformed => "CORRUPT_VIDEO",
            }
            .to_owned(),
        )
    })?;
    if frames.len() != expected {
        return Err(ParseError::Malformed("CORRUPT_VIDEO".to_owned()));
    }
    let shots =
        build_shots(&frames, data.width, data.height, &data.frames).map_err(
            |error| match error {
                ParseError::Malformed(code) => ParseError::Malformed(code),
                _ => ParseError::Malformed("CORRUPT_VIDEO".to_owned()),
            },
        )?;
    let _ = binding;
    Ok((frames, shots))
}

fn decode_audio(
    bytes: &[u8],
    ffmpeg: &Path,
    data: &ValidatedWebm,
    binding: &AssetBinding,
) -> Result<Option<Transcription>, ParseError> {
    let Some(audio) = data.audio.as_ref() else {
        return Ok(None);
    };
    let pcm = run_ffmpeg_output(
        bytes,
        ffmpeg,
        &[
            "-v",
            "error",
            "-nostdin",
            "-threads",
            "1",
            "-protocol_whitelist",
            "pipe",
            "-i",
            "pipe:0",
            "-map",
            "0:a:0",
            "-c:a",
            "pcm_s16le",
            "-f",
            "s16le",
            "pipe:1",
        ],
        MAX_CHILD_OUTPUT,
    )
    .map_err(|error| {
        ParseError::Malformed(
            match error {
                ChildError::Runtime => "MEDIA_RUNTIME_NOT_ACTIVATED",
                ChildError::Malformed => "CORRUPT_VIDEO",
            }
            .to_owned(),
        )
    })?;
    if pcm.chunks_exact(2).all(|pair| pair == [0, 0]) {
        return Ok(Some(Transcription {
            segments: Vec::new(),
            abstention: Some("NOT_APPLICABLE_SILENCE".to_owned()),
        }));
    }
    transcribe_pcm(
        &pcm,
        audio.sample_rate,
        audio.channels,
        data.duration,
        binding,
    )
    .map(Some)
    .map_err(|code| ParseError::Malformed(code.to_owned()))
}

fn assemble_video(
    binding: &AssetBinding,
    data: ValidatedWebm,
    frames: Vec<u8>,
    shots: Vec<Shot>,
    transcription: Option<Transcription>,
) -> Result<MultimodalExtractionResult, ParseError> {
    let transcript_state = transcription
        .as_ref()
        .map_or("NOT_APPLICABLE_NO_AUDIO", |value| {
            if value.segments.is_empty() {
                value.abstention.as_deref().unwrap_or("NON_SPEECH")
            } else {
                "TRANSCRIBED"
            }
        })
        .to_owned();
    let was_transcribed = transcript_state == "TRANSCRIBED";
    let mut result = base_result(binding, "video/webm", "webm-media", MEDIA_VERSION);
    result.metadata = Some(MediaMetadata::Video {
        container: "WEBM".to_owned(),
        duration_ms: data.duration,
        width_px: data.width,
        height_px: data.height,
        frame_rate_millihz: data.frame_rate,
        video_codec: "VP8".to_owned(),
        frame_count: data.frame_count,
        audio_stream_state: if data.audio.is_some() {
            "DECODED"
        } else {
            "ABSENT"
        }
        .to_owned(),
        audio_codec: data.audio.as_ref().map(|value| value.codec.clone()),
        transcript_state,
    });
    append_shots(&mut result, binding, &data, &frames, &shots)?;
    append_transcription(
        &mut result,
        data.audio.is_some(),
        was_transcribed,
        transcription,
    );
    super::super::sort_segments(&mut result.segments);
    Ok(result)
}

fn append_shots(
    result: &mut MultimodalExtractionResult,
    binding: &AssetBinding,
    data: &ValidatedWebm,
    frames: &[u8],
    shots: &[Shot],
) -> Result<(), ParseError> {
    for shot in shots {
        let representative = frame_slice(frames, data.width, data.height, shot.representative)
            .ok_or_else(|| ParseError::Malformed("CORRUPT_VIDEO".to_owned()))?;
        let image = ImageBuffer::<Rgb<u8>, Vec<u8>>::from_raw(
            data.width,
            data.height,
            representative.to_vec(),
        )
        .map(DynamicImage::ImageRgb8)
        .ok_or_else(|| ParseError::Malformed("CORRUPT_VIDEO".to_owned()))?;
        let ocr = super::super::super::image::tesseract_ocr(&image)
            .map_err(|code| ParseError::Malformed(code.to_string()))?;
        let locator = Locator {
            kind: LocatorKind::VideoTimeRange,
            value: format!("time-ms:start={},end={}", shot.start, shot.end),
        };
        result.shots.push(ExtractionShot {
            shot_id: stable_id(binding, &locator.value, "shot"),
            locator: locator.clone(),
            decoded_frame_count: shot.frame_count,
            representative_frame_sha256: sha256_hex(representative),
            source_asset_id: binding.asset_id,
            source_asset_revision: binding.asset_revision,
            source_content_sha256: binding.content_sha256.clone(),
            extraction_version: MEDIA_VERSION.to_owned(),
            confidence_basis_points: None,
        });
        append_video_ocr(result, binding, &ocr, &locator, MEDIA_VERSION);
    }
    Ok(())
}

fn append_transcription(
    result: &mut MultimodalExtractionResult,
    has_audio: bool,
    was_transcribed: bool,
    transcription: Option<Transcription>,
) {
    if let Some(transcription) = transcription {
        result.segments.extend(transcription.segments);
        if let Some(abstention) = transcription.abstention {
            result.warnings.push(abstention);
        }
    }
    if has_audio {
        if was_transcribed {
            result.warnings.push("ASR_TRANSCRIBED".to_owned());
        }
    } else {
        result.warnings.push("AUDIO_STREAM_ABSENT".to_owned());
    }
}

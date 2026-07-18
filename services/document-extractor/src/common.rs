use std::io::Read;

use image::DynamicImage;

pub fn detect_format(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("jpeg")
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        Some("tiff")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        Some("webp")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WAVE") {
        Some("wav")
    } else if bytes.starts_with(b"\x1a\x45\xdf\xa3")
        && bytes
            .windows(4)
            .any(|window| window.eq_ignore_ascii_case(b"webm"))
    {
        Some("webm")
    } else if looks_like_html(bytes) {
        Some("html")
    } else {
        None
    }
}

fn looks_like_html(bytes: &[u8]) -> bool {
    let value = match std::str::from_utf8(
        bytes
            .strip_prefix(&[0xef, 0xbb, 0xbf])
            .map_or(bytes, |value| value),
    ) {
        Ok(value) => value,
        Err(_) => return false,
    };
    let lower = value.to_ascii_lowercase();
    let trimmed = lower.trim_start();
    trimmed.starts_with("<!doctype html")
        || lower.contains("<html")
        || lower.contains("<head")
        || lower.contains("<body")
}
pub(super) fn bounded_stdout(
    child: &mut std::process::Child,
    maximum: u64,
) -> Result<(std::process::ExitStatus, Vec<u8>), std::io::Error> {
    let Some(stdout) = child.stdout.take() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "child stdout unavailable",
        ));
    };
    let mut bytes = Vec::new();
    stdout
        .take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)?;
    if u64::try_from(bytes.len()).map_or(true, |length| length > maximum) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "child output limit",
        ));
    }
    let status = child.wait()?;
    Ok((status, bytes))
}

pub(super) fn parse_seconds_ms(value: &str) -> Option<u64> {
    let (whole, fractional) = match value.split_once('.') {
        Some(parts) => parts,
        None => (value, "0"),
    };
    let seconds = whole.parse::<u64>().ok()?;
    let mut frac = fractional.chars().take(3).collect::<String>();
    while frac.len() < 3 {
        frac.push('0');
    }
    seconds
        .checked_mul(1000)?
        .checked_add(frac.parse::<u64>().ok()?)
}
pub(super) fn parse_rate_millihz(value: &str) -> Option<u32> {
    let (num, den) = value.split_once('/')?;
    let n = num.parse::<u64>().ok()?;
    let d = den.parse::<u64>().ok()?;
    u32::try_from(n.checked_mul(1_000_000)?.checked_div(d)?).ok()
}
pub(super) fn media_type(format: &str) -> &str {
    match format {
        "png" => "image/png",
        "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "tiff" => "image/tiff",
        _ => "application/octet-stream",
    }
}
pub(super) fn color_model(image: &DynamicImage) -> String {
    format!("{:?}", image.color())
}
pub(super) fn webp_is_animated(bytes: &[u8]) -> bool {
    bytes
        .windows(4)
        .position(|window| window == b"VP8X")
        .and_then(|offset| bytes.get(offset + 4))
        .is_some_and(|flags| flags & 0x02 != 0)
}
pub(super) fn tiff_has_multiple_ifds(bytes: &[u8]) -> bool {
    if bytes.len() < 10 {
        return false;
    }
    let little = bytes.starts_with(b"II");
    let offset = if little {
        u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]])
    } else {
        u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]])
    };
    let Some(offset) = usize::try_from(offset).ok() else {
        return false;
    };
    let Some(count_bytes) = offset.checked_add(2).and_then(|end| bytes.get(offset..end)) else {
        return false;
    };
    let count = if little {
        u16::from_le_bytes([count_bytes[0], count_bytes[1]])
    } else {
        u16::from_be_bytes([count_bytes[0], count_bytes[1]])
    };
    let Some(next_offset) = offset
        .checked_add(2)
        .and_then(|value| value.checked_add(usize::from(count).saturating_mul(12)))
    else {
        return false;
    };
    let Some(next) = next_offset
        .checked_add(4)
        .and_then(|end| bytes.get(next_offset..end))
    else {
        return false;
    };
    if little {
        u32::from_le_bytes([next[0], next[1], next[2], next[3]]) != 0
    } else {
        u32::from_be_bytes([next[0], next[1], next[2], next[3]]) != 0
    }
}

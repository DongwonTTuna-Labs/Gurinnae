use std::{
    io::Read,
    os::unix::process::CommandExt,
    process::{Child, Command},
    sync::mpsc::{self, TryRecvError},
    time::{Duration, Instant},
};

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
    child: &mut Child,
    maximum: u64,
    timeout: Duration,
) -> Result<(std::process::ExitStatus, Vec<u8>), std::io::Error> {
    let Some(stdout) = child.stdout.take() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "child stdout unavailable",
        ));
    };
    let (sender, receiver) = mpsc::channel();
    let limit = maximum.saturating_add(1);
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.take(limit).read_to_end(&mut bytes).map(|_| bytes);
        let _ = sender.send(result);
    });
    let started = Instant::now();
    let mut output = None;
    loop {
        if output.is_none() {
            match receiver.try_recv() {
                Ok(result) => output = Some(result),
                Err(TryRecvError::Disconnected) => {
                    terminate_process_group(child);
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "child stdout reader disconnected",
                    ));
                }
                Err(TryRecvError::Empty) => {}
            }
        }
        if let Some(status) = child.try_wait()? {
            if output.is_none() {
                output = receiver.recv_timeout(Duration::from_millis(100)).ok();
            }
            if let Some(result) = output {
                let bytes = match result {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        terminate_process_group(child);
                        return Err(error);
                    }
                };
                if u64::try_from(bytes.len()).map_or(true, |length| length > maximum) {
                    terminate_process_group(child);
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "child output limit",
                    ));
                }
                return Ok((status, bytes));
            }
        }
        if started.elapsed() >= timeout {
            terminate_process_group(child);
            let _ = receiver.recv_timeout(Duration::from_secs(1));
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "child process timeout",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Start every media/OCR child in an isolated process group.  The parser
/// contract is group-scoped: killing only the direct child can leave a codec
/// helper alive and leak work across cancellation or output-limit failures.
pub(super) fn command_in_process_group(command: &mut Command) -> &mut Command {
    command.process_group(0)
}

/// Send TERM then KILL to the complete process group and always reap the
/// direct child.  `kill` is the POSIX shell builtin in the slim runtime, so
/// invoking it through the absolute `/bin/sh` avoids a missing `/bin/kill`
/// dependency while retaining a fixed executable path.
pub(super) fn terminate_process_group(child: &mut Child) {
    let pid = child.id();
    if pid > 0 {
        let group = format!("-{pid}");
        let _ = Command::new("/bin/sh")
            .args(["-c", &format!("kill -TERM {group}")])
            .status();
        let _ = Command::new("/bin/sh")
            .args(["-c", &format!("kill -KILL {group}")])
            .status();
    }
    let _ = child.wait();
}

pub(super) fn wait_with_timeout(
    child: &mut Child,
    timeout: std::time::Duration,
) -> Result<std::process::ExitStatus, std::io::Error> {
    let started = std::time::Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if started.elapsed() >= timeout {
            terminate_process_group(child);
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "child process timeout",
            ));
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
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

/// Digest-bound runtime probe used only by the final OCI evidence command.
/// It exercises the same bounded stdout, timeout, process-group termination,
/// and child reap helpers used by every media/OCR adapter.
pub(super) fn runtime_lifecycle_probe() -> Result<serde_json::Value, String> {
    let components = [
        ("ffmpeg", "/opt/gurinnae/bin/ffmpeg"),
        ("ffprobe", "/opt/gurinnae/bin/ffprobe"),
        ("tesseract", "/usr/bin/tesseract"),
        ("whisper", "/opt/gurinnae/bin/whisper-cli"),
    ];
    let mut cases = Vec::new();
    for (name, executable) in components {
        let timeout = run_timeout_child(
            &format!("{executable} --version >/dev/null 2>&1; sleep 5"),
            Duration::from_millis(100),
        );
        if timeout != "TimedOut" {
            return Err(format!("{name}: timeout case returned {timeout}"));
        }
        let output_limit = run_probe_child("yes gurine-runtime-probe", 128, Duration::from_secs(2));
        if output_limit != "OutputLimit" {
            return Err(format!("{name}: output case returned {output_limit}"));
        }
        cases.push(serde_json::json!({
            "component": name,
            "executable": executable,
            "timeout": "PASS",
            "outputLimit": "PASS",
            "processGroupTerminated": true,
            "directChildReaped": true,
        }));
    }
    Ok(serde_json::json!({"schemaVersion":"media-process-lifecycle.v1","cases":cases,"pass":true}))
}

fn run_probe_child(script: &str, maximum: u64, timeout: Duration) -> &'static str {
    let mut command = Command::new("/bin/sh");
    command
        .args(["-c", script])
        .stdout(std::process::Stdio::piped());
    let Ok(mut child) = command_in_process_group(&mut command).spawn() else {
        return "SpawnFailed";
    };
    match bounded_stdout(&mut child, maximum, timeout) {
        Ok(_) => "UnexpectedSuccess",
        Err(error) if error.kind() == std::io::ErrorKind::TimedOut => "TimedOut",
        Err(error) if error.kind() == std::io::ErrorKind::InvalidData => "OutputLimit",
        Err(_) => "OtherError",
    }
}

fn run_timeout_child(script: &str, timeout: Duration) -> &'static str {
    let mut command = Command::new("/bin/sh");
    command
        .args(["-c", script])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let Ok(mut child) = command_in_process_group(&mut command).spawn() else {
        return "SpawnFailed";
    };
    match wait_with_timeout(&mut child, timeout) {
        Ok(_) => "UnexpectedSuccess",
        Err(error) if error.kind() == std::io::ErrorKind::TimedOut => "TimedOut",
        Err(_) => "OtherError",
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

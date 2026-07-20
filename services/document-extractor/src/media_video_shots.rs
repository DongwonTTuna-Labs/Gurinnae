use super::super::ParseError;

pub(super) fn build_shots(
    bytes: &[u8],
    width: u32,
    height: u32,
    timings: &[FrameTiming],
) -> Result<Vec<Shot>, ParseError> {
    if timings.is_empty() {
        return Err(ParseError::Malformed("CORRUPT_VIDEO".to_owned()));
    }
    let frame_size = usize::try_from(width)
        .ok()
        .and_then(|value| value.checked_mul(usize::try_from(height).ok()?))
        .and_then(|value| value.checked_mul(3))
        .ok_or(ParseError::Malformed("VIDEO_FRAME_LIMIT".to_owned()))?;
    let mut starts = vec![0usize];
    let mut prior = None;
    let mut current_start = timings[0].timestamp;
    for (index, timing) in timings.iter().enumerate() {
        let frame = bytes
            .get(index * frame_size..(index + 1) * frame_size)
            .ok_or(ParseError::Malformed("CORRUPT_VIDEO".to_owned()))?;
        let scaled = scale_rgb64(frame, width, height)?;
        if let Some(previous) = prior {
            let score = difference_score(&previous, &scaled);
            if score >= 1800 && timing.timestamp >= current_start.saturating_add(500) {
                starts.push(index);
                current_start = timing.timestamp;
            }
        }
        prior = Some(scaled);
    }
    let mut shots = Vec::with_capacity(starts.len());
    for (ordinal, start_index) in starts.iter().copied().enumerate() {
        let end_index = starts.get(ordinal + 1).copied().unwrap_or(timings.len());
        let start = timings[start_index].timestamp;
        let end = if end_index < timings.len() {
            timings[end_index].timestamp
        } else {
            timings.last().map_or(start, |frame| frame.end)
        };
        if end <= start {
            return Err(ParseError::Malformed("CORRUPT_VIDEO".to_owned()));
        }
        let midpoint = start.saturating_add((end - start) / 2);
        let representative = (start_index..end_index)
            .min_by_key(|index| {
                let timestamp = timings[*index].timestamp;
                (timestamp.abs_diff(midpoint), timestamp, *index)
            })
            .ok_or(ParseError::Malformed("CORRUPT_VIDEO".to_owned()))?;
        shots.push(Shot {
            start,
            end,
            representative,
            frame_count: u64::try_from(end_index - start_index)
                .map_err(|_| ParseError::Malformed("VIDEO_FRAME_LIMIT".to_owned()))?,
        });
    }
    Ok(shots)
}

fn scale_rgb64(frame: &[u8], width: u32, height: u32) -> Result<[u8; 64 * 64 * 3], ParseError> {
    let mut scaled = [0u8; 64 * 64 * 3];
    let width = usize::try_from(width)
        .map_err(|_| ParseError::Malformed("VIDEO_DIMENSION_LIMIT".to_owned()))?;
    let height = usize::try_from(height)
        .map_err(|_| ParseError::Malformed("VIDEO_DIMENSION_LIMIT".to_owned()))?;
    for y in 0..64usize {
        let y_num = y
            .saturating_mul(height.saturating_sub(1))
            .saturating_mul(65_536)
            / 63;
        let y0 = (y_num / 65_536).min(height.saturating_sub(1));
        let y1 = (y0 + 1).min(height.saturating_sub(1));
        let yf = y_num % 65_536;
        for x in 0..64usize {
            let x_num = x
                .saturating_mul(width.saturating_sub(1))
                .saturating_mul(65_536)
                / 63;
            let x0 = (x_num / 65_536).min(width.saturating_sub(1));
            let x1 = (x0 + 1).min(width.saturating_sub(1));
            let xf = x_num % 65_536;
            for channel in 0..3usize {
                let top_left = u64::from(frame[(y0 * width + x0) * 3 + channel]);
                let top_right = u64::from(frame[(y0 * width + x1) * 3 + channel]);
                let bottom_left = u64::from(frame[(y1 * width + x0) * 3 + channel]);
                let bottom_right = u64::from(frame[(y1 * width + x1) * 3 + channel]);
                let xf = u64::try_from(xf)
                    .map_err(|_| ParseError::Malformed("VIDEO_DIMENSION_LIMIT".to_owned()))?;
                let yf = u64::try_from(yf)
                    .map_err(|_| ParseError::Malformed("VIDEO_DIMENSION_LIMIT".to_owned()))?;
                let top = top_left.saturating_mul(65_536 - xf) + top_right.saturating_mul(xf);
                let bottom =
                    bottom_left.saturating_mul(65_536 - xf) + bottom_right.saturating_mul(xf);
                let value = top.saturating_mul(65_536 - yf) + bottom.saturating_mul(yf);
                scaled[(y * 64 + x) * 3 + channel] =
                    u8::try_from(value / (65_536 * 65_536)).map_or(255, |value| value);
            }
        }
    }
    Ok(scaled)
}

fn difference_score(previous: &[u8; 64 * 64 * 3], current: &[u8; 64 * 64 * 3]) -> u32 {
    let total = previous
        .iter()
        .zip(current.iter())
        .map(|(left, right)| u64::from(left.abs_diff(*right)))
        .sum::<u64>();
    u32::try_from(total.saturating_mul(10_000) / (64 * 64 * 3 * 255)).unwrap_or(u32::MAX)
}

pub(super) fn frame_slice(bytes: &[u8], width: u32, height: u32, index: usize) -> Option<&[u8]> {
    let size = usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?
        .checked_mul(3)?;
    bytes.get(index.checked_mul(size)?..index.checked_add(1)?.checked_mul(size)?)
}

pub(super) struct Shot {
    pub(super) start: u64,
    pub(super) end: u64,
    pub(super) representative: usize,
    pub(super) frame_count: u64,
}

#[derive(Clone, Copy)]
pub(super) struct FrameTiming {
    pub(super) timestamp: u64,
    pub(super) end: u64,
}

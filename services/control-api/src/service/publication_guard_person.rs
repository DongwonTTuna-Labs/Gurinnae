use gurine_publication_policy::natural_person::PublicTextNode;

use super::*;

pub(super) fn public_text_leaf<'a>(
    root: &'a PublicTextNode<'a>,
    pointer: &str,
) -> Result<&'a str, ServiceError> {
    let mut node = root;
    for encoded in pointer
        .strip_prefix('/')
        .ok_or(ServiceError::Persistence)?
        .split('/')
    {
        let segment = encoded.replace("~1", "/").replace("~0", "~");
        node = match node {
            PublicTextNode::Object(fields) => fields
                .iter()
                .find_map(|(name, child)| (*name == segment).then_some(child))
                .ok_or(ServiceError::Persistence)?,
            PublicTextNode::Array(items) => items
                .get(
                    segment
                        .parse::<usize>()
                        .map_err(|_| ServiceError::Persistence)?,
                )
                .ok_or(ServiceError::Persistence)?,
            PublicTextNode::Text(_) => return Err(ServiceError::Persistence),
        };
    }
    match node {
        PublicTextNode::Text(text) => Ok(text),
        PublicTextNode::Object(_) | PublicTextNode::Array(_) => Err(ServiceError::Persistence),
    }
}

pub(super) fn utf16_slice(value: &str, start: usize, end: usize) -> Result<&str, ServiceError> {
    if start >= end {
        return Err(ServiceError::Persistence);
    }
    let mut utf16_index = 0;
    let mut start_byte = None;
    let mut end_byte = None;
    for (byte_index, character) in value.char_indices() {
        if utf16_index == start {
            start_byte = Some(byte_index);
        }
        if utf16_index == end {
            end_byte = Some(byte_index);
            break;
        }
        utf16_index += character.len_utf16();
        if (utf16_index > start && start_byte.is_none()) || utf16_index > end {
            return Err(ServiceError::Persistence);
        }
    }
    if utf16_index == start && start_byte.is_none() {
        start_byte = Some(value.len());
    }
    if utf16_index == end && end_byte.is_none() {
        end_byte = Some(value.len());
    }
    value
        .get(
            start_byte.ok_or(ServiceError::Persistence)?
                ..end_byte.ok_or(ServiceError::Persistence)?,
        )
        .ok_or(ServiceError::Persistence)
}

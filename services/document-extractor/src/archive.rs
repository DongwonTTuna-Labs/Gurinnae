use std::{
    collections::BTreeSet,
    fs::File,
    io::{Read, Seek},
    path::Path,
};

use zip::ZipArchive;

use crate::xml;

const MAX_ENTRIES: usize = 10_000;
const MAX_UNCOMPRESSED_BYTES: u64 = 536_870_912;
const MAX_COMPRESSION_RATIO: u64 = 100;

pub fn open_checked(path: &Path) -> Result<ZipArchive<File>, String> {
    let bytes = std::fs::read(path).map_err(|_| "ZIP_INVALID".to_owned())?;
    preflight_central_directory(&bytes)?;
    let file = File::open(path).map_err(|_| "ZIP_INVALID".to_owned())?;
    ZipArchive::new(file).map_err(|_| "ZIP_INVALID".to_owned())
}

pub fn read_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> Result<Vec<u8>, String> {
    let mut entry = archive
        .by_name(name)
        .map_err(|_| "ARCHIVE_ENTRY_MISSING".to_owned())?;
    let mut bytes = Vec::new();
    entry
        .read_to_end(&mut bytes)
        .map_err(|_| "ARCHIVE_READ_FAILED".to_owned())?;
    Ok(bytes)
}

pub fn reject_external_relationships<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
) -> Result<(), String> {
    let names = (0..archive.len())
        .filter_map(|index| {
            archive
                .by_index(index)
                .ok()
                .map(|entry| entry.name().to_owned())
        })
        .filter(|name| name.ends_with(".rels"))
        .collect::<Vec<_>>();
    for name in names {
        let bytes = read_entry(archive, &name)?;
        let root = xml::parse(&bytes).map_err(|code| {
            if code == "XML_DTD_OR_ENTITY" {
                code
            } else {
                "OOXML_RELATIONSHIP_INVALID".to_owned()
            }
        })?;
        if std::iter::once(&root)
            .chain(root.descendants_named("Relationship"))
            .any(|node| {
                node.attributes
                    .get("TargetMode")
                    .is_some_and(|mode| mode.eq_ignore_ascii_case("external"))
            })
        {
            return Err("OOXML_EXTERNAL_RELATIONSHIP".to_owned());
        }
    }
    Ok(())
}

fn invalid_name(name: &str) -> bool {
    name.is_empty()
        || name.starts_with('/')
        || name.as_bytes().get(1).is_some_and(|byte| *byte == b':')
        || name.split('/').any(|segment| segment == "..")
}

fn preflight_central_directory(bytes: &[u8]) -> Result<(), String> {
    let eocd = bytes
        .windows(4)
        .rposition(|window| window == b"PK\x05\x06")
        .ok_or_else(|| "ZIP_INVALID".to_owned())?;
    let entry_count = read_u16(bytes, eocd + 10)? as usize;
    if entry_count > MAX_ENTRIES {
        return Err("ZIP_TOO_MANY_ENTRIES".to_owned());
    }
    let mut position = read_u32(bytes, eocd + 16)? as usize;
    let mut names = BTreeSet::new();
    let mut total = 0_u64;
    for _ in 0..entry_count {
        if bytes.get(position..position + 4) != Some(b"PK\x01\x02") {
            return Err("ZIP_INVALID".to_owned());
        }
        let flags = read_u16(bytes, position + 8)?;
        let compressed = read_u32(bytes, position + 20)? as u64;
        let uncompressed = read_u32(bytes, position + 24)? as u64;
        let name_length = read_u16(bytes, position + 28)? as usize;
        let extra_length = read_u16(bytes, position + 30)? as usize;
        let comment_length = read_u16(bytes, position + 32)? as usize;
        let external_attributes = read_u32(bytes, position + 38)?;
        let name_start = position
            .checked_add(46)
            .ok_or_else(|| "ZIP_INVALID".to_owned())?;
        let name_end = name_start
            .checked_add(name_length)
            .ok_or_else(|| "ZIP_INVALID".to_owned())?;
        let name_bytes = bytes
            .get(name_start..name_end)
            .ok_or_else(|| "ZIP_INVALID".to_owned())?;
        let name = String::from_utf8_lossy(name_bytes).replace('\\', "/");
        if invalid_name(&name) {
            return Err("ZIP_PATH_TRAVERSAL".to_owned());
        }
        if !names.insert(name) {
            return Err("ZIP_DUPLICATE_ENTRY".to_owned());
        }
        if flags & 1 != 0 {
            return Err("ENCRYPTED_DOCUMENT".to_owned());
        }
        let unix_mode = external_attributes >> 16;
        if unix_mode & 0o170000 == 0o120000 {
            return Err("ZIP_SYMLINK_ENTRY".to_owned());
        }
        total = total.saturating_add(uncompressed);
        if total > MAX_UNCOMPRESSED_BYTES {
            return Err("ZIP_UNCOMPRESSED_SIZE_LIMIT".to_owned());
        }
        if compressed > 0 && uncompressed / compressed.max(1) > MAX_COMPRESSION_RATIO {
            return Err("ZIP_BOMB".to_owned());
        }
        position = name_end
            .checked_add(extra_length)
            .and_then(|value| value.checked_add(comment_length))
            .ok_or_else(|| "ZIP_INVALID".to_owned())?;
    }
    Ok(())
}

fn read_u16(bytes: &[u8], offset: usize) -> Result<u16, String> {
    let value = bytes
        .get(offset..offset + 2)
        .ok_or_else(|| "ZIP_INVALID".to_owned())?;
    Ok(u16::from_le_bytes([value[0], value[1]]))
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, String> {
    let value = bytes
        .get(offset..offset + 4)
        .ok_or_else(|| "ZIP_INVALID".to_owned())?;
    Ok(u32::from_le_bytes([value[0], value[1], value[2], value[3]]))
}

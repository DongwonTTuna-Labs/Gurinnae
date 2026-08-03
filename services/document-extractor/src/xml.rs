use std::collections::BTreeMap;

use quick_xml::{Reader, events::Event};

#[derive(Clone, Debug)]
pub struct XmlNode {
    pub name: String,
    pub attributes: BTreeMap<String, String>,
    pub text: String,
    pub children: Vec<XmlNode>,
}

impl XmlNode {
    pub fn descendants_named<'a>(&'a self, name: &str) -> Vec<&'a XmlNode> {
        let mut matches = Vec::new();
        self.collect_descendants(name, &mut matches);
        matches
    }

    fn collect_descendants<'a>(&'a self, name: &str, matches: &mut Vec<&'a XmlNode>) {
        for child in &self.children {
            if child.name == name {
                matches.push(child);
            }
            child.collect_descendants(name, matches);
        }
    }

    pub fn all_text(&self) -> String {
        let mut text = self.text.clone();
        for child in &self.children {
            text.push_str(&child.all_text());
        }
        text
    }
}

pub fn contains_forbidden_declaration(bytes: &[u8]) -> bool {
    let uppercase = bytes.iter().map(u8::to_ascii_uppercase).collect::<Vec<_>>();
    uppercase.windows(9).any(|window| window == b"<!DOCTYPE")
        || uppercase.windows(8).any(|window| window == b"<!ENTITY")
}

pub fn parse(bytes: &[u8]) -> Result<XmlNode, String> {
    if contains_forbidden_declaration(bytes) {
        return Err("XML_DTD_OR_ENTITY".to_owned());
    }
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(false);
    let mut stack: Vec<XmlNode> = Vec::new();
    let mut root = None;
    loop {
        match reader.read_event() {
            Ok(Event::Start(start)) => {
                if stack.len() >= 64 {
                    return Err("XML_DEPTH_LIMIT".to_owned());
                }
                stack.push(node_from_start(&reader, &start)?);
            }
            Ok(Event::Empty(start)) => {
                let node = node_from_start(&reader, &start)?;
                attach_node(&mut stack, &mut root, node)?;
            }
            Ok(Event::Text(text)) => {
                let decoded = text.decode().map_err(|_| "XML_INVALID".to_owned())?;
                if let Some(current) = stack.last_mut() {
                    current.text.push_str(&decoded);
                } else if !decoded.trim().is_empty() {
                    return Err("XML_INVALID".to_owned());
                }
            }
            Ok(Event::CData(text)) => {
                let decoded = text.decode().map_err(|_| "XML_INVALID".to_owned())?;
                if let Some(current) = stack.last_mut() {
                    current.text.push_str(&decoded);
                } else if !decoded.trim().is_empty() {
                    return Err("XML_INVALID".to_owned());
                }
            }
            Ok(Event::End(_)) => {
                let node = stack.pop().ok_or_else(|| "XML_INVALID".to_owned())?;
                attach_node(&mut stack, &mut root, node)?;
            }
            Ok(Event::DocType(_)) => return Err("XML_DTD_OR_ENTITY".to_owned()),
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(_) => return Err("XML_INVALID".to_owned()),
        }
    }
    if !stack.is_empty() {
        return Err("XML_INVALID".to_owned());
    }
    root.ok_or_else(|| "XML_INVALID".to_owned())
}

fn node_from_start(
    reader: &Reader<&[u8]>,
    start: &quick_xml::events::BytesStart<'_>,
) -> Result<XmlNode, String> {
    let name = local_name(start.name().as_ref());
    let mut attributes = BTreeMap::new();
    for attribute in start.attributes() {
        let attribute = attribute.map_err(|_| "XML_INVALID".to_owned())?;
        let key = local_name(attribute.key.as_ref());
        let value = attribute
            .decoded_and_normalized_value(quick_xml::XmlVersion::Implicit1_0, reader.decoder())
            .map_err(|_| "XML_INVALID".to_owned())?;
        attributes.insert(key, value.into_owned());
    }
    Ok(XmlNode {
        name,
        attributes,
        text: String::new(),
        children: Vec::new(),
    })
}

fn local_name(name: &[u8]) -> String {
    let decoded = String::from_utf8_lossy(name);
    match decoded.rsplit(':').next() {
        Some(local) => local.to_owned(),
        None => decoded.into_owned(),
    }
}

fn attach_node(
    stack: &mut [XmlNode],
    root: &mut Option<XmlNode>,
    node: XmlNode,
) -> Result<(), String> {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(node);
        return Ok(());
    }
    if root.replace(node).is_some() {
        return Err("XML_INVALID".to_owned());
    }
    Ok(())
}

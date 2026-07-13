use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct Problem<'a> {
    pub code: &'a str,
    pub title: &'a str,
    pub status: u16,
    pub request_id: &'a str,
}

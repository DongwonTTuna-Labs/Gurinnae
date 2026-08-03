use crate::fetch::{FetchRequest, FetchResponse};

pub trait SourceConnector: Send + Sync {
    type Error;

    fn source_id(&self) -> &'static str;
    fn fetch(&self, request: &FetchRequest) -> Result<FetchResponse, Self::Error>;
}

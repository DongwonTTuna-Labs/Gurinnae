use std::time::Duration;

use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    time::timeout,
};

#[derive(Clone)]
pub struct ClamAvScanner {
    host: String,
    port: u16,
    timeout: Duration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScanResult {
    Clean,
    Infected,
}

#[derive(Debug, Error)]
pub enum ScanError {
    #[error("ClamAV connection failed")]
    Connect,
    #[error("ClamAV stream failed")]
    Stream,
    #[error("ClamAV response is invalid")]
    InvalidResponse,
}

impl ClamAvScanner {
    pub fn new(host: String, port: u16) -> Self {
        Self {
            host,
            port,
            timeout: Duration::from_secs(30),
        }
    }

    pub async fn scan(&self, bytes: &[u8]) -> Result<ScanResult, ScanError> {
        let stream = timeout(self.timeout, TcpStream::connect((&*self.host, self.port)))
            .await
            .map_err(|_| ScanError::Connect)?
            .map_err(|_| ScanError::Connect)?;
        timeout(self.timeout, scan_stream(stream, bytes))
            .await
            .map_err(|_| ScanError::Stream)?
    }
}

async fn scan_stream(mut stream: TcpStream, bytes: &[u8]) -> Result<ScanResult, ScanError> {
    stream
        .write_all(b"zINSTREAM\0")
        .await
        .map_err(|_| ScanError::Stream)?;
    for chunk in bytes.chunks(64 * 1024) {
        let length = u32::try_from(chunk.len()).map_err(|_| ScanError::Stream)?;
        stream
            .write_all(&length.to_be_bytes())
            .await
            .map_err(|_| ScanError::Stream)?;
        stream
            .write_all(chunk)
            .await
            .map_err(|_| ScanError::Stream)?;
    }
    stream
        .write_all(&0_u32.to_be_bytes())
        .await
        .map_err(|_| ScanError::Stream)?;
    stream.flush().await.map_err(|_| ScanError::Stream)?;
    let mut response = Vec::new();
    for _ in 0..4096 {
        let byte = stream.read_u8().await.map_err(|_| ScanError::Stream)?;
        if byte == 0 {
            break;
        }
        response.push(byte);
    }
    if response.len() == 4096 {
        return Err(ScanError::InvalidResponse);
    }
    let response = std::str::from_utf8(&response).map_err(|_| ScanError::InvalidResponse)?;
    if response.contains("stream: OK") {
        Ok(ScanResult::Clean)
    } else if response.contains(" FOUND") {
        Ok(ScanResult::Infected)
    } else {
        Err(ScanError::InvalidResponse)
    }
}

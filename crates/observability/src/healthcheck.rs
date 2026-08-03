use std::{
    env,
    io::{Read, Write},
    net::{TcpStream, ToSocketAddrs},
    time::Duration,
};

use url::Url;

pub fn run_if_requested() -> Result<bool, std::io::Error> {
    let mut arguments = env::args().skip(1);
    if arguments.next().as_deref() != Some("healthcheck") {
        return Ok(false);
    }
    if arguments.next().as_deref() != Some("--url") {
        return Err(invalid("healthcheck requires --url"));
    }
    let raw_url = arguments
        .next()
        .ok_or_else(|| invalid("healthcheck URL is missing"))?;
    if arguments.next().is_some() {
        return Err(invalid("unexpected healthcheck argument"));
    }
    probe(&raw_url)?;
    Ok(true)
}

fn probe(raw_url: &str) -> Result<(), std::io::Error> {
    let url = Url::parse(raw_url).map_err(|_| invalid("healthcheck URL is invalid"))?;
    if url.scheme() != "http" || !url.username().is_empty() || url.password().is_some() {
        return Err(invalid(
            "healthcheck URL must be plain HTTP without credentials",
        ));
    }
    let host = url
        .host_str()
        .ok_or_else(|| invalid("healthcheck host is missing"))?;
    let port = url
        .port_or_known_default()
        .ok_or_else(|| invalid("healthcheck port is missing"))?;
    let address = (host, port)
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| invalid("healthcheck host did not resolve"))?;
    let timeout = Duration::from_secs(2);
    let mut stream = TcpStream::connect_timeout(&address, timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    let target = match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_owned(),
    };
    write!(
        stream,
        "GET {target} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n"
    )?;
    stream.flush()?;
    let mut response = [0_u8; 512];
    let length = stream.read(&mut response)?;
    let status_line = std::str::from_utf8(&response[..length])
        .ok()
        .and_then(|text| text.lines().next())
        .unwrap_or_default();
    if !status_line.starts_with("HTTP/1.1 200 ") && !status_line.starts_with("HTTP/1.0 200 ") {
        return Err(invalid("healthcheck endpoint is not ready"));
    }
    Ok(())
}

fn invalid(message: &'static str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidInput, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_credentials_and_tls() {
        assert!(probe("https://127.0.0.1:8080/health/live").is_err());
        assert!(probe("http://user:secret@127.0.0.1:8080/health/live").is_err());
    }
}

use std::{collections::HashMap, io, sync::Mutex};

use actix_web::{App, HttpServer, web};
use openidconnect::{JsonWebKeyId, core::CoreRsaPrivateSigningKey};

use crate::{config::Config, handlers, health};

pub struct AuthorizationRecord {
    pub redirect_uri: String,
    pub nonce: String,
    pub code_challenge: String,
    pub acr: Option<String>,
    pub expires_at: std::time::Instant,
}

pub struct AppState {
    pub config: Config,
    pub signing_key: CoreRsaPrivateSigningKey,
    pub codes: Mutex<HashMap<String, AuthorizationRecord>>,
}

pub async fn run() -> io::Result<()> {
    let config = Config::from_env().map_err(io::Error::other)?;
    let bind = config.bind.clone();
    let signing_key = CoreRsaPrivateSigningKey::from_pem(
        TEST_RSA_PRIVATE_KEY,
        Some(JsonWebKeyId::new("gurine-test-rs256-1".to_owned())),
    )
    .map_err(io::Error::other)?;
    let state = web::Data::new(AppState {
        config,
        signing_key,
        codes: Mutex::new(HashMap::new()),
    });
    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .app_data(web::PayloadConfig::new(64 * 1024))
            .route("/health/live", web::get().to(health::live))
            .route("/health/ready", web::get().to(health::ready))
            .route(
                "/.well-known/openid-configuration",
                web::get().to(handlers::discovery),
            )
            .route("/jwks", web::get().to(handlers::jwks))
            .route("/authorize", web::get().to(handlers::authorize))
            .route("/token", web::post().to(handlers::token))
    })
    .bind(bind)?
    .run()
    .await
}

const TEST_RSA_PRIVATE_KEY: &str = r#"-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAscLe15FRxYDNtwoSdpfkluo/kQ4+6NQSbNR1C5SLpmwiw0uP
q+5khI7Gx1Lx3hL4ojNev5rTcpv9hgk4A1deMnF2oVjN2vmIg+F/qO+tUuptrIfQ
oZB65vBQ5YMcFTD0C7hANDqrkDMkaPhWinB1MQ3vyNWyCmk7HLAwv5oHtBiW8upg
0zt3JVx9GyNgzGuoxcUvLWTrQr7vJkexhKkLt2A4XTmntXiAkLHRcW6WIWBXTQU+
i6W14a7pymfxcGue0qsVqYQvq0M2KXcZiGnT80tsCh6S0/3VdUVNCcbKVlIzhz1f
G1OCpYyym1vj6ddBiBX1hGta+D51s98m5/sAKwIDAQABAoIBAFYELnHQa2mvLJws
Pwfs8xuFyXGnG5DtgebwnZyXakYDIIUxDJoNNs2gCxcLj2c+9doDEo+T20qjqfeQ
gW64eafeGKH1h1M1GTZ7yRrVs6CiOKTaaX2snJQgaHzOxymH8Se0pji/xSH3ZWB3
/uRpi4PLsyKTKV55UjXNGiG05pJh3oQ7HRdknCRPnVnbWmSuacpEG53NlXEgYkN1
honxMObKsiDTEPJ8FvZ++ixtCf6F0lTiADSLla6HctzNtfj/9/0XL3joeAgyFX4n
pcuB9sx2Koydwsh2z+KMTlNc4LgESV9Rii7H5rwdWmJLS0lg3aaVyG/BseY9xMXu
HorbJGUCgYEA6ChqKxX/vGpPJHiOQCy96O5Fn90C+xUlpI2wgwMufKnhrliatjii
AwjL8tAUSZtdPuFc0cdlM52xDl7CSj8UxY8DP8z3Qa5xKcYaumli8U7Cde/StRKS
PNieN9Cn5xTRlMp9f/I4YvNeEqS1X4QUS7tgx1YTXsquKbGGvWMUQ+0CgYEAxARU
01fWM3Kn2FKP3LSMOXLsai1TdUjI0LPBnWsj5LbnTx7oUPw3zhofyN0OMBAz//u8
2xCxQ5oIFwSWrSP2qy2A0PseGz+4ey5/Kyk/qCyLlbbnp5ps2T3gKSUPDHutUpSK
e+sarwkkiMIAAB+stkgHObAnJBfVyPyFm0AJgXcCgYEA4Xku872f7LxLNR6o+Yb6
wtl3YXXjSTwWnSTHg9Z5NbZAa3W+fK+wGcZXXfHdYke0Xje+UDeaAHFs3ooFpNpz
MBRfkX1dvrrPSUUP/HASGk7l6mkLebUZtmKj9419JJ9BlYK8NKFpRiEbAnxZcvTy
SUMpETB2C6BJWlECjblGm1kCgYBr0r4ea0jGkCFH21KLYz1nNJJbbYdlEp50Pw0X
3KGn4/ylBylfsv23f6NQSFjPk3onK4CdODdqKkac8sc3gnrjempLinbrIkgGanNF
eLEtfyNhPXV8OnP5pBG0UFBQ249hx5fNxmutMOhJ2f1KFCJbOo/O6dj9/6Z3ooCT
/8u6zQKBgCj1+Trh5oTP3GDBSfjTZ34QT1QMT7uAY8sSXha9LTKDfgYwZD7/Zzc5
pq0LOlcfucjwyvzhGnGJ95gwqbVRFiw+nao3EV/Cms2hONhwOxnJx63H41Hyii08
dsXiQQgQZNRgsGUW0298LDmP/z4BoMNdzYkYrm7GVjxYoMdIkynO
-----END RSA PRIVATE KEY-----"#;

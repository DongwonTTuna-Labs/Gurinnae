//! Non-secret runtime probe used by the credential binding acceptance script.
//! It reports only the resolver result and reference digest.

use gurine_egress_gateway::credential_resolver::resolve_from_environment;
use serde_json::json;

fn main() {
    let channel = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "TELEGRAM".to_owned());
    match resolve_from_environment(&channel) {
        Ok(credential) => println!(
            "{}",
            json!({
                "status": "PASS",
                "channel": channel,
                "referenceDigest": credential.reference_digest(),
            })
        ),
        Err(error) => {
            println!(
                "{}",
                json!({
                    "status": "REJECTED",
                    "channel": channel,
                    "reasonCode": error.to_string(),
                })
            );
            std::process::exit(1);
        }
    }
}

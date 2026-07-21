//! Runtime-observable Gherkin bindings used by the authoritative acceptance runner.
//!
//! Every macro evaluates its assertion first, then appends one closed JSON event
//! per required runtime layer, and only then fires a selected mutation sentinel.
//! A failed assertion, dead branch, missing runner environment, or stale contract
//! therefore cannot produce a valid external evidence set.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::OpenOptions;
use std::io::Write as _;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};

const ASSERTION_SENTINEL_ENV: &str = "GURINE_ASSERTION_SENTINEL";
const OBSERVATION_PATH_ENV: &str = "GURINNAE_ACCEPTANCE_OBSERVATION_PATH";
const RUNTIME_LAYERS_ENV: &str = "GURINNAE_ACCEPTANCE_RUNTIME_LAYERS_JSON";
const EDGE_CONTRACTS_ENV: &str = "GURINNAE_ACCEPTANCE_EDGE_CONTRACTS_JSON";
const LAYER_PROBE_PATHS_ENV: &str = "GURINNAE_ACCEPTANCE_LAYER_PROBE_PATHS_JSON";
const RUNTIME_LAYERS: [&str; 8] = [
    "rust-1.97.0-domain-application",
    "postgresql-18.4-real-migrations",
    "docker-compose-production-topology",
    "sveltekit-ssr-browser",
    "provider-double-at-external-boundary",
    "parser-golden-bytes",
    "production-ledger-projection",
    "koneps-synthetic-source-boundary",
];

static OBSERVATION_WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Serialize)]
struct ObservationEvent<'a> {
    schema_version: u8,
    event_kind: &'static str,
    scenario_id: &'a str,
    instance_id: &'a str,
    instance_sha256: &'a str,
    clause_id: &'a str,
    clause_sha256: &'a str,
    example_id: &'a str,
    example_sha256: Option<&'a str>,
    phase: &'a str,
    observation_ordinal: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    oracle_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    oracle_sha256: Option<&'a str>,
    layer_id: &'a str,
    observation_layer_edge_id: &'a str,
    observation_layer_edge_sha256: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    oracle_layer_edge_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    oracle_layer_edge_sha256: Option<&'a str>,
    effect_binding_sha256: &'a str,
    status: &'static str,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EdgeBinding {
    observation_layer_edge_id: String,
    observation_layer_edge_sha256: String,
    oracle_layer_edge_id: Option<String>,
    oracle_layer_edge_sha256: Option<String>,
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn required_layers() -> Result<Vec<String>, String> {
    let encoded = std::env::var(RUNTIME_LAYERS_ENV)
        .map_err(|_| format!("{RUNTIME_LAYERS_ENV} is required by the authoritative runner"))?;
    let layers: Vec<String> = serde_json::from_str(&encoded)
        .map_err(|error| format!("{RUNTIME_LAYERS_ENV} is not a JSON string array: {error}"))?;
    if layers.is_empty() {
        return Err(format!("{RUNTIME_LAYERS_ENV} must not be empty"));
    }
    let allowed = RUNTIME_LAYERS.into_iter().collect::<BTreeSet<_>>();
    let actual = layers.iter().map(String::as_str).collect::<BTreeSet<_>>();
    if actual.len() != layers.len() || !actual.is_subset(&allowed) {
        return Err(format!(
            "{RUNTIME_LAYERS_ENV} contains a duplicate or unknown layer"
        ));
    }
    Ok(layers)
}

fn edge_contracts() -> Result<BTreeMap<String, BTreeMap<String, EdgeBinding>>, String> {
    let encoded = std::env::var(EDGE_CONTRACTS_ENV)
        .map_err(|_| format!("{EDGE_CONTRACTS_ENV} is required by the authoritative runner"))?;
    // The local full-workspace runtime gate can exceed the host exec argument
    // limit when it binds every generated acceptance instance.  It passes a
    // runner-owned regular file as `@/absolute/path`; the authoritative
    // acceptance runner continues to pass the sealed JSON value directly.
    let payload = if let Some(path) = encoded.strip_prefix('@') {
        let metadata = std::fs::symlink_metadata(path).map_err(|error| {
            format!("{EDGE_CONTRACTS_ENV} contract file is unavailable: {error}")
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(format!(
                "{EDGE_CONTRACTS_ENV} contract file must be a regular non-symlink file"
            ));
        }
        std::fs::read_to_string(path).map_err(|error| {
            format!("{EDGE_CONTRACTS_ENV} contract file cannot be read: {error}")
        })?
    } else {
        encoded
    };
    serde_json::from_str(&payload)
        .map_err(|error| format!("{EDGE_CONTRACTS_ENV} is not a closed edge map: {error}"))
}

#[allow(clippy::too_many_arguments)]
fn append_observations(
    scenario_id: &str,
    observation_ordinal: u32,
    instance_id: &str,
    instance_sha256: &str,
    clause_id: &str,
    clause_sha256: &str,
    example_id: &str,
    example_sha256: Option<&str>,
    phase: &str,
    oracle_id: Option<&str>,
    oracle_sha256: Option<&str>,
    effect_binding_sha256: &str,
) -> Result<(), String> {
    // Runtime probes are executed and persisted by scripts/run_acceptance.py.
    // A test process must never receive a writable probe path: accepting one
    // would let a no-op or forged test manufacture a green layer receipt.
    if let Ok(value) = std::env::var(LAYER_PROBE_PATHS_ENV)
        && value != "{}"
    {
        return Err(format!(
            "{LAYER_PROBE_PATHS_ENV} is runner-owned and must be an empty map"
        ));
    }
    let Some(path_value) = std::env::var_os(OBSERVATION_PATH_ENV) else {
        return Ok(());
    };
    if observation_ordinal == 0
        || !is_sha256(instance_sha256)
        || !is_sha256(clause_sha256)
        || example_sha256.is_some_and(|value| !is_sha256(value))
        || !is_sha256(effect_binding_sha256)
        || !matches!(phase, "GIVEN" | "WHEN" | "THEN")
        || (phase == "THEN") != oracle_id.is_some()
        || (phase == "THEN") != oracle_sha256.is_some()
        || oracle_sha256.is_some_and(|value| !is_sha256(value))
    {
        return Err("invalid acceptance observation contract or digest".to_owned());
    }
    let path = Path::new(&path_value);
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| format!("observation file must be precreated by the runner: {error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("observation path must be a precreated regular non-symlink file".to_owned());
    }
    let layers = required_layers()?;
    let edges = edge_contracts()?;
    let lock = OBSERVATION_WRITE_LOCK.get_or_init(|| Mutex::new(()));
    let _guard = lock
        .lock()
        .map_err(|_| "observation write lock is poisoned".to_owned())?;
    let mut file = OpenOptions::new()
        .append(true)
        .open(path)
        .map_err(|error| format!("cannot append acceptance observation: {error}"))?;
    append_layer_events(
        &mut file,
        &layers,
        &edges,
        scenario_id,
        observation_ordinal,
        instance_id,
        instance_sha256,
        clause_id,
        clause_sha256,
        example_id,
        example_sha256,
        phase,
        oracle_id,
        oracle_sha256,
        effect_binding_sha256,
    )?;
    file.sync_data()
        .map_err(|error| format!("cannot sync acceptance observation: {error}"))?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn append_layer_events(
    file: &mut std::fs::File,
    layers: &[String],
    edges: &BTreeMap<String, BTreeMap<String, EdgeBinding>>,
    scenario_id: &str,
    observation_ordinal: u32,
    instance_id: &str,
    instance_sha256: &str,
    clause_id: &str,
    clause_sha256: &str,
    example_id: &str,
    example_sha256: Option<&str>,
    phase: &str,
    oracle_id: Option<&str>,
    oracle_sha256: Option<&str>,
    effect_binding_sha256: &str,
) -> Result<(), String> {
    for layer_id in layers {
        let edge = edges
            .get(layer_id)
            .and_then(|rows| rows.get(instance_id))
            .ok_or_else(|| format!("missing observation edge for {layer_id}/{instance_id}"))?;
        if !is_sha256(&edge.observation_layer_edge_sha256)
            || (phase == "THEN") != edge.oracle_layer_edge_id.is_some()
            || (phase == "THEN") != edge.oracle_layer_edge_sha256.is_some()
            || edge
                .oracle_layer_edge_sha256
                .as_deref()
                .is_some_and(|value| !is_sha256(value))
        {
            return Err(format!(
                "invalid observation/oracle edge contract for {layer_id}/{instance_id}"
            ));
        }
        let event = ObservationEvent {
            schema_version: 1,
            event_kind: "ACCEPTANCE_OBSERVATION",
            scenario_id,
            instance_id,
            instance_sha256,
            clause_id,
            clause_sha256,
            example_id,
            example_sha256,
            phase,
            observation_ordinal,
            oracle_id,
            oracle_sha256,
            layer_id,
            observation_layer_edge_id: &edge.observation_layer_edge_id,
            observation_layer_edge_sha256: &edge.observation_layer_edge_sha256,
            oracle_layer_edge_id: edge.oracle_layer_edge_id.as_deref(),
            oracle_layer_edge_sha256: edge.oracle_layer_edge_sha256.as_deref(),
            effect_binding_sha256,
            status: "PASSED",
        };
        serde_json::to_writer(&mut *file, &event)
            .map_err(|error| format!("cannot serialize acceptance observation: {error}"))?;
        file.write_all(b"\n")
            .map_err(|error| format!("cannot terminate acceptance observation: {error}"))?;
    }
    Ok(())
}

#[doc(hidden)]
#[allow(clippy::too_many_arguments)]
pub fn after_observation(
    scenario_id: &str,
    observation_ordinal: u32,
    instance_id: &str,
    instance_sha256: &str,
    clause_id: &str,
    clause_sha256: &str,
    example_id: &str,
    example_sha256_or_none: &str,
    phase: &str,
    oracle_id: Option<&str>,
    oracle_sha256: Option<&str>,
    effect_binding_sha256: &str,
) {
    let example_sha256 = (example_sha256_or_none != "NONE").then_some(example_sha256_or_none);
    append_observations(
        scenario_id,
        observation_ordinal,
        instance_id,
        instance_sha256,
        clause_id,
        clause_sha256,
        example_id,
        example_sha256,
        phase,
        oracle_id,
        oracle_sha256,
        effect_binding_sha256,
    )
    .unwrap_or_else(|error| panic!("acceptance observation failed: {error}"));

    let selected = format!("{scenario_id}:{observation_ordinal}:{instance_id}:{instance_sha256}");
    if let Ok(value) = std::env::var(ASSERTION_SENTINEL_ENV)
        && value == selected
    {
        panic!("GURINE_ASSERTION_REACHED:{selected}");
    }
}

#[macro_export]
macro_rules! observed_precondition {
    ($scenario_id:literal, $ordinal:literal, $instance_id:literal, $instance_sha256:literal, $clause_id:literal, $clause_sha256:literal, $example_id:literal, $example_sha256_or_none:literal, $effect_binding_sha256:expr, $condition:expr $(,)?) => {{
        ::std::assert!($condition);
        let effect_binding_sha256 = $effect_binding_sha256;
        $crate::acceptance_observation::after_observation(
            $scenario_id,
            $ordinal,
            $instance_id,
            $instance_sha256,
            $clause_id,
            $clause_sha256,
            $example_id,
            $example_sha256_or_none,
            "GIVEN",
            None,
            None,
            ::std::convert::AsRef::<str>::as_ref(&effect_binding_sha256),
        );
    }};
}

#[macro_export]
macro_rules! observed_action {
    ($scenario_id:literal, $ordinal:literal, $instance_id:literal, $instance_sha256:literal, $clause_id:literal, $clause_sha256:literal, $example_id:literal, $example_sha256_or_none:literal, $effect_binding_sha256:expr, $condition:expr $(,)?) => {{
        ::std::assert!($condition);
        let effect_binding_sha256 = $effect_binding_sha256;
        $crate::acceptance_observation::after_observation(
            $scenario_id,
            $ordinal,
            $instance_id,
            $instance_sha256,
            $clause_id,
            $clause_sha256,
            $example_id,
            $example_sha256_or_none,
            "WHEN",
            None,
            None,
            ::std::convert::AsRef::<str>::as_ref(&effect_binding_sha256),
        );
    }};
}

#[macro_export]
macro_rules! observed_assert {
    ($scenario_id:literal, $ordinal:literal, $instance_id:literal, $instance_sha256:literal, $clause_id:literal, $clause_sha256:literal, $example_id:literal, $example_sha256_or_none:literal, $oracle_id:literal, $oracle_sha256:literal, $effect_binding_sha256:expr, $condition:expr $(,)?) => {{
        ::std::assert!($condition);
        let effect_binding_sha256 = $effect_binding_sha256;
        $crate::acceptance_observation::after_observation(
            $scenario_id,
            $ordinal,
            $instance_id,
            $instance_sha256,
            $clause_id,
            $clause_sha256,
            $example_id,
            $example_sha256_or_none,
            "THEN",
            Some($oracle_id),
            Some($oracle_sha256),
            ::std::convert::AsRef::<str>::as_ref(&effect_binding_sha256),
        );
    }};
}

#[macro_export]
macro_rules! observed_assert_eq {
    ($scenario_id:literal, $ordinal:literal, $instance_id:literal, $instance_sha256:literal, $clause_id:literal, $clause_sha256:literal, $example_id:literal, $example_sha256_or_none:literal, $oracle_id:literal, $oracle_sha256:literal, $effect_binding_sha256:expr, $left:expr, $right:expr $(,)?) => {{
        ::std::assert_eq!($left, $right);
        let effect_binding_sha256 = $effect_binding_sha256;
        $crate::acceptance_observation::after_observation(
            $scenario_id,
            $ordinal,
            $instance_id,
            $instance_sha256,
            $clause_id,
            $clause_sha256,
            $example_id,
            $example_sha256_or_none,
            "THEN",
            Some($oracle_id),
            Some($oracle_sha256),
            ::std::convert::AsRef::<str>::as_ref(&effect_binding_sha256),
        );
    }};
}

#[macro_export]
macro_rules! observed_assert_ne {
    ($scenario_id:literal, $ordinal:literal, $instance_id:literal, $instance_sha256:literal, $clause_id:literal, $clause_sha256:literal, $example_id:literal, $example_sha256_or_none:literal, $oracle_id:literal, $oracle_sha256:literal, $effect_binding_sha256:expr, $left:expr, $right:expr $(,)?) => {{
        ::std::assert_ne!($left, $right);
        let effect_binding_sha256 = $effect_binding_sha256;
        $crate::acceptance_observation::after_observation(
            $scenario_id,
            $ordinal,
            $instance_id,
            $instance_sha256,
            $clause_id,
            $clause_sha256,
            $example_id,
            $example_sha256_or_none,
            "THEN",
            Some($oracle_id),
            Some($oracle_sha256),
            ::std::convert::AsRef::<str>::as_ref(&effect_binding_sha256),
        );
    }};
}

#[macro_export]
macro_rules! observed_assert_matches {
    ($scenario_id:literal, $ordinal:literal, $instance_id:literal, $instance_sha256:literal, $clause_id:literal, $clause_sha256:literal, $example_id:literal, $example_sha256_or_none:literal, $oracle_id:literal, $oracle_sha256:literal, $effect_binding_sha256:expr, $value:expr, $pattern:pat $(if $guard:expr)? $(,)?) => {{
        ::std::assert!(::std::matches!($value, $pattern $(if $guard)?));
        let effect_binding_sha256 = $effect_binding_sha256;
        $crate::acceptance_observation::after_observation(
            $scenario_id, $ordinal, $instance_id, $instance_sha256, $clause_id,
            $clause_sha256, $example_id, $example_sha256_or_none, "THEN",
            Some($oracle_id), Some($oracle_sha256),
            ::std::convert::AsRef::<str>::as_ref(&effect_binding_sha256),
        );
    }};
}

#[cfg(test)]
mod tests {
    use super::{EDGE_CONTRACTS_ENV, OBSERVATION_PATH_ENV, RUNTIME_LAYERS_ENV};

    #[test]
    fn observed_assertions_preserve_normal_assertion_behavior() {
        crate::observed_precondition!(
            "AC-TESTKIT-001",
            1,
            "GI-TEST-001",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "GH-TEST-001",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "NONE",
            "NONE",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            true,
        );
        crate::observed_action!(
            "AC-TESTKIT-001",
            2,
            "GI-TEST-002",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "GH-TEST-002",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "NONE",
            "NONE",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            true,
        );
        crate::observed_assert_eq!(
            "AC-TESTKIT-001",
            3,
            "GI-TEST-003",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "GH-TEST-003",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "NONE",
            "NONE",
            "OR-GI-TEST-003",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            2,
            1 + 1,
        );
        crate::observed_assert_ne!(
            "AC-TESTKIT-001",
            4,
            "GI-TEST-004",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "GH-TEST-004",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "NONE",
            "NONE",
            "OR-GI-TEST-004",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            1,
            2,
        );
        crate::observed_assert_matches!(
            "AC-TESTKIT-001", 5, "GI-TEST-005",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "GH-TEST-005",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "NONE", "NONE", "OR-GI-TEST-005",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Some(1),
            Some(value) if value == 1,
        );
    }

    #[test]
    fn sentinel_probe() {
        if std::env::var_os("GURINE_SENTINEL_UNIT_PROBE").is_some() {
            crate::observed_assert!(
                "AC-TESTKIT-002",
                1,
                "GI-TEST-006",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "GH-TEST-006",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "NONE",
                "NONE",
                "OR-GI-TEST-006",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                2 + 2 == 4,
            );
        }
    }

    #[test]
    fn sentinel_is_emitted_only_after_the_assertion_passes() {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let observation_path = std::env::temp_dir().join(format!(
            "gurinnae-acceptance-observation-{}-{nonce}.jsonl",
            std::process::id()
        ));
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&observation_path)
            .expect("precreate external observation file");
        let edges = serde_json::json!({
            "rust-1.97.0-domain-application": {
                "GI-TEST-006": {
                    "observation_layer_edge_id": "OLE-GI-TEST-006-L01",
                    "observation_layer_edge_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "oracle_layer_edge_id": "RLE-OR-GI-TEST-006-L01",
                    "oracle_layer_edge_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                }
            }
        });
        let output = std::process::Command::new(
            std::env::current_exe().expect("current Rust test executable"),
        )
        .args([
            "--exact",
            "acceptance_observation::tests::sentinel_probe",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("GURINE_SENTINEL_UNIT_PROBE", "1")
        .env(OBSERVATION_PATH_ENV, &observation_path)
        .env(
            RUNTIME_LAYERS_ENV,
            r#"["rust-1.97.0-domain-application"]"#,
        )
        .env(EDGE_CONTRACTS_ENV, edges.to_string())
        .env(
            "GURINE_ASSERTION_SENTINEL",
            "AC-TESTKIT-002:1:GI-TEST-006:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        .output()
        .expect("run isolated sentinel probe");
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(
            "GURINE_ASSERTION_REACHED:AC-TESTKIT-002:1:GI-TEST-006:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ));
        let content = std::fs::read_to_string(&observation_path).expect("read emitted observation");
        std::fs::remove_file(&observation_path).expect("remove observation probe");
        let event: serde_json::Value =
            serde_json::from_str(content.trim()).expect("closed observation JSON");
        assert_eq!(event["observation_layer_edge_id"], "OLE-GI-TEST-006-L01");
        assert_eq!(event["oracle_layer_edge_id"], "RLE-OR-GI-TEST-006-L01");
    }
}

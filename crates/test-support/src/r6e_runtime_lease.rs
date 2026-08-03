use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

const SCRIPT_PATH: &str = "scripts/test-r6e-monetization-runtime.sh";
const DATABASE_NAME: &str = "gurine_r6e_monetization";
const CONTAINER_PREFIX: &str = "gurine-r6e-monetization-";
const READY_TIMEOUT: Duration = Duration::from_secs(900);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(30);
const KILL_TIMEOUT: Duration = Duration::from_secs(10);
const READY_LINE_LIMIT: usize = 4_096;
const DATABASE_ENVIRONMENTS: [&str; 6] = [
    "DATABASE_URL",
    "TEST_DATABASE_URL",
    "GURINNAE_DATABASE_URL",
    "ECONOMICS_DATABASE_URL",
    "BILLING_DATABASE_URL",
    "PROJECTOR_DATABASE_URL",
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadyResponse {
    container: String,
    database: String,
    host: String,
    port: u16,
    scenario_id: String,
    schema_version: u8,
    status: String,
}

pub(crate) struct R6eRuntimeLease {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    container: String,
    ready: Option<ReadyResponse>,
    cleanup_armed: bool,
}

impl R6eRuntimeLease {
    pub(crate) async fn open(scenario_id: &str) -> Option<Self> {
        if !scenario_is_allowed(scenario_id) {
            return None;
        }
        let root = workspace_root()?;
        let mut command = Command::new("bash");
        command
            .arg(SCRIPT_PATH)
            .arg("--lease")
            .arg(scenario_id)
            .current_dir(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for name in DATABASE_ENVIRONMENTS {
            command.env_remove(name);
        }
        let mut child = command.spawn().ok()?;
        let Some(container_hint) = child
            .id()
            .map(|identifier| format!("{CONTAINER_PREFIX}{identifier}"))
        else {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(KILL_TIMEOUT, child.wait()).await;
            return None;
        };
        let stdin = child.stdin.take();
        let Some(stdout) = child.stdout.take() else {
            force_cleanup(&mut child, &container_hint).await;
            return None;
        };
        let mut lease = Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            container: container_hint,
            ready: None,
            cleanup_armed: true,
        };
        let ready = read_ready(&mut lease.stdout, scenario_id, &lease.container).await;
        let Some(ready) = ready else {
            lease.abort().await;
            return None;
        };
        lease.ready = Some(ready);
        Some(lease)
    }

    pub(crate) fn control_database_url(&self) -> Option<String> {
        let ready = self.ready.as_ref()?;
        Some(format!(
            "postgresql://gurine_control_api@{}:{}/{}",
            ready.host, ready.port, ready.database
        ))
    }

    pub(crate) async fn close(mut self) -> bool {
        let released = release_stdin(self.stdin.take()).await;
        let mut residual = Vec::new();
        let completion = tokio::time::timeout(CLEANUP_TIMEOUT, async {
            tokio::join!(self.child.wait(), self.stdout.read_to_end(&mut residual))
        })
        .await;
        let clean = matches!(
            completion,
            Ok((Ok(status), Ok(_))) if released && status.success() && residual.is_empty()
        );
        if clean {
            self.cleanup_armed = false;
        } else if force_cleanup(&mut self.child, &self.container).await {
            self.cleanup_armed = false;
        }
        clean
    }

    async fn abort(mut self) {
        let _ = release_stdin(self.stdin.take()).await;
        let mut discarded = Vec::new();
        let _ = tokio::time::timeout(CLEANUP_TIMEOUT, async {
            tokio::join!(self.child.wait(), self.stdout.read_to_end(&mut discarded))
        })
        .await;
        if force_cleanup(&mut self.child, &self.container).await {
            self.cleanup_armed = false;
        }
    }
}

impl Drop for R6eRuntimeLease {
    fn drop(&mut self) {
        self.stdin.take();
        if !self.cleanup_armed {
            return;
        }
        let _ = self.child.start_kill();
        let _ = std::process::Command::new("docker")
            .args(["container", "rm", "--force", &self.container])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }
}

pub(crate) fn scenario_is_allowed(scenario_id: &str) -> bool {
    matches!(
        scenario_id,
        "AC-BUSINESS_MODEL-042"
            | "AC-BUSINESS_MODEL-043"
            | "AC-BUSINESS_MODEL-044"
            | "AC-BUSINESS_MODEL-045"
            | "AC-BUSINESS_MODEL-046"
            | "AC-BUSINESS_MODEL-047"
            | "AC-BUSINESS_MODEL-048"
    )
}

fn workspace_root() -> Option<PathBuf> {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()?
        .parent()
        .map(Path::to_path_buf)
}

async fn read_ready(
    stdout: &mut BufReader<ChildStdout>,
    scenario_id: &str,
    expected_container: &str,
) -> Option<ReadyResponse> {
    let mut line = Vec::new();
    let read = tokio::time::timeout(READY_TIMEOUT, stdout.read_until(b'\n', &mut line))
        .await
        .ok()?
        .ok()?;
    if read == 0
        || line.len() > READY_LINE_LIMIT
        || line.last() != Some(&b'\n')
        || !stdout.buffer().is_empty()
    {
        return None;
    }
    line.pop();
    let ready: ReadyResponse = serde_json::from_slice(&line).ok()?;
    ready_is_valid(&ready, scenario_id, expected_container).then_some(ready)
}

fn ready_is_valid(ready: &ReadyResponse, scenario_id: &str, expected_container: &str) -> bool {
    ready.schema_version == 1
        && ready.status == "READY"
        && ready.scenario_id == scenario_id
        && ready.host == "127.0.0.1"
        && ready.port > 0
        && ready.database == DATABASE_NAME
        && ready.container == expected_container
        && ready
            .container
            .strip_prefix(CONTAINER_PREFIX)
            .is_some_and(|suffix| {
                !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
            })
}

async fn release_stdin(stdin: Option<ChildStdin>) -> bool {
    let Some(mut stdin) = stdin else {
        return false;
    };
    stdin.write_all(b"\n").await.is_ok() && stdin.shutdown().await.is_ok()
}

async fn force_cleanup(child: &mut Child, container: &str) -> bool {
    let _ = child.start_kill();
    let _ = tokio::time::timeout(KILL_TIMEOUT, child.wait()).await;
    let _ = tokio::time::timeout(
        KILL_TIMEOUT,
        Command::new("docker")
            .args(["rm", "-f", container])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status(),
    )
    .await;
    container_is_absent(container).await
}

async fn container_is_absent(container: &str) -> bool {
    let output = tokio::time::timeout(
        KILL_TIMEOUT,
        Command::new("docker")
            .args(["container", "ls", "--all", "--format", "{{.Names}}"])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output(),
    )
    .await;
    let Ok(Ok(result)) = output else {
        return false;
    };
    result.status.success()
        && std::str::from_utf8(&result.stdout)
            .ok()
            .is_some_and(|names| !names.lines().any(|name| name == container))
}

#[cfg(test)]
mod tests {
    use super::{ReadyResponse, ready_is_valid, scenario_is_allowed};

    fn ready(scenario_id: &str) -> ReadyResponse {
        ReadyResponse {
            container: "gurine-r6e-monetization-123".to_owned(),
            database: "gurine_r6e_monetization".to_owned(),
            host: "127.0.0.1".to_owned(),
            port: 55_432,
            scenario_id: scenario_id.to_owned(),
            schema_version: 1,
            status: "READY".to_owned(),
        }
    }

    #[test]
    fn scenario_allowlist_is_exact() {
        assert!(scenario_is_allowed("AC-BUSINESS_MODEL-042"));
        assert!(scenario_is_allowed("AC-BUSINESS_MODEL-048"));
        assert!(!scenario_is_allowed("AC-BUSINESS_MODEL-041"));
        assert!(!scenario_is_allowed("AC-BUSINESS_MODEL-049"));
    }

    #[test]
    fn ready_identity_is_scenario_bound() {
        let expected = ready("AC-BUSINESS_MODEL-042");
        assert!(ready_is_valid(
            &expected,
            "AC-BUSINESS_MODEL-042",
            "gurine-r6e-monetization-123"
        ));
        assert!(!ready_is_valid(
            &expected,
            "AC-BUSINESS_MODEL-043",
            "gurine-r6e-monetization-123"
        ));

        let mut wrong_host = ready("AC-BUSINESS_MODEL-042");
        wrong_host.host = "localhost".to_owned();
        assert!(!ready_is_valid(
            &wrong_host,
            "AC-BUSINESS_MODEL-042",
            "gurine-r6e-monetization-123"
        ));

        let mut wrong_container = ready("AC-BUSINESS_MODEL-042");
        wrong_container.container = "gurine-r6e-monetization-current".to_owned();
        assert!(!ready_is_valid(
            &wrong_container,
            "AC-BUSINESS_MODEL-042",
            "gurine-r6e-monetization-123"
        ));
    }

    #[test]
    fn ready_json_rejects_unknown_or_out_of_range_fields() {
        let unknown = br#"{
            "container":"gurine-r6e-monetization-123",
            "database":"gurine_r6e_monetization",
            "host":"127.0.0.1",
            "port":55432,
            "scenario_id":"AC-BUSINESS_MODEL-042",
            "schema_version":1,
            "status":"READY",
            "url":"must-not-be-accepted"
        }"#;
        let invalid_port = br#"{
            "container":"gurine-r6e-monetization-123",
            "database":"gurine_r6e_monetization",
            "host":"127.0.0.1",
            "port":65536,
            "scenario_id":"AC-BUSINESS_MODEL-042",
            "schema_version":1,
            "status":"READY"
        }"#;

        assert!(serde_json::from_slice::<ReadyResponse>(unknown).is_err());
        assert!(serde_json::from_slice::<ReadyResponse>(invalid_port).is_err());
    }
}

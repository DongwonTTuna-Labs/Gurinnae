use crate::r6e_runtime_lease::scenario_is_allowed;

const DATABASE_NAME: &str = "gurine_r6e_monetization";
const ACCEPTANCE_RUN_ID_ENVIRONMENT: &str = "GURINNAE_ACCEPTANCE_RUN_ID";
const ACCEPTANCE_OBSERVATION_ENVIRONMENT: &str = "GURINNAE_ACCEPTANCE_OBSERVATION_PATH";
const ROLE_DATABASE_ENVIRONMENTS: [&str; 3] = [
    "ECONOMICS_DATABASE_URL",
    "BILLING_DATABASE_URL",
    "PROJECTOR_DATABASE_URL",
];

/// Recognize the exact environment shape emitted by the local acceptance
/// runner. This is deterministic harness provenance, not a cryptographic
/// authentication boundary against the same operating-system user.
pub(crate) fn acceptance_runner_lease_is_present(scenario_id: &str) -> bool {
    runner_lease_environment_is_valid(scenario_id, |name| {
        std::env::var(name)
            .ok()
            .filter(|value| !value.trim().is_empty())
    })
}

fn runner_lease_environment_is_valid(
    scenario_id: &str,
    mut environment: impl FnMut(&str) -> Option<String>,
) -> bool {
    if !scenario_is_allowed(scenario_id) {
        return false;
    }
    let Some(run_id) = environment(ACCEPTANCE_RUN_ID_ENVIRONMENT) else {
        return false;
    };
    if !(8..=128).contains(&run_id.len())
        || !run_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
    {
        return false;
    }
    let Some(observation_path) = environment(ACCEPTANCE_OBSERVATION_ENVIRONMENT) else {
        return false;
    };
    if !observation_path.contains(scenario_id) {
        return false;
    }
    let Some(control_url) = environment("GURINNAE_DATABASE_URL") else {
        return false;
    };
    if environment("DATABASE_URL").as_deref() != Some(control_url.as_str())
        || environment("TEST_DATABASE_URL").is_some()
    {
        return false;
    }
    let Some(endpoint) = control_url.strip_prefix("postgresql://gurine_control_api@") else {
        return false;
    };
    let Some((authority, database)) = endpoint.split_once('/') else {
        return false;
    };
    let Some(port) = authority.strip_prefix("127.0.0.1:") else {
        return false;
    };
    if database != DATABASE_NAME
        || database.contains('/')
        || port.parse::<u16>().ok().is_none_or(|value| value == 0)
    {
        return false;
    }
    ROLE_DATABASE_ENVIRONMENTS.iter().all(|name| {
        let expected_role = expected_role(scenario_id, name);
        match (expected_role, environment(name)) {
            (Some(role), Some(value)) => value == format!("postgresql://{role}@{endpoint}"),
            (None, None) => true,
            _ => false,
        }
    })
}

fn expected_role(scenario_id: &str, environment: &str) -> Option<&'static str> {
    match (scenario_id, environment) {
        ("AC-BUSINESS_MODEL-042" | "AC-BUSINESS_MODEL-043", "ECONOMICS_DATABASE_URL")
        | ("AC-BUSINESS_MODEL-046", "ECONOMICS_DATABASE_URL") => Some("gurine_economics_importer"),
        (
            "AC-BUSINESS_MODEL-044"
            | "AC-BUSINESS_MODEL-045"
            | "AC-BUSINESS_MODEL-046"
            | "AC-BUSINESS_MODEL-047"
            | "AC-BUSINESS_MODEL-048",
            "BILLING_DATABASE_URL",
        ) => Some("gurine_billing_gateway"),
        ("AC-BUSINESS_MODEL-047", "PROJECTOR_DATABASE_URL") => Some("gurine_public_projector"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::runner_lease_environment_is_valid;
    use std::collections::BTreeMap;

    #[test]
    fn runner_lease_requires_exact_context_and_role_urls() {
        let mut environment = BTreeMap::from([
            (
                "GURINNAE_ACCEPTANCE_RUN_ID",
                "r6e-acceptance-run-001".to_owned(),
            ),
            (
                "GURINNAE_ACCEPTANCE_OBSERVATION_PATH",
                "/tmp/acceptance/AC-BUSINESS_MODEL-047/observation.json".to_owned(),
            ),
            (
                "GURINNAE_DATABASE_URL",
                "postgresql://gurine_control_api@127.0.0.1:55432/gurine_r6e_monetization"
                    .to_owned(),
            ),
            (
                "DATABASE_URL",
                "postgresql://gurine_control_api@127.0.0.1:55432/gurine_r6e_monetization"
                    .to_owned(),
            ),
            (
                "BILLING_DATABASE_URL",
                "postgresql://gurine_billing_gateway@127.0.0.1:55432/gurine_r6e_monetization"
                    .to_owned(),
            ),
            (
                "PROJECTOR_DATABASE_URL",
                "postgresql://gurine_public_projector@127.0.0.1:55432/gurine_r6e_monetization"
                    .to_owned(),
            ),
        ]);
        let valid = |values: &BTreeMap<&str, String>| {
            runner_lease_environment_is_valid("AC-BUSINESS_MODEL-047", |name| {
                values.get(name).cloned()
            })
        };
        assert!(valid(&environment));

        environment.remove("PROJECTOR_DATABASE_URL");
        assert!(!valid(&environment));
        environment.insert(
            "PROJECTOR_DATABASE_URL",
            "postgresql://gurine_public_projector@127.0.0.1:55432/gurine_r6e_monetization"
                .to_owned(),
        );
        environment.insert(
            "TEST_DATABASE_URL",
            "postgresql://unexpected@127.0.0.1:55432/gurine_r6e_monetization".to_owned(),
        );
        assert!(!valid(&environment));
    }

    #[test]
    fn lone_control_url_cannot_bypass_plain_nextest_lease() {
        let environment = BTreeMap::from([(
            "GURINNAE_DATABASE_URL",
            "postgresql://gurine_control_api@127.0.0.1:55432/gurine_r6e_monetization".to_owned(),
        )]);
        assert!(!runner_lease_environment_is_valid(
            "AC-BUSINESS_MODEL-042",
            |name| environment.get(name).cloned()
        ));
    }
}

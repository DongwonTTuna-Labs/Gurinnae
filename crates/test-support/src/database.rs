use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IsolatedDatabase {
    pub name: String,
    pub application_name: String,
}

impl IsolatedDatabase {
    pub fn new(test_name: &str) -> Self {
        let safe_name = test_name
            .chars()
            .filter(|character| character.is_ascii_alphanumeric() || *character == '_')
            .take(32)
            .collect::<String>();
        let suffix = Uuid::new_v4().simple().to_string();
        Self {
            name: format!("gurine_test_{safe_name}_{}", &suffix[..12]),
            application_name: format!("gurine-test-{safe_name}"),
        }
    }
}

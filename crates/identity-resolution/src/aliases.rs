pub fn normalized_alias(value: &str) -> String {
    value
        .trim()
        .to_lowercase()
        .chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn exact_alias_match(left: &str, right: &str) -> bool {
    let left = normalized_alias(left);
    !left.is_empty() && left == normalized_alias(right)
}

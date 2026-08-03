#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RunState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    BudgetBlocked,
    PolicyBlocked,
}

pub fn transition(from: RunState, to: RunState) -> bool {
    matches!(
        (from, to),
        (
            RunState::Queued,
            RunState::Running
                | RunState::Cancelled
                | RunState::BudgetBlocked
                | RunState::PolicyBlocked
        ) | (
            RunState::Running,
            RunState::Succeeded
                | RunState::Failed
                | RunState::Cancelled
                | RunState::BudgetBlocked
                | RunState::PolicyBlocked
        )
    )
}

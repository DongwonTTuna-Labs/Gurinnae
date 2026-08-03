use std::sync::Mutex;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum BudgetError {
    #[error("agent budget is exhausted")]
    Exhausted,
    #[error("budget state is unavailable")]
    Unavailable,
}

#[derive(Debug)]
pub struct Budget {
    limit_krw: u64,
    state: Mutex<BudgetState>,
}

#[derive(Debug, Default)]
struct BudgetState {
    reserved_krw: u64,
    settled_krw: u64,
}

impl Budget {
    pub fn new(limit_krw: u64) -> Self {
        Self {
            limit_krw,
            state: Mutex::new(BudgetState::default()),
        }
    }

    pub fn reserve(&self, maximum_cost_krw: u64) -> Result<(), BudgetError> {
        let mut state = self.state.lock().map_err(|_| BudgetError::Unavailable)?;
        let committed = state.reserved_krw.saturating_add(state.settled_krw);
        if committed.saturating_add(maximum_cost_krw) > self.limit_krw {
            return Err(BudgetError::Exhausted);
        }
        state.reserved_krw = state.reserved_krw.saturating_add(maximum_cost_krw);
        Ok(())
    }

    pub fn settle(&self, maximum_cost_krw: u64, actual_cost_krw: u64) -> Result<(), BudgetError> {
        let mut state = self.state.lock().map_err(|_| BudgetError::Unavailable)?;
        if state.reserved_krw < maximum_cost_krw || actual_cost_krw > maximum_cost_krw {
            return Err(BudgetError::Unavailable);
        }
        state.reserved_krw -= maximum_cost_krw;
        state.settled_krw = state.settled_krw.saturating_add(actual_cost_krw);
        Ok(())
    }
}

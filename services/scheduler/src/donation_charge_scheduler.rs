use crate::config::DonationChargeSchedulingMode;

/// Return the closed R6e donation scheduling outcome.
///
/// The function deliberately has no database argument: the authority-named
/// enqueue routine is absent and uncallable, so disabled scheduling must not
/// probe PostgreSQL or infer any calendar or retry policy.
pub(crate) const fn schedule_due_donation_charge_jobs(mode: DonationChargeSchedulingMode) -> u64 {
    match mode {
        DonationChargeSchedulingMode::Disabled => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_disabled_mode_performs_zero_database_work() {
        assert_eq!(
            schedule_due_donation_charge_jobs(DonationChargeSchedulingMode::default()),
            0
        );
    }
}

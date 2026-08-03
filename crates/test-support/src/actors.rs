use std::collections::BTreeSet;

use gurine_application::authorization::ActorContext;
use uuid::Uuid;

pub fn actor(capabilities: &[&str], now: i64) -> ActorContext {
    ActorContext {
        user_id: Uuid::new_v4(),
        session_id: Uuid::new_v4(),
        capabilities: capabilities
            .iter()
            .map(|capability| (*capability).to_owned())
            .collect::<BTreeSet<_>>(),
        auth_time: now,
        step_up_at: None,
        roles_version: 1,
    }
}

pub fn step_up_actor(capabilities: &[&str], now: i64) -> ActorContext {
    let mut actor = actor(capabilities, now);
    actor.step_up_at = Some(now);
    actor
}

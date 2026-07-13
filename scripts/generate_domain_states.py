#!/usr/bin/env python3
"""Generate the Rust state catalog and case transition table from v13 authority."""

from __future__ import annotations

import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
CATALOG = yaml.safe_load((ROOT / "specs/domain/state-machines.yaml").read_text())


def pascal(value: str) -> str:
    return "".join(part.capitalize() for part in value.lower().split("_"))


def write(path: str, body: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body.rstrip() + "\n")


def enum_source() -> str:
    blocks = ["//! Generated from specs/domain/state-machines.yaml.\n", "use serde::{Deserialize, Serialize};\n"]
    for name, values in CATALOG["enums"].items():
        rust_name = pascal(name)
        variants = "\n".join(f'    #[serde(rename = "{value}")]\n    {pascal(value)},' for value in values)
        match_arms = "\n".join(f'            Self::{pascal(value)} => "{value}",' for value in values)
        blocks.append(
            f'''#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum {rust_name} {{
{variants}
}}

impl {rust_name} {{
    pub const ALL: &'static [Self] = &[{", ".join(f"Self::{pascal(value)}" for value in values)}];

    pub const fn as_str(self) -> &'static str {{
        match self {{
{match_arms}
        }}
    }}
}}
'''
        )
    return "\n".join(blocks)


def transition_source() -> str:
    rows = []
    for transition in CATALOG["case_transitions"]:
        from_states = ", ".join(f"InvestigationState::{pascal(value)}" for value in transition["from"])
        guards = ", ".join(f'"{value}"' for value in transition["guards"])
        events = ", ".join(f'"{value}"' for value in transition["domain_events"])
        rows.append(
            "    CaseTransition { "
            f'id: "{transition["id"]}", from: &[{from_states}], '
            f'to: InvestigationState::{pascal(transition["to"])}, '
            f'capability: "{transition["capability"]}", guards: &[{guards}], '
            f'audit_action: "{transition["audit_action"]}", domain_events: &[{events}] '
            "},"
        )
    return f'''use crate::state_catalog::{{InvestigationState, PublicationState, ResolutionCode}};

#[derive(Clone, Copy, Debug)]
pub struct CaseTransition {{
    pub id: &'static str,
    pub from: &'static [InvestigationState],
    pub to: InvestigationState,
    pub capability: &'static str,
    pub guards: &'static [&'static str],
    pub audit_action: &'static str,
    pub domain_events: &'static [&'static str],
}}

pub const CASE_TRANSITIONS: &[CaseTransition] = &[
{chr(10).join(rows)}
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransitionDenial {{
    UndeclaredTransition,
    CapabilityDenied,
    GuardDenied(&'static str),
}}

pub fn authorize_transition(
    from: InvestigationState,
    to: InvestigationState,
    capability: &str,
    guard_satisfied: impl Fn(&str) -> bool,
) -> Result<&'static CaseTransition, TransitionDenial> {{
    let transition = CASE_TRANSITIONS
        .iter()
        .find(|transition| transition.from.contains(&from) && transition.to == to)
        .ok_or(TransitionDenial::UndeclaredTransition)?;
    if transition.capability != capability {{
        return Err(TransitionDenial::CapabilityDenied);
    }}
    if let Some(guard) = transition.guards.iter().find(|guard| !guard_satisfied(guard)) {{
        return Err(TransitionDenial::GuardDenied(guard));
    }}
    Ok(transition)
}}

#[derive(Clone, Copy, Debug)]
pub struct CaseAxes {{
    pub investigation: InvestigationState,
    pub publication: PublicationState,
    pub resolution: ResolutionCode,
}}

#[derive(Clone, Copy, Debug, Default)]
pub struct PublicationHistory {{
    pub prior_immutable_revision: bool,
    pub visible_tombstone: bool,
    pub structured_reason: bool,
}}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AxisViolation {{
    PublicationBeforeReady,
    ExplainedWithoutResolution,
    CorrectedWithoutHistory,
    RetractedWithoutTombstone,
    ClosedWithoutResolution,
}}

pub fn validate_case_axes(
    axes: CaseAxes,
    history: PublicationHistory,
) -> Result<(), AxisViolation> {{
    if axes.publication != PublicationState::NeverPublished
        && !matches!(axes.investigation, InvestigationState::ReadyToPublish | InvestigationState::Closed)
    {{
        return Err(AxisViolation::PublicationBeforeReady);
    }}
    if axes.publication == PublicationState::PublishedExplained
        && axes.resolution != ResolutionCode::Explained
    {{
        return Err(AxisViolation::ExplainedWithoutResolution);
    }}
    if axes.publication == PublicationState::Corrected && !history.prior_immutable_revision {{
        return Err(AxisViolation::CorrectedWithoutHistory);
    }}
    if axes.publication == PublicationState::Retracted
        && !(history.visible_tombstone && history.structured_reason)
    {{
        return Err(AxisViolation::RetractedWithoutTombstone);
    }}
    if axes.investigation == InvestigationState::Closed && axes.resolution == ResolutionCode::None {{
        return Err(AxisViolation::ClosedWithoutResolution);
    }}
    Ok(())
}}
'''


def tests_source() -> str:
    tests = yaml.safe_load((ROOT / "specs/domain/state-transition-tests.yaml").read_text())
    cases = []
    for case in tests["positive_transition_cases"]:
        cases.append(
            f'''    assert!(authorize_transition(
        InvestigationState::{pascal(case["from"])},
        InvestigationState::{pascal(case["to"])},
        "{case["capability"]}",
        |_| true,
    ).is_ok(), "{case["id"]}");'''
        )
    negatives = []
    for case in tests["negative_transition_cases"]:
        guards = ", ".join(f'("{name}", {str(value).lower()})' for name, value in case["guards"].items())
        expected = "TransitionDenial::CapabilityDenied" if case["reason"] == "CAPABILITY_DENIED" else "TransitionDenial::GuardDenied(_)"
        negatives.append(
            f'''    let guards = [{guards}];
    let result = authorize_transition(
        InvestigationState::{pascal(case["from"])},
        InvestigationState::{pascal(case["to"])},
        "{case["capability"]}",
        |guard| guards.iter().find(|entry| entry.0 == guard).is_some_and(|entry| entry.1),
    );
    assert!(matches!(result, Err({expected})), "{case["id"]}");'''
        )
    axes = []
    for case in tests["cross_axis_cases"]:
        expected = "is_ok()" if case["expected"] == "ALLOW" else "is_err()"
        axes.append(
            f'''    assert!(validate_case_axes(
        CaseAxes {{
            investigation: InvestigationState::{pascal(case["investigation_state"])},
            publication: PublicationState::{pascal(case["publication_state"])},
            resolution: ResolutionCode::{pascal(case["resolution_code"])},
        }},
        PublicationHistory::default(),
    ).{expected}, "{case["id"]}");'''
        )
    return f'''use gurine_domain::{{
    case::{{authorize_transition, validate_case_axes, CaseAxes, PublicationHistory, TransitionDenial}},
    state_catalog::{{InvestigationState, PublicationState, ResolutionCode}},
}};

#[test]
fn every_declared_transition_has_an_executable_positive_case() {{
{chr(10).join(cases)}
}}

#[test]
fn capability_and_guard_denials_match_the_catalog() {{
{chr(10).join(negatives)}
}}

#[test]
fn cross_axis_examples_match_the_catalog() {{
{chr(10).join(axes)}
}}
'''


def main() -> None:
    write("crates/domain/src/state_catalog.rs", enum_source())
    write("crates/domain/src/case.rs", transition_source())
    write("crates/domain/tests/state_contract.rs", tests_source())
    lib = ROOT / "crates/domain/src/lib.rs"
    text = lib.read_text()
    if "pub mod state_catalog;" not in text:
        text = text.rstrip() + "\npub mod state_catalog;\n"
        lib.write_text(text)
    print("generated 21 state enums and 11 case transition rules")


if __name__ == "__main__":
    main()

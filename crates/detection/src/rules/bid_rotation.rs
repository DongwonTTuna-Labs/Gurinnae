use std::collections::{BTreeMap, BTreeSet};

use rust_decimal::Decimal;
use serde_json::{Map, Value};
use time::{Date, Month};

use crate::engine::{Evaluation, EvaluationError, blocked, finish, quantized};

const STRUCTURED_SOURCE: &str = "STRUCTURED_COMPLETE";
const CLUSTER_METRIC: &str = "LOSING_BID_RANGE_BPS";
const TIE_HANDLING: &str = "BLOCK";

struct Policy {
    minimum_notice_count: usize,
    window_days: i64,
    minimum_bidders_per_notice: usize,
    minimum_distinct_winners: usize,
    cluster_tolerance_bps: Decimal,
    currency: String,
}

struct Notice {
    id: String,
    agency_id: String,
    noticed_at: Date,
    winner_supplier_id: String,
    bids: BTreeMap<String, Decimal>,
    losing_range_bps: Decimal,
}

struct RotationMetrics {
    notice_count: usize,
    minimum_bidder_count: usize,
    distinct_winner_count: usize,
    window_span_days: i64,
    maximum_losing_bid_range_bps: Decimal,
    same_agency: bool,
    same_participant_set: bool,
    winners_rotate: bool,
    losing_prices_clustered: bool,
}

pub fn evaluate(input: &Value) -> Result<Value, EvaluationError> {
    let policy = match parse_policy(input) {
        Ok(policy) => policy,
        Err(code) => return blocked(code, input),
    };
    let source_status = input
        .pointer("/participant_source/status")
        .and_then(Value::as_str);
    if source_status.is_none() {
        return blocked("REQUIRED_FIELD_MISSING", input);
    }
    if source_status != Some(STRUCTURED_SOURCE) {
        return blocked("STRUCTURED_PARTICIPANT_SOURCE_UNAVAILABLE", input);
    }
    if input
        .get("observation_period_complete")
        .and_then(Value::as_bool)
        != Some(true)
    {
        return blocked("PERIOD_COVERAGE_INCOMPLETE", input);
    }
    let notices = match parse_notices(input, &policy) {
        Ok(notices) => notices,
        Err(code) => return blocked(code, input),
    };
    evaluate_notices(input, &policy, notices)
}

fn parse_policy(input: &Value) -> Result<Policy, &'static str> {
    let policy = input
        .get("policy")
        .and_then(Value::as_object)
        .ok_or("REQUIRED_FIELD_MISSING")?;
    let required = [
        "minimum_notice_count",
        "window_days",
        "minimum_bidders_per_notice",
        "minimum_distinct_winners",
        "cluster_metric",
        "cluster_tolerance_bps",
        "currency",
        "tie_handling",
    ];
    if required
        .iter()
        .any(|field| policy.get(*field).is_none_or(Value::is_null))
    {
        return Err("REQUIRED_FIELD_MISSING");
    }
    let minimum_notice_count = positive_usize(policy.get("minimum_notice_count"))?;
    let window_days = nonnegative_i64(policy.get("window_days"))?;
    let minimum_bidders_per_notice = positive_usize(policy.get("minimum_bidders_per_notice"))?;
    let minimum_distinct_winners = positive_usize(policy.get("minimum_distinct_winners"))?;
    let cluster_tolerance_bps = nonnegative_decimal(policy.get("cluster_tolerance_bps"))?;
    let currency = required_string(policy.get("currency"))?;
    let metric = required_string(policy.get("cluster_metric"))?;
    let tie_handling = required_string(policy.get("tie_handling"))?;
    let valid_dimensions = minimum_notice_count >= 3
        && minimum_bidders_per_notice >= 3
        && minimum_distinct_winners >= 2
        && minimum_distinct_winners <= minimum_bidders_per_notice;
    if !valid_dimensions || metric != CLUSTER_METRIC || tie_handling != TIE_HANDLING {
        return Err("INVALID_POLICY");
    }
    Ok(Policy {
        minimum_notice_count,
        window_days,
        minimum_bidders_per_notice,
        minimum_distinct_winners,
        cluster_tolerance_bps,
        currency: currency.to_owned(),
    })
}

fn parse_notices(input: &Value, policy: &Policy) -> Result<Vec<Notice>, &'static str> {
    let values = input
        .get("notices")
        .and_then(Value::as_array)
        .ok_or("REQUIRED_FIELD_MISSING")?;
    let mut notice_ids = BTreeSet::new();
    let mut notices = Vec::with_capacity(values.len());
    for value in values {
        let object = value.as_object().ok_or("REQUIRED_FIELD_MISSING")?;
        ensure_coverage(object)?;
        let id = required_string(object.get("id"))?;
        if !notice_ids.insert(id.to_owned()) {
            return Err("DUPLICATE_NOTICE_ID");
        }
        notices.push(parse_notice(object, policy, id)?);
    }
    Ok(notices)
}

fn ensure_coverage(notice: &Map<String, Value>) -> Result<(), &'static str> {
    if notice
        .get("participant_set_complete")
        .and_then(Value::as_bool)
        != Some(true)
    {
        return Err("PARTICIPANT_SET_INCOMPLETE");
    }
    if notice.get("winner_complete").and_then(Value::as_bool) != Some(true) {
        return Err("WINNER_INCOMPLETE");
    }
    if notice
        .get("price_coverage_complete")
        .and_then(Value::as_bool)
        != Some(true)
    {
        return Err("PRICE_COVERAGE_INCOMPLETE");
    }
    Ok(())
}

fn parse_notice(
    notice: &Map<String, Value>,
    policy: &Policy,
    id: &str,
) -> Result<Notice, &'static str> {
    let agency_id = required_string(notice.get("agency_id"))?;
    let noticed_at = required_string(notice.get("noticed_at"))
        .and_then(|value| parse_date(value).ok_or("PERIOD_COVERAGE_INCOMPLETE"))?;
    let winner_supplier_id = notice
        .get("winner_supplier_id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or("WINNER_INCOMPLETE")?;
    let bids = parse_bids(notice.get("participants"), policy)?;
    let winner_bid = bids
        .get(winner_supplier_id)
        .copied()
        .ok_or("WINNER_INCOMPLETE")?;
    let lowest_bid = bids
        .values()
        .copied()
        .min()
        .ok_or("PARTICIPANT_SET_INCOMPLETE")?;
    if bids
        .values()
        .filter(|amount| **amount == lowest_bid)
        .count()
        > 1
    {
        return Err("BID_TIE");
    }
    if winner_bid != lowest_bid {
        return Err("WINNER_PRICE_INCONSISTENT");
    }
    let losing_range_bps = losing_range_bps(&bids, winner_supplier_id)?;
    Ok(Notice {
        id: id.to_owned(),
        agency_id: agency_id.to_owned(),
        noticed_at,
        winner_supplier_id: winner_supplier_id.to_owned(),
        bids,
        losing_range_bps,
    })
}

fn parse_bids(
    participants: Option<&Value>,
    policy: &Policy,
) -> Result<BTreeMap<String, Decimal>, &'static str> {
    let participants = participants
        .and_then(Value::as_array)
        .ok_or("PARTICIPANT_SET_INCOMPLETE")?;
    let mut bids = BTreeMap::new();
    for participant in participants {
        let participant = participant
            .as_object()
            .ok_or("PARTICIPANT_SET_INCOMPLETE")?;
        let supplier_id = required_string(participant.get("supplier_id"))?;
        let currency = required_string(participant.get("currency"))?;
        if currency != policy.currency.as_str() {
            return Err("CURRENCY_MISMATCH");
        }
        let amount = positive_decimal(participant.get("bid_amount"))?;
        if bids.insert(supplier_id.to_owned(), amount).is_some() {
            return Err("PARTICIPANT_IDENTITY_AMBIGUOUS");
        }
    }
    Ok(bids)
}

fn losing_range_bps(
    bids: &BTreeMap<String, Decimal>,
    winner_supplier_id: &str,
) -> Result<Decimal, &'static str> {
    let losing = bids
        .iter()
        .filter(|(supplier_id, _)| supplier_id.as_str() != winner_supplier_id)
        .map(|(_, amount)| *amount)
        .collect::<Vec<_>>();
    let minimum = losing
        .iter()
        .copied()
        .min()
        .ok_or("PARTICIPANT_SET_INCOMPLETE")?;
    let maximum = losing
        .iter()
        .copied()
        .max()
        .ok_or("PARTICIPANT_SET_INCOMPLETE")?;
    Ok((maximum - minimum) / minimum * Decimal::from(10_000))
}

fn evaluate_notices(
    input: &Value,
    policy: &Policy,
    mut notices: Vec<Notice>,
) -> Result<Value, EvaluationError> {
    notices.sort_by(|left, right| {
        left.noticed_at
            .cmp(&right.noticed_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    let notice_ids = notices
        .iter()
        .map(|notice| notice.id.clone())
        .collect::<Vec<_>>();
    let metrics = rotation_metrics(&notices, policy);
    let signal = metrics.notice_count >= policy.minimum_notice_count
        && metrics.minimum_bidder_count >= policy.minimum_bidders_per_notice
        && metrics.distinct_winner_count >= policy.minimum_distinct_winners
        && metrics.same_agency
        && metrics.same_participant_set
        && metrics.winners_rotate
        && metrics.window_span_days <= policy.window_days
        && metrics.losing_prices_clustered;
    finish(
        Evaluation {
            outcome: if signal { "SIGNAL" } else { "NO_SIGNAL" },
            blockers: Vec::new(),
            metrics: metric_map(metrics, policy),
            included_ids: if signal {
                notice_ids.clone()
            } else {
                Vec::new()
            },
            excluded_ids: if signal { Vec::new() } else { notice_ids },
        },
        input,
    )
}

fn rotation_metrics(notices: &[Notice], policy: &Policy) -> RotationMetrics {
    let same_agency = notices.first().is_none_or(|first| {
        notices
            .iter()
            .all(|notice| notice.agency_id == first.agency_id)
    });
    let same_participant_set = notices.first().is_none_or(|first| {
        let first_ids = first.bids.keys().collect::<BTreeSet<_>>();
        notices
            .iter()
            .all(|notice| notice.bids.keys().collect::<BTreeSet<_>>() == first_ids)
    });
    let maximum_losing_bid_range_bps = notices
        .iter()
        .map(|notice| notice.losing_range_bps)
        .max()
        .unwrap_or(Decimal::ZERO);
    RotationMetrics {
        notice_count: notices.len(),
        minimum_bidder_count: notices
            .iter()
            .map(|notice| notice.bids.len())
            .min()
            .unwrap_or(0),
        distinct_winner_count: notices
            .iter()
            .map(|notice| notice.winner_supplier_id.as_str())
            .collect::<BTreeSet<_>>()
            .len(),
        window_span_days: match (notices.first(), notices.last()) {
            (Some(first), Some(last)) => {
                i64::from(last.noticed_at.to_julian_day() - first.noticed_at.to_julian_day())
            }
            _ => 0,
        },
        maximum_losing_bid_range_bps,
        same_agency,
        same_participant_set,
        winners_rotate: notices
            .windows(2)
            .all(|pair| pair[0].winner_supplier_id != pair[1].winner_supplier_id),
        losing_prices_clustered: maximum_losing_bid_range_bps <= policy.cluster_tolerance_bps,
    }
}

fn metric_map(values: RotationMetrics, policy: &Policy) -> Map<String, Value> {
    [
        ("notice_count", Value::from(values.notice_count as u64)),
        (
            "minimum_bidder_count",
            Value::from(values.minimum_bidder_count as u64),
        ),
        (
            "distinct_winner_count",
            Value::from(values.distinct_winner_count as u64),
        ),
        ("window_span_days", Value::from(values.window_span_days)),
        (
            "maximum_losing_bid_range_bps",
            Value::from(quantized(values.maximum_losing_bid_range_bps)),
        ),
        ("same_agency", Value::from(values.same_agency)),
        (
            "same_participant_set",
            Value::from(values.same_participant_set),
        ),
        ("winners_rotate", Value::from(values.winners_rotate)),
        (
            "losing_prices_clustered",
            Value::from(values.losing_prices_clustered),
        ),
        ("cluster_metric", Value::from(CLUSTER_METRIC)),
        ("currency", Value::from(policy.currency.clone())),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_owned(), value))
    .collect()
}

fn positive_usize(value: Option<&Value>) -> Result<usize, &'static str> {
    let value = value
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .ok_or("INVALID_POLICY")?;
    if value == 0 {
        return Err("INVALID_POLICY");
    }
    Ok(value)
}

fn nonnegative_i64(value: Option<&Value>) -> Result<i64, &'static str> {
    value
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or("INVALID_POLICY")
}

fn nonnegative_decimal(value: Option<&Value>) -> Result<Decimal, &'static str> {
    let value = value.and_then(decimal_value).ok_or("INVALID_POLICY")?;
    if value < Decimal::ZERO {
        return Err("INVALID_POLICY");
    }
    Ok(value)
}

fn positive_decimal(value: Option<&Value>) -> Result<Decimal, &'static str> {
    let value = value
        .and_then(decimal_value)
        .ok_or("PRICE_COVERAGE_INCOMPLETE")?;
    if value <= Decimal::ZERO {
        return Err("PRICE_COVERAGE_INCOMPLETE");
    }
    Ok(value)
}

fn decimal_value(value: &Value) -> Option<Decimal> {
    match value {
        Value::String(value) => value.parse().ok(),
        Value::Number(value) => value.to_string().parse().ok(),
        _ => None,
    }
}

fn required_string(value: Option<&Value>) -> Result<&str, &'static str> {
    value
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or("REQUIRED_FIELD_MISSING")
}

fn parse_date(value: &str) -> Option<Date> {
    let mut parts = value.split('-');
    let year = parts.next()?.parse().ok()?;
    let month = Month::try_from(parts.next()?.parse::<u8>().ok()?).ok()?;
    let day = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Date::from_calendar_date(year, month, day).ok()
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::evaluate;

    #[test]
    fn unavailable_structured_source_blocks_before_evaluation() {
        let input = json!({
            "policy": {
                "minimum_notice_count": 3,
                "window_days": 60,
                "minimum_bidders_per_notice": 3,
                "minimum_distinct_winners": 3,
                "cluster_metric": "LOSING_BID_RANGE_BPS",
                "cluster_tolerance_bps": 200,
                "currency": "KRW",
                "tie_handling": "BLOCK"
            },
            "participant_source": {"status": "UNAVAILABLE"}
        });
        let actual = evaluate(&input);
        let blocker = actual.as_ref().ok().and_then(|value| {
            value
                .get("blockers")
                .and_then(Value::as_array)
                .and_then(|values| values.first())
                .and_then(Value::as_str)
        });
        assert_eq!(blocker, Some("STRUCTURED_PARTICIPANT_SOURCE_UNAVAILABLE"));
    }
}

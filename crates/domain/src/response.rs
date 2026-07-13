use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::{
    error::{DomainError, validated_text},
    ids::{CaseId, ResponseRequestId, UserId},
    state_catalog::ResponseRequestStatus,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ResponseRequest {
    pub id: ResponseRequestId,
    pub case_id: CaseId,
    pub status: ResponseRequestStatus,
    pub questions: Vec<String>,
    pub due_at: OffsetDateTime,
    pub version: i64,
}

impl ResponseRequest {
    pub fn draft(
        id: ResponseRequestId,
        case_id: CaseId,
        questions: Vec<String>,
        due_at: OffsetDateTime,
        now: OffsetDateTime,
    ) -> Result<Self, DomainError> {
        if questions.is_empty() || due_at <= now {
            return Err(DomainError::InvalidTimeRange);
        }
        let questions = questions
            .into_iter()
            .map(|question| validated_text(question, 2_000))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            id,
            case_id,
            status: ResponseRequestStatus::Draft,
            questions,
            due_at,
            version: 1,
        })
    }

    pub fn send(&mut self) -> Result<(), DomainError> {
        self.transition(ResponseRequestStatus::Sent)
    }

    pub fn mark_viewed(&mut self) -> Result<(), DomainError> {
        self.transition(ResponseRequestStatus::Viewed)
    }

    pub fn mark_submitted(&mut self) -> Result<(), DomainError> {
        self.transition(ResponseRequestStatus::Submitted)
    }

    pub fn expire(&mut self, now: OffsetDateTime) -> Result<(), DomainError> {
        if now < self.due_at
            || !matches!(
                self.status,
                ResponseRequestStatus::Sent | ResponseRequestStatus::Viewed
            )
        {
            return Err(DomainError::InvalidTransition);
        }
        self.status = ResponseRequestStatus::Expired;
        self.version += 1;
        Ok(())
    }

    fn transition(&mut self, next: ResponseRequestStatus) -> Result<(), DomainError> {
        let allowed = matches!(
            (self.status, next),
            (ResponseRequestStatus::Draft, ResponseRequestStatus::Sent)
                | (ResponseRequestStatus::Sent, ResponseRequestStatus::Viewed)
                | (
                    ResponseRequestStatus::Sent | ResponseRequestStatus::Viewed,
                    ResponseRequestStatus::Submitted
                )
        );
        if !allowed {
            return Err(DomainError::InvalidTransition);
        }
        self.status = next;
        self.version += 1;
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ResponseSubmission {
    pub response_request_id: ResponseRequestId,
    pub answers_encrypted: Vec<u8>,
    pub submission_sha256: String,
    pub publication_consent: bool,
    pub submitted_by: Option<UserId>,
    pub submitted_at: OffsetDateTime,
}

impl ResponseSubmission {
    pub fn new(
        response_request_id: ResponseRequestId,
        answers_encrypted: Vec<u8>,
        submission_sha256: String,
        publication_consent: bool,
        submitted_by: Option<UserId>,
        submitted_at: OffsetDateTime,
    ) -> Result<Self, DomainError> {
        if answers_encrypted.is_empty() || !is_hash(&submission_sha256) {
            return Err(DomainError::EmptyValue);
        }
        Ok(Self {
            response_request_id,
            answers_encrypted,
            submission_sha256,
            publication_consent,
            submitted_by,
            submitted_at,
        })
    }
}

fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

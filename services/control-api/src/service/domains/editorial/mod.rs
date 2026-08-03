use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

mod corrections;
mod publication;
mod queries;
mod responses;
mod reviews;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    ApproveResponseExcerpt,
    AssignCorrection,
    AssignReview,
    CreateCorrection,
    CreateResponseRequest,
    CreateRetractionDraft,
    CreateReviewSnapshot,
    PreviewPublication,
    PublishCase,
    ResolveCorrectionRequest,
    SaveResponseRequestDraft,
    SubmitReview,
    TriageCorrection,
    UpdateCorrectionDraft,
    ReconcileCommunicationDelivery,
    CancelCommunicationDelivery,
    TransitionResponseAppeal,
    DecideResponseExtension,
    DeclareConflict,
    WithdrawConflict,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetCorrectionWorkspace,
    GetPublicationPreview,
    GetPublicationReceipt,
    GetPublishConfirmation,
    GetResponseRequestComposer,
    GetReviewReadiness,
    GetReviewSnapshot,
    ListCaseCorrections,
    ListCaseResponses,
    ListCorrectionQueue,
    ListReviewQueue,
    GetCommunicationDeliveryReceipt,
    ListResponseAppeals,
    GetResponseAppealWorkspace,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "approveResponseExcerpt",
        Handler::Command(CommandHandler::Editorial(Command::ApproveResponseExcerpt)),
    ),
    (
        "assignCorrection",
        Handler::Command(CommandHandler::Editorial(Command::AssignCorrection)),
    ),
    (
        "assignReview",
        Handler::Command(CommandHandler::Editorial(Command::AssignReview)),
    ),
    (
        "createCorrection",
        Handler::Command(CommandHandler::Editorial(Command::CreateCorrection)),
    ),
    (
        "createResponseRequest",
        Handler::Command(CommandHandler::Editorial(Command::CreateResponseRequest)),
    ),
    (
        "createRetractionDraft",
        Handler::Command(CommandHandler::Editorial(Command::CreateRetractionDraft)),
    ),
    (
        "createReviewSnapshot",
        Handler::Command(CommandHandler::Editorial(Command::CreateReviewSnapshot)),
    ),
    (
        "getCorrectionWorkspace",
        Handler::Query(QueryHandler::Editorial(Query::GetCorrectionWorkspace)),
    ),
    (
        "getPublicationPreview",
        Handler::Query(QueryHandler::Editorial(Query::GetPublicationPreview)),
    ),
    (
        "getPublicationReceipt",
        Handler::Query(QueryHandler::Editorial(Query::GetPublicationReceipt)),
    ),
    (
        "getPublishConfirmation",
        Handler::Query(QueryHandler::Editorial(Query::GetPublishConfirmation)),
    ),
    (
        "getResponseRequestComposer",
        Handler::Query(QueryHandler::Editorial(Query::GetResponseRequestComposer)),
    ),
    (
        "getReviewReadiness",
        Handler::Query(QueryHandler::Editorial(Query::GetReviewReadiness)),
    ),
    (
        "getReviewSnapshot",
        Handler::Query(QueryHandler::Editorial(Query::GetReviewSnapshot)),
    ),
    (
        "listCaseCorrections",
        Handler::Query(QueryHandler::Editorial(Query::ListCaseCorrections)),
    ),
    (
        "listCaseResponses",
        Handler::Query(QueryHandler::Editorial(Query::ListCaseResponses)),
    ),
    (
        "listCorrectionQueue",
        Handler::Query(QueryHandler::Editorial(Query::ListCorrectionQueue)),
    ),
    (
        "listReviewQueue",
        Handler::Query(QueryHandler::Editorial(Query::ListReviewQueue)),
    ),
    (
        "previewPublication",
        Handler::Command(CommandHandler::Editorial(Command::PreviewPublication)),
    ),
    (
        "publishCase",
        Handler::Command(CommandHandler::Editorial(Command::PublishCase)),
    ),
    (
        "resolveCorrectionRequest",
        Handler::Command(CommandHandler::Editorial(Command::ResolveCorrectionRequest)),
    ),
    (
        "saveResponseRequestDraft",
        Handler::Command(CommandHandler::Editorial(Command::SaveResponseRequestDraft)),
    ),
    (
        "submitReview",
        Handler::Command(CommandHandler::Editorial(Command::SubmitReview)),
    ),
    (
        "triageCorrection",
        Handler::Command(CommandHandler::Editorial(Command::TriageCorrection)),
    ),
    (
        "updateCorrectionDraft",
        Handler::Command(CommandHandler::Editorial(Command::UpdateCorrectionDraft)),
    ),
    (
        "getCommunicationDeliveryReceipt",
        Handler::Query(QueryHandler::Editorial(
            Query::GetCommunicationDeliveryReceipt,
        )),
    ),
    (
        "reconcileCommunicationDelivery",
        Handler::Command(CommandHandler::Editorial(
            Command::ReconcileCommunicationDelivery,
        )),
    ),
    (
        "cancelCommunicationDelivery",
        Handler::Command(CommandHandler::Editorial(
            Command::CancelCommunicationDelivery,
        )),
    ),
    (
        "listResponseAppeals",
        Handler::Query(QueryHandler::Editorial(Query::ListResponseAppeals)),
    ),
    (
        "getResponseAppealWorkspace",
        Handler::Query(QueryHandler::Editorial(Query::GetResponseAppealWorkspace)),
    ),
    (
        "transitionResponseAppeal",
        Handler::Command(CommandHandler::Editorial(Command::TransitionResponseAppeal)),
    ),
    (
        "decideResponseExtension",
        Handler::Command(CommandHandler::Editorial(Command::DecideResponseExtension)),
    ),
    (
        "declareConflict",
        Handler::Command(CommandHandler::Editorial(Command::DeclareConflict)),
    ),
    (
        "withdrawConflict",
        Handler::Command(CommandHandler::Editorial(Command::WithdrawConflict)),
    ),
];

pub(super) const fn command_kind(command: Command) -> CommandKind {
    match command {
        Command::ApproveResponseExcerpt
        | Command::AssignCorrection
        | Command::AssignReview
        | Command::CreateCorrection
        | Command::CreateResponseRequest
        | Command::CreateRetractionDraft
        | Command::CreateReviewSnapshot
        | Command::PreviewPublication
        | Command::PublishCase
        | Command::ResolveCorrectionRequest
        | Command::SaveResponseRequestDraft
        | Command::SubmitReview
        | Command::TriageCorrection
        | Command::UpdateCorrectionDraft => CommandKind::Base,
        Command::ReconcileCommunicationDelivery
        | Command::CancelCommunicationDelivery
        | Command::TransitionResponseAppeal
        | Command::DecideResponseExtension
        | Command::DeclareConflict
        | Command::WithdrawConflict => CommandKind::Addendum,
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "editorial commands preserve the existing transaction-bound handler contract"
)]
pub(super) async fn apply(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::AssignCorrection
        | Command::CreateCorrection
        | Command::ResolveCorrectionRequest
        | Command::TriageCorrection
        | Command::UpdateCorrectionDraft => {
            apply_correction(
                command, operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::ApproveResponseExcerpt
        | Command::AssignReview
        | Command::CreateReviewSnapshot
        | Command::SubmitReview => {
            apply_review(
                command, operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::CreateResponseRequest | Command::SaveResponseRequestDraft => {
            apply_response(
                command, operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::CreateRetractionDraft | Command::PreviewPublication | Command::PublishCase => {
            apply_publication(
                command, operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::ReconcileCommunicationDelivery
        | Command::CancelCommunicationDelivery
        | Command::TransitionResponseAppeal
        | Command::DecideResponseExtension
        | Command::DeclareConflict
        | Command::WithdrawConflict => Err(ServiceError::InvalidRequest),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "editorial correction dispatch preserves the existing handler contract"
)]
async fn apply_correction(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::AssignCorrection => {
            corrections::arm_assigncorrection(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::CreateCorrection => {
            corrections::arm_createcorrection(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::ResolveCorrectionRequest => {
            corrections::arm_resolvecorrectionrequest(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::TriageCorrection => {
            corrections::arm_triagecorrection(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::UpdateCorrectionDraft => {
            corrections::arm_updatecorrectiondraft(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        _ => Err(ServiceError::InvalidRequest),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "editorial review dispatch preserves the existing handler contract"
)]
async fn apply_review(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::ApproveResponseExcerpt => {
            reviews::arm_approveresponseexcerpt(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::AssignReview => {
            reviews::arm_assignreview(operation, payload, id, actor, session_id, field_keys, tx)
                .await
        }
        Command::CreateReviewSnapshot => {
            reviews::arm_createreviewsnapshot(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::SubmitReview => {
            reviews::arm_submitreview(operation, payload, id, actor, session_id, field_keys, tx)
                .await
        }
        _ => Err(ServiceError::InvalidRequest),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "editorial response dispatch preserves the existing handler contract"
)]
async fn apply_response(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::CreateResponseRequest => {
            responses::arm_createresponserequest(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::SaveResponseRequestDraft => {
            responses::arm_saveresponserequestdraft(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        _ => Err(ServiceError::InvalidRequest),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "editorial publication dispatch preserves the existing handler contract"
)]
async fn apply_publication(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    field_keys: &EnvelopeKeyRing,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::CreateRetractionDraft => {
            publication::arm_createretractiondraft(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::PreviewPublication => {
            publication::arm_previewpublication(
                operation, payload, id, actor, session_id, field_keys, tx,
            )
            .await
        }
        Command::PublishCase => {
            publication::arm_publishcase(operation, payload, id, actor, session_id, field_keys, tx)
                .await
        }
        _ => Err(ServiceError::InvalidRequest),
    }
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetCorrectionWorkspace => {
            queries::query_correction_workspace(parameters, pool).await
        }
        Query::GetPublicationPreview => queries::get_publication_preview(parameters, pool).await,
        Query::GetPublicationReceipt => queries::get_publication_receipt(parameters, pool).await,
        Query::GetPublishConfirmation => queries::get_publish_confirmation(parameters, pool).await,
        Query::GetResponseRequestComposer => {
            queries::query_response_request_composer(parameters, pool).await
        }
        Query::GetReviewReadiness => queries::query_review_readiness(parameters, pool).await,
        Query::GetReviewSnapshot => queries::get_review_snapshot(parameters, pool).await,
        Query::ListCaseCorrections => queries::list_case_corrections(parameters, pool).await,
        Query::ListCaseResponses => queries::list_case_responses(parameters, pool).await,
        Query::ListCorrectionQueue => queries::list_correction_queue(parameters, pool).await,
        Query::ListReviewQueue => queries::list_review_queue(parameters, pool).await,
        Query::GetCommunicationDeliveryReceipt => {
            queries::get_communication_delivery_receipt(parameters, pool).await
        }
        Query::ListResponseAppeals => queries::list_response_appeals(pool).await,
        Query::GetResponseAppealWorkspace => {
            queries::get_response_appeal_workspace(parameters, pool).await
        }
    }
}

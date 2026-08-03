use gurine_application::privacy::{
    CreatePrivacyRequest, EncryptedPrivacyScope, EncryptedPrivacyStatement,
    ExchangePrivacyReceiptToken, GetPrivacyRequest, PrivacyCommandError, PrivacyRequestUseCase,
    PrivacyUseCaseError,
};
use gurine_auth::assertion::canonical::{canonical_json, sha256_hex};
use gurine_domain::privacy::PrivacyDigest;
use gurine_persistence_postgres::{
    privacy::{PostgresPrivacyRequestRepository, PrivacyRepositoryError},
    transaction::{IsolationLevel, set_isolation},
};
use serde_json::Value;
use uuid::Uuid;
use zeroize::Zeroize;

use super::{RequestContext, ServiceError, common, privacy_crypto, privacy_dto, privacy_render};

const PRIVACY_SCOPE_LOGICAL_TYPE: &str = "privacy-request-scope";
const PRIVACY_STATEMENT_LOGICAL_TYPE: &str = "privacy-request-statement";

pub(super) async fn execute(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    match context.operation {
        "createPrivacyRequest" => create(context).await,
        "exchangePrivacyRequestReceiptToken" => exchange(context).await,
        "getPrivacyRequest" => get(context).await,
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn create(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let mut body = privacy_dto::CreatePrivacyRequestBody::parse(context.body)?;
    let mut abuse_proof = match body.abuse_proof_value() {
        Ok(value) => value,
        Err(error) => {
            body.zeroize_sensitive();
            return Err(error);
        }
    };
    let abuse_result =
        common::require_abuse_proof_v1(context, &abuse_proof, "createPrivacyRequest").await;
    if let Some(Value::String(token)) = abuse_proof.get_mut("token") {
        token.zeroize();
    }
    if let Err(error) = abuse_result {
        body.zeroize_sensitive();
        return Err(error);
    }
    let (command, receipt) = prepare_create_command(context, body)?;
    let created = persist_create(context, command).await?;
    privacy_render::created(&created, receipt.token())
}

fn prepare_create_command(
    context: &RequestContext<'_>,
    mut body: privacy_dto::CreatePrivacyRequestBody,
) -> Result<(CreatePrivacyRequest, privacy_dto::PrivacyReceiptMaterial), ServiceError> {
    let result = (|| {
        let idempotency_key_sha256 = request_digest(context.idempotency_key_hash)?;
        let request_sha256 = request_digest(context.request_hash)?;
        let transport_request_id = transport_request_id(context.request_id)?;
        let privacy_request_id = Uuid::new_v4();
        let communication_subject_id = Uuid::new_v4();
        let communication_endpoint_id = Uuid::new_v4();
        let encrypted_scope = encrypt_scope(context, privacy_request_id, &body.scope)?;
        let encrypted_statement =
            encrypt_statement(context, privacy_request_id, &mut body.statement)?;
        let identity_proof = body
            .subject_identity_proof
            .derive_claim(&context.state.token_hmac_key)?;
        let contact = body
            .contact_endpoint
            .encrypt(context, communication_endpoint_id)?;
        let receipt = privacy_dto::PrivacyReceiptMaterial::derive(
            &context.state.token_hmac_key,
            idempotency_key_sha256.as_str(),
            request_sha256.as_str(),
        )?;
        Ok((
            CreatePrivacyRequest {
                privacy_request_id,
                communication_subject_id,
                communication_subject_hmac_key_version: receipt.key_version().to_owned(),
                request_type: body.request_type,
                identity_proof,
                jurisdiction: body.jurisdiction.clone(),
                scope: body.scope.clone(),
                encrypted_scope,
                contact,
                encrypted_statement,
                receipt_token_hmac: receipt.token_hmac().clone(),
                receipt_token_sha256: receipt.token_sha256().clone(),
                receipt_token_key_version: receipt.key_version().to_owned(),
                idempotency_key_sha256,
                request_sha256,
                bff_issuer: context.issuer.to_owned(),
                transport_request_id,
            },
            receipt,
        ))
    })();
    if result.is_err() {
        body.zeroize_sensitive();
    }
    result
}

async fn persist_create(
    context: &RequestContext<'_>,
    command: CreatePrivacyRequest,
) -> Result<gurine_application::privacy::CreatedPrivacyRequest, ServiceError> {
    let mut transaction = context
        .state
        .pool
        .begin()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    set_isolation(&mut transaction, IsolationLevel::Serializable)
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let mut repository = PostgresPrivacyRequestRepository::new(&mut transaction);
    let created = PrivacyRequestUseCase::new(&mut repository)
        .create(command)
        .await
        .map_err(map_use_case_error)?;
    transaction
        .commit()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    Ok(created)
}

fn encrypt_scope(
    context: &RequestContext<'_>,
    privacy_request_id: Uuid,
    scope: &gurine_domain::privacy::PrivacyRequestScope,
) -> Result<EncryptedPrivacyScope, ServiceError> {
    let scope_value = serde_json::to_value(scope).map_err(|_| ServiceError::InvalidParameter)?;
    let mut canonical = canonical_json(&scope_value).map_err(|_| ServiceError::InvalidParameter)?;
    let result = (|| {
        let material = privacy_crypto::encrypt_field_material(
            context,
            "ops.privacy_requests_v2",
            "scope_ciphertext",
            privacy_request_id,
            PRIVACY_SCOPE_LOGICAL_TYPE,
            &canonical,
        )?;
        EncryptedPrivacyScope::try_new(
            material.ciphertext,
            privacy_digest(sha256_hex(&canonical))?,
            privacy_digest(material.aad_digest)?,
            material.encryption_key_id,
        )
        .map_err(map_command_error)
    })();
    canonical.zeroize();
    result
}

fn encrypt_statement(
    context: &RequestContext<'_>,
    privacy_request_id: Uuid,
    statement: &mut String,
) -> Result<EncryptedPrivacyStatement, ServiceError> {
    let result = (|| {
        let digest = privacy_digest(sha256_hex(statement.as_bytes()))?;
        let material = privacy_crypto::encrypt_field_material(
            context,
            "ops.privacy_requests_v2",
            "statement_ciphertext",
            privacy_request_id,
            PRIVACY_STATEMENT_LOGICAL_TYPE,
            statement.as_bytes(),
        )?;
        EncryptedPrivacyStatement::try_new(
            material.ciphertext,
            digest,
            privacy_digest(material.aad_digest)?,
            material.encryption_key_id,
        )
        .map_err(map_command_error)
    })();
    statement.zeroize();
    result
}

async fn exchange(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let mut token = privacy_dto::ExchangePrivacyReceiptBody::parse(context.body)?.token;
    let receipt_token_hmac =
        common::token_hmac(&context.state.token_hmac_key, &token).and_then(privacy_digest);
    token.zeroize();
    let receipt_token_hmac = receipt_token_hmac?;
    let next_submission_session_sha256 = context
        .next_session_token
        .map(|token| sha256_hex(token.as_bytes()))
        .ok_or(ServiceError::PrivacyTokenInvalid)
        .and_then(privacy_digest)?;
    let command = ExchangePrivacyReceiptToken {
        receipt_token_hmac,
        next_submission_session_sha256,
        transport_request_id: transport_request_id(context.request_id)?,
        idempotency_key_sha256: request_digest(context.idempotency_key_hash)?,
        request_sha256: request_digest(context.request_hash)?,
        bff_issuer: context.issuer.to_owned(),
    };

    let mut transaction = context
        .state
        .pool
        .begin()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    set_isolation(&mut transaction, IsolationLevel::Serializable)
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let mut repository = PostgresPrivacyRequestRepository::new(&mut transaction);
    let session = PrivacyRequestUseCase::new(&mut repository)
        .exchange(command)
        .await
        .map_err(map_use_case_error)?;
    transaction
        .commit()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    privacy_render::session(&session)
}

async fn get(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let session_token_sha256 = context
        .session_token
        .map(|token| sha256_hex(token.as_bytes()))
        .ok_or(ServiceError::ScopedSessionRequired)
        .and_then(privacy_digest)?;
    let command = GetPrivacyRequest {
        session_token_sha256,
        bff_issuer: context.issuer.to_owned(),
    };
    let mut connection = context
        .state
        .pool
        .acquire()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let mut repository = PostgresPrivacyRequestRepository::new(&mut connection);
    let status = PrivacyRequestUseCase::new(&mut repository)
        .get(command)
        .await
        .map_err(map_use_case_error)?;
    privacy_render::public_status(&status)
}

fn request_digest(value: Option<&str>) -> Result<PrivacyDigest, ServiceError> {
    value
        .ok_or(ServiceError::InvalidRequest)
        .and_then(privacy_digest)
}

fn privacy_digest(value: impl Into<String>) -> Result<PrivacyDigest, ServiceError> {
    PrivacyDigest::try_new(value).map_err(|_| ServiceError::InvalidRequest)
}

fn transport_request_id(value: &str) -> Result<Uuid, ServiceError> {
    Uuid::parse_str(value).map_err(|_| ServiceError::InvalidRequest)
}

fn map_command_error(error: PrivacyCommandError) -> ServiceError {
    match error {
        PrivacyCommandError::IdentityProofInvalid => ServiceError::IdentityProofInvalid,
        PrivacyCommandError::ScopeInvalid => ServiceError::PrivacyScopeInvalid,
        PrivacyCommandError::InvalidCommand => ServiceError::InvalidParameter,
        PrivacyCommandError::InvalidOwnerResult => ServiceError::Persistence,
    }
}

fn map_use_case_error(error: PrivacyUseCaseError<PrivacyRepositoryError>) -> ServiceError {
    match error {
        PrivacyUseCaseError::Command(error) => map_command_error(error),
        PrivacyUseCaseError::Repository(error) => match error {
            PrivacyRepositoryError::IdempotencyConflict => ServiceError::IdempotencyConflict,
            PrivacyRepositoryError::IdentityProofInvalid => ServiceError::IdentityProofInvalid,
            PrivacyRepositoryError::ScopeInvalid => ServiceError::PrivacyScopeInvalid,
            PrivacyRepositoryError::TokenInvalid => ServiceError::PrivacyTokenInvalid,
            PrivacyRepositoryError::TokenExpired => ServiceError::PrivacyTokenExpired,
            PrivacyRepositoryError::TokenReplayed => ServiceError::PrivacyTokenReplayed,
            PrivacyRepositoryError::ScopedSessionRequired => ServiceError::ScopedSessionRequired,
            PrivacyRepositoryError::NotFound => ServiceError::NotFound,
            PrivacyRepositoryError::InvalidOwnerResult | PrivacyRepositoryError::Unavailable(_) => {
                ServiceError::Persistence
            }
        },
    }
}

#[cfg(test)]
mod mapping_tests {
    use super::*;

    #[test]
    fn database_privacy_contract_failures_keep_their_typed_service_errors() {
        assert!(matches!(
            map_use_case_error(PrivacyUseCaseError::Repository(
                PrivacyRepositoryError::IdentityProofInvalid,
            )),
            ServiceError::IdentityProofInvalid
        ));
        assert!(matches!(
            map_use_case_error(PrivacyUseCaseError::Repository(
                PrivacyRepositoryError::ScopeInvalid,
            )),
            ServiceError::PrivacyScopeInvalid
        ));
    }
}

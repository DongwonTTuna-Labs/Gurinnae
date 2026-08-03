use gurine_auth::oidc::{ActionAuthorizationContext, OidcTransaction, TransactionKind};
use sqlx::{PgPool, Postgres, Transaction};
use time::OffsetDateTime;
use uuid::Uuid;

#[derive(Clone, Debug)]
pub struct RequestContext<'a> {
    pub ip_hash: &'a str,
    pub user_agent_hash: &'a str,
}

#[derive(Clone, Debug)]
pub struct ClaimedOidcTransaction {
    pub id: Uuid,
    pub kind: TransactionKind,
    pub nonce_hash: String,
    pub pkce_verifier_encrypted: Vec<u8>,
    pub safe_return_to: String,
    pub session_id: Option<Uuid>,
    pub action_context: Option<ActionAuthorizationContext>,
    pub action_digest: Option<String>,
    pub idempotency_key_sha256: Option<String>,
    pub issuer_url: String,
    pub redirect_uri: String,
    pub expires_at: OffsetDateTime,
}

#[derive(Clone, Debug)]
pub struct ResolvedSession {
    pub session_id: Uuid,
    pub user_id: Uuid,
    pub email: String,
    pub display_name: String,
    pub role_codes: Vec<String>,
    pub capabilities: Vec<String>,
    pub auth_time: OffsetDateTime,
    pub step_up_at: Option<OffsetDateTime>,
    pub expires_at: OffsetDateTime,
    pub csrf_rotated_at: OffsetDateTime,
    pub roles_version: i64,
}

pub struct NewSession<'a> {
    pub user_id: Uuid,
    pub session_token_hash: &'a str,
    pub csrf_token_hash: &'a str,
    pub oidc_session_id: Option<&'a str>,
    pub auth_time: OffsetDateTime,
    pub expires_at: OffsetDateTime,
    pub context: RequestContext<'a>,
}

#[derive(Clone, Debug)]
pub struct StepUpClaim {
    pub authorization_id: Uuid,
    pub issue_number: i32,
    pub remaining_issues: i32,
    pub expires_at: OffsetDateTime,
}

pub struct OidcPersistence<'a> {
    pub encrypted_pkce_verifier: &'a [u8],
    pub issuer_url: &'a str,
    pub redirect_uri: &'a str,
    pub requested_acr_values: &'a [String],
    pub max_age_seconds: Option<i32>,
    pub request_context_hash: &'a str,
}

pub async fn insert_oidc_transaction(
    pool: &PgPool,
    transaction: &OidcTransaction,
    persistence: OidcPersistence<'_>,
) -> Result<(), sqlx::Error> {
    let action_context = transaction
        .action_context
        .as_ref()
        .map(serde_json::to_value)
        .transpose()
        .map_err(json_error)?;
    sqlx::query!(
        "INSERT INTO ops.oidc_transactions( \
           id,state_hash,nonce_hash,pkce_verifier_encrypted,safe_return_to,action_digest,expires_at, \
           transaction_kind,session_id,issuer_url,redirect_uri,requested_acr_values,max_age_seconds, \
           request_context_hash,action_context,idempotency_key_sha256 \
         ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)",
        transaction.id,
        &transaction.state_hash,
        &transaction.nonce_hash,
        persistence.encrypted_pkce_verifier,
        &transaction.safe_return_to,
        transaction.action_digest.as_deref(),
        OffsetDateTime::from_unix_timestamp(transaction.expires_at).map_err(decode_error)?,
        match transaction.kind {
            TransactionKind::Login => "LOGIN",
            TransactionKind::StepUp => "STEP_UP",
        },
        transaction.session_id,
        persistence.issuer_url,
        persistence.redirect_uri,
        persistence.requested_acr_values,
        persistence.max_age_seconds,
        persistence.request_context_hash,
        action_context,
        transaction.idempotency_key_sha256.as_deref(),
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn claim_oidc_transaction(
    pool: &PgPool,
    state_hash: &str,
) -> Result<Option<ClaimedOidcTransaction>, sqlx::Error> {
    let mut transaction = pool.begin().await?;
    let row = sqlx::query!(
        "SELECT id,transaction_kind,nonce_hash,pkce_verifier_encrypted,safe_return_to,session_id, \
                action_context,action_digest,idempotency_key_sha256,issuer_url,redirect_uri,expires_at \
         FROM ops.oidc_transactions \
         WHERE state_hash=$1 AND consumed_at IS NULL AND expires_at>clock_timestamp() FOR UPDATE",
        state_hash,
    )
    .fetch_optional(&mut *transaction)
    .await?;
    let Some(row) = row else {
        transaction.rollback().await?;
        return Ok(None);
    };
    let id = row.id;
    sqlx::query!(
        "UPDATE ops.oidc_transactions SET consumed_at=clock_timestamp() \
         WHERE id=$1 AND consumed_at IS NULL",
        id,
    )
    .execute(&mut *transaction)
    .await?;
    let claimed = ClaimedOidcTransaction {
        id: row.id,
        kind: if row.transaction_kind == "LOGIN" {
            TransactionKind::Login
        } else {
            TransactionKind::StepUp
        },
        nonce_hash: row.nonce_hash,
        pkce_verifier_encrypted: row.pkce_verifier_encrypted,
        safe_return_to: row.safe_return_to,
        session_id: row.session_id,
        action_context: row
            .action_context
            .map(serde_json::from_value)
            .transpose()
            .map_err(json_error)?,
        action_digest: row.action_digest,
        idempotency_key_sha256: row.idempotency_key_sha256,
        issuer_url: required(row.issuer_url)?,
        redirect_uri: required(row.redirect_uri)?,
        expires_at: row.expires_at,
    };
    transaction.commit().await?;
    Ok(Some(claimed))
}

pub async fn active_user_by_subject(
    pool: &PgPool,
    subject: &str,
) -> Result<Option<(Uuid, String, String)>, sqlx::Error> {
    let row = sqlx::query!(
        "SELECT id,email::text,display_name FROM ops.users \
         WHERE oidc_subject=$1 AND status='ACTIVE'",
        subject,
    )
    .fetch_optional(pool)
    .await?;
    row.map(|row| Ok((row.id, required(row.email)?, row.display_name)))
        .transpose()
}

pub async fn create_session(pool: &PgPool, session: NewSession<'_>) -> Result<Uuid, sqlx::Error> {
    sqlx::query_scalar!(
        "INSERT INTO ops.sessions( \
           user_id,session_token_hash,csrf_token_hash,oidc_session_id,auth_time,expires_at,ip_hash,user_agent_hash \
         ) VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id",
        session.user_id,
        session.session_token_hash,
        session.csrf_token_hash,
        session.oidc_session_id,
        session.auth_time,
        session.expires_at,
        session.context.ip_hash,
        session.context.user_agent_hash,
    )
    .fetch_one(pool)
    .await
}

pub async fn resolve_session(
    pool: &PgPool,
    token_hash: &str,
) -> Result<Option<ResolvedSession>, sqlx::Error> {
    let row = sqlx::query!(
        "SELECT s.id AS session_id,u.id AS user_id,u.email::text,u.display_name,s.auth_time,s.step_up_at, \
                s.expires_at,s.csrf_rotated_at,u.version AS roles_version, \
                COALESCE(array_agg(DISTINCT r.code) FILTER (WHERE r.code IS NOT NULL),'{}') AS role_codes, \
                COALESCE(array_agg(DISTINCT rc.capability_code) FILTER (WHERE rc.capability_code IS NOT NULL),'{}') AS capabilities \
         FROM ops.sessions s JOIN ops.users u ON u.id=s.user_id \
         LEFT JOIN ops.user_roles ur ON ur.user_id=u.id AND ur.revoked_at IS NULL \
           AND (ur.expires_at IS NULL OR ur.expires_at>clock_timestamp()) \
         LEFT JOIN ops.roles r ON r.id=ur.role_id \
         LEFT JOIN ops.role_capabilities rc ON rc.role_id=r.id \
         WHERE s.session_token_hash=$1 AND s.revoked_at IS NULL \
           AND s.expires_at>clock_timestamp() AND u.status='ACTIVE' \
         GROUP BY s.id,u.id",
        token_hash,
    )
    .fetch_optional(pool)
    .await?;
    row.map(|row| {
        Ok(ResolvedSession {
            session_id: row.session_id,
            user_id: row.user_id,
            email: required(row.email)?,
            display_name: row.display_name,
            role_codes: required(row.role_codes)?,
            capabilities: required(row.capabilities)?,
            auth_time: row.auth_time,
            step_up_at: row.step_up_at,
            expires_at: row.expires_at,
            csrf_rotated_at: row.csrf_rotated_at,
            roles_version: row.roles_version,
        })
    })
    .transpose()
}

pub async fn session_context_matches(
    pool: &PgPool,
    token_hash: &str,
    context: &RequestContext<'_>,
) -> Result<bool, sqlx::Error> {
    required(
        sqlx::query_scalar!(
            "SELECT EXISTS(SELECT 1 FROM ops.sessions \
             WHERE session_token_hash=$1 AND ip_hash=$2 AND user_agent_hash=$3 \
               AND revoked_at IS NULL AND expires_at>clock_timestamp())",
            token_hash,
            context.ip_hash,
            context.user_agent_hash,
        )
        .fetch_one(pool)
        .await?,
    )
}

pub async fn session_csrf_matches(
    pool: &PgPool,
    token_hash: &str,
    csrf_hash: &str,
) -> Result<bool, sqlx::Error> {
    required(
        sqlx::query_scalar!(
            "SELECT EXISTS(SELECT 1 FROM ops.sessions \
             WHERE session_token_hash=$1 AND csrf_token_hash=$2 \
               AND revoked_at IS NULL AND expires_at>clock_timestamp())",
            token_hash,
            csrf_hash,
        )
        .fetch_one(pool)
        .await?,
    )
}

pub async fn revoke_session(pool: &PgPool, token_hash: &str) -> Result<bool, sqlx::Error> {
    Ok(sqlx::query!(
        "UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) \
         WHERE session_token_hash=$1 AND revoked_at IS NULL",
        token_hash,
    )
    .execute(pool)
    .await?
    .rows_affected()
        == 1)
}

pub async fn rotate_csrf(
    pool: &PgPool,
    session_token_hash: &str,
    current_csrf_hash: &str,
    new_csrf_hash: &str,
) -> Result<bool, sqlx::Error> {
    required(
        sqlx::query_scalar!(
            "SELECT ops.rotate_session_csrf($1,$2,$3)",
            session_token_hash,
            current_csrf_hash,
            new_csrf_hash,
        )
        .fetch_one(pool)
        .await?,
    )
}

pub async fn rotate_csrf_for_session(
    transaction: &mut Transaction<'_, Postgres>,
    session_token_hash: &str,
    new_csrf_hash: &str,
) -> Result<bool, sqlx::Error> {
    let current: Option<String> = sqlx::query_scalar!(
        "SELECT csrf_token_hash FROM ops.sessions WHERE session_token_hash=$1 \
         AND revoked_at IS NULL AND expires_at>clock_timestamp() FOR UPDATE",
        session_token_hash,
    )
    .fetch_optional(&mut **transaction)
    .await?;
    let Some(current) = current else {
        return Ok(false);
    };
    required(
        sqlx::query_scalar!(
            "SELECT ops.rotate_session_csrf($1,$2,$3)",
            session_token_hash,
            current,
            new_csrf_hash,
        )
        .fetch_one(&mut **transaction)
        .await?,
    )
}

pub async fn append_session_revocation_audit(
    pool: &PgPool,
    session: &ResolvedSession,
    reason: &str,
    request_id: Uuid,
) -> Result<Uuid, sqlx::Error> {
    required(
        sqlx::query_scalar!(
            "SELECT ops.append_audit_event($1,$2,$3,$4,$5,$6,$7,$8,$9::ops.audit_outcome,$10,$11,$12)",
            format!("identity.session:{}", session.session_id),
            "USER",
            session.user_id.to_string(),
            session.session_id,
            "identity.session_revoked",
            "session",
            session.session_id.to_string(),
            "identity.session",
            "SUCCESS" as _,
            reason,
            request_id,
            serde_json::json!({"source":"identity-api"}),
        )
        .fetch_one(pool)
        .await?,
    )
}

pub async fn revoke_session_with_audit(
    pool: &PgPool,
    session: &ResolvedSession,
    token_hash: &str,
    reason: &str,
    request_id: Uuid,
) -> Result<Option<Uuid>, sqlx::Error> {
    let mut transaction = pool.begin().await?;
    let revoked = sqlx::query!(
        "UPDATE ops.sessions SET revoked_at=clock_timestamp() \
         WHERE id=$1 AND session_token_hash=$2 AND revoked_at IS NULL",
        session.session_id,
        token_hash,
    )
    .execute(&mut *transaction)
    .await?
    .rows_affected();
    if revoked != 1 {
        transaction.rollback().await?;
        return Ok(None);
    }
    let audit_id = required(
        sqlx::query_scalar!(
            "SELECT ops.append_audit_event($1,$2,$3,$4,$5,$6,$7,$8,$9::ops.audit_outcome,$10,$11,$12)",
            format!("identity.session:{}", session.session_id),
            "USER",
            session.user_id.to_string(),
            session.session_id,
            "identity.session_revoked",
            "session",
            session.session_id.to_string(),
            "identity.session",
            "SUCCESS" as _,
            reason,
            request_id,
            serde_json::json!({"source":"identity-api"}),
        )
        .fetch_one(&mut *transaction)
        .await?,
    )?;
    transaction.commit().await?;
    Ok(Some(audit_id))
}

pub async fn set_step_up_time(
    transaction: &mut Transaction<'_, Postgres>,
    session_id: Uuid,
    now: OffsetDateTime,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE ops.sessions SET step_up_at=$2 \
         WHERE id=$1 AND revoked_at IS NULL AND expires_at>$2",
        session_id,
        now,
    )
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

pub async fn create_step_up_authorization(
    pool: &PgPool,
    session_id: Uuid,
    action_digest: &str,
    idempotency_key_sha256: &str,
    authorization_token_hash: &str,
    expires_at: OffsetDateTime,
) -> Result<Uuid, sqlx::Error> {
    required(
        sqlx::query_scalar!(
            "SELECT ops.create_step_up_authorization($1,$2,$3,$4,$5)",
            session_id,
            action_digest,
            idempotency_key_sha256,
            authorization_token_hash,
            expires_at,
        )
        .fetch_one(pool)
        .await?,
    )
}

pub async fn claim_step_up_authorization(
    pool: &PgPool,
    token_hash: &str,
    session_id: Uuid,
    action_digest: &str,
    idempotency_key_sha256: &str,
    now: OffsetDateTime,
) -> Result<StepUpClaim, sqlx::Error> {
    let row = sqlx::query!(
        "SELECT * FROM ops.claim_step_up_authorization($1,$2,$3,$4,$5)",
        token_hash,
        session_id,
        action_digest,
        idempotency_key_sha256,
        now,
    )
    .fetch_one(pool)
    .await?;
    Ok(StepUpClaim {
        authorization_id: required(row.authorization_id)?,
        issue_number: required(row.issue_number)?,
        remaining_issues: required(row.remaining_issues)?,
        expires_at: required(row.authorization_expires_at)?,
    })
}

pub async fn close_step_up_authorization(
    pool: &PgPool,
    token_hash: &str,
    session_id: Uuid,
    action_digest: &str,
    idempotency_key_sha256: &str,
) -> Result<bool, sqlx::Error> {
    required(
        sqlx::query_scalar!(
            "SELECT ops.close_step_up_authorization($1,$2,$3,$4)",
            token_hash,
            session_id,
            action_digest,
            idempotency_key_sha256,
        )
        .fetch_one(pool)
        .await?,
    )
}

fn required<T>(value: Option<T>) -> Result<T, sqlx::Error> {
    value.ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))
}

fn decode_error(error: time::error::ComponentRange) -> sqlx::Error {
    sqlx::Error::Decode(Box::new(error))
}

fn json_error(error: serde_json::Error) -> sqlx::Error {
    sqlx::Error::Decode(Box::new(error))
}

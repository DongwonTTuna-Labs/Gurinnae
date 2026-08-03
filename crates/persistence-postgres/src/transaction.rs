use sqlx::{Postgres, Transaction};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IsolationLevel {
    ReadCommitted,
    RepeatableRead,
    Serializable,
}

impl IsolationLevel {
    const fn statement(self) -> &'static str {
        match self {
            Self::ReadCommitted => "SET TRANSACTION ISOLATION LEVEL READ COMMITTED",
            Self::RepeatableRead => "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ",
            Self::Serializable => "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE",
        }
    }
}

pub async fn set_isolation(
    transaction: &mut Transaction<'_, Postgres>,
    level: IsolationLevel,
) -> Result<(), sqlx::Error> {
    sqlx::query(level.statement())
        .execute(&mut **transaction)
        .await?;
    Ok(())
}

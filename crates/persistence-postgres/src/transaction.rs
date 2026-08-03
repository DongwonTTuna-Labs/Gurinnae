use sqlx::{Postgres, Transaction};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IsolationLevel {
    ReadCommitted,
    RepeatableRead,
    Serializable,
}

pub async fn set_isolation(
    transaction: &mut Transaction<'_, Postgres>,
    level: IsolationLevel,
) -> Result<(), sqlx::Error> {
    match level {
        IsolationLevel::ReadCommitted => {
            sqlx::query!("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
                .execute(&mut **transaction)
                .await?;
        }
        IsolationLevel::RepeatableRead => {
            sqlx::query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
                .execute(&mut **transaction)
                .await?;
        }
        IsolationLevel::Serializable => {
            sqlx::query!("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
                .execute(&mut **transaction)
                .await?;
        }
    }
    Ok(())
}

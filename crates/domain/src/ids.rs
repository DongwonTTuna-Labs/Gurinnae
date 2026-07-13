use serde::{Deserialize, Serialize};
use uuid::Uuid;

macro_rules! domain_id {
    ($name:ident) => {
        #[derive(
            Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize,
        )]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            pub const fn new(value: Uuid) -> Self {
                Self(value)
            }

            pub fn generate() -> Self {
                Self(Uuid::new_v4())
            }

            pub const fn value(self) -> Uuid {
                self.0
            }
        }
    };
}

domain_id!(AgencyId);
domain_id!(CaseId);
domain_id!(ClaimId);
domain_id!(ContractId);
domain_id!(EvidenceId);
domain_id!(JobId);
domain_id!(PublicationId);
domain_id!(ResponseRequestId);
domain_id!(SignalId);
domain_id!(SourceDocumentId);
domain_id!(SupplierId);
domain_id!(UserId);

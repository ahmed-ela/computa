//! Shared v1 durable evidence. There is one schema and one safe persistence
//! implementation for runtime and harness; native errors are not invented
//! diagnostic records. The runtime records finite turn outcomes.
pub use computa_state::evidence::{
    FailureRecord, FailureStore as FailureEvidenceStore, SWIFT_EPOCH_UNIX,
    StoreError as EvidenceError, outcome_record,
};

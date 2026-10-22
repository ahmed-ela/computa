#![forbid(unsafe_code)]
//! Host-owned computer execution, observation lifetimes and verification.
pub mod evidence;
pub mod executor;
pub mod formatter;
mod legacy_verification;
pub mod semantic;
pub mod verification;
pub use executor::*;

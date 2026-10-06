#![forbid(unsafe_code)]
//! Rust-authored interface. Native approval authority stays outside the WebView.
pub mod activity;
pub mod markdown;
pub mod queue;
pub mod render;
#[cfg(target_arch = "wasm32")]
mod web;

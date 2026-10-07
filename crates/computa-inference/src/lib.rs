//! Offline, bounded native inference and visual grounding. No Python runtime.
pub mod generation;
pub mod grounding;
pub mod grounding_backend;
pub mod live;
pub mod metal_resources;
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
pub mod mlx;
pub mod output;
pub mod request;
pub mod server;

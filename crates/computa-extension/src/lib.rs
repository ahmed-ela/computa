//! Rust-owned Chrome extension authority, policy and provider state machines.
pub mod commands;
pub mod engine;
pub mod providers;
pub mod temporary;
pub use engine::{Effect, Engine, Event};
#[cfg(test)]
mod engine_tests;

#[cfg(target_arch = "wasm32")]
mod wasm {
    use super::*;
    use wasm_bindgen::prelude::*;
    #[wasm_bindgen]
    pub struct ExtensionEngine {
        inner: Engine,
    }
    #[wasm_bindgen]
    impl ExtensionEngine {
        #[wasm_bindgen(constructor)]
        pub fn new(
            installation_id: String,
            extension_id: String,
            epoch: String,
        ) -> ExtensionEngine {
            Self {
                inner: Engine::new(installation_id, extension_id, epoch),
            }
        }
        pub fn dispatch(&mut self, event: JsValue) -> Result<JsValue, JsValue> {
            let event: Event = serde_wasm_bindgen::from_value(event)
                .map_err(|_| JsValue::from_str("Invalid extension event"))?;
            use serde::Serialize;
            self.inner
                .dispatch(event)
                .serialize(&serde_wasm_bindgen::Serializer::json_compatible())
                .map_err(|_| JsValue::from_str("Invalid extension effect"))
        }
        pub fn permits(&self, id: f64) -> bool {
            id.is_finite()
                && id > 0.0
                && id.fract() == 0.0
                && id <= 9_007_199_254_740_991.0
                && self.inner.permits(id as u64)
        }
        pub fn accepts_popup(&self, sender: JsValue) -> bool {
            serde_wasm_bindgen::from_value(sender)
                .is_ok_and(|sender| self.inner.accepts_popup(&sender))
        }
    }
}

use crate::{output, request::ContextBudget};
#[derive(Debug, thiserror::Error)]
pub enum InferenceError {
    #[error("The selected local model is unavailable.")]
    Unavailable,
    #[error("Switching models requires restarting the owned local model server.")]
    RestartRequired,
    #[error("Local input and output allowance exceed the 16384-token context window.")]
    Context(ContextBudget),
    #[error("The local model input is unsupported.")]
    Input,
    #[error("The local model generation failed.")]
    Generation,
    #[error("Local inference was cancelled.")]
    Cancelled,
    #[error("The local model output allowance was exhausted before a clean stop.")]
    Length(Usage),
    #[error("{0}")]
    Output(#[from] output::OutputError),
}
#[derive(Clone, Debug, serde::Serialize)]
pub struct Usage {
    pub input_tokens: usize,
    pub output_tokens: usize,
    pub total_tokens: usize,
}
#[derive(Clone, Debug)]
pub struct Reply {
    pub text: String,
    pub reasoning: Option<String>,
    pub calls: Vec<output::ToolCall>,
    pub usage: Usage,
}
#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub struct Memory {
    pub active_bytes: usize,
    pub cache_bytes: usize,
    pub peak_bytes: usize,
}

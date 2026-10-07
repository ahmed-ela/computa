//! One request-local parser supplies both live deltas and final output. Tool
//! arguments stay private until the complete bundle passes offered-tool checks.
use crate::output::{self, OfferedTool, OutputError, ToolCall};
use std::collections::BTreeMap;

pub const MAX_CAPTURE: usize = 4 * 1024 * 1024;
pub(crate) const FORCED_REASONING_CLOSE: &str = "\n</think>\n\n";
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Delta {
    Text(String),
    Reasoning(String),
}
#[derive(Clone, Copy, Eq, PartialEq)]
enum Phase {
    Text,
    Reasoning,
    Tool,
}
pub struct LiveOutput {
    raw: String,
    pending: String,
    phase: Phase,
    reasoning_seen: bool,
    tools_seen: bool,
    text: String,
    reasoning: String,
    calls: String,
}
pub struct FinalOutput {
    pub text: String,
    pub reasoning: Option<String>,
    pub calls: Vec<ToolCall>,
}
impl LiveOutput {
    pub fn new(prompt_opens_reasoning: bool) -> Self {
        Self {
            raw: String::new(),
            pending: String::new(),
            phase: if prompt_opens_reasoning {
                Phase::Reasoning
            } else {
                Phase::Text
            },
            reasoning_seen: prompt_opens_reasoning,
            tools_seen: false,
            text: String::new(),
            reasoning: String::new(),
            calls: String::new(),
        }
    }
    pub fn raw(&self) -> &str {
        &self.raw
    }
    pub fn reasoning_open(&self) -> bool {
        self.phase == Phase::Reasoning
    }
    /// Retain the exact host-authored causal suffix without publishing its
    /// separators as model text. Any withheld model bytes remain reasoning.
    pub(crate) fn force_reasoning_close(&mut self) -> Result<Vec<Delta>, OutputError> {
        if self.phase != Phase::Reasoning
            || self.raw.len().saturating_add(FORCED_REASONING_CLOSE.len()) > MAX_CAPTURE
        {
            return Err(OutputError::Malformed);
        }
        self.raw.push_str(FORCED_REASONING_CLOSE);
        let mut deltas = Vec::new();
        let pending = std::mem::take(&mut self.pending);
        self.emit_reasoning(pending, &mut deltas);
        self.phase = Phase::Text;
        Ok(deltas)
    }
    pub fn feed(&mut self, piece: &str) -> Result<Vec<Delta>, OutputError> {
        if self.raw.len().saturating_add(piece.len()) > MAX_CAPTURE || piece.contains('\0') {
            return Err(OutputError::Malformed);
        }
        self.raw.push_str(piece);
        self.pending.push_str(piece);
        let mut deltas = Vec::new();
        loop {
            match self.phase {
                Phase::Reasoning => {
                    if let Some(at) = self.pending.find("</think>") {
                        let text = self.pending[..at].to_owned();
                        self.pending.drain(..at + 8);
                        self.emit_reasoning(text, &mut deltas);
                        self.phase = Phase::Text;
                        continue;
                    }
                    let end = self.pending.len() - held_prefix(&self.pending, &["</think>"]);
                    let text = self.pending[..end].to_owned();
                    self.pending.drain(..end);
                    self.emit_reasoning(text, &mut deltas);
                    break;
                }
                Phase::Tool => {
                    if let Some(at) = self.pending.find("</tool_call>") {
                        self.calls.push_str(&self.pending[..at + 12]);
                        self.pending.drain(..at + 12);
                        self.phase = Phase::Text;
                        continue;
                    }
                    // Keep the whole raw span for strict, complete-consumption
                    // validation. Its content is never a streamed tool action.
                    break;
                }
                Phase::Text => {
                    let next = [("<think>", Phase::Reasoning), ("<tool_call>", Phase::Tool)]
                        .into_iter()
                        .filter_map(|(marker, phase)| {
                            self.pending.find(marker).map(|at| (at, marker, phase))
                        })
                        .min_by_key(|v| v.0);
                    if let Some((at, marker, phase)) = next {
                        let text = self.pending[..at].to_owned();
                        self.pending.drain(..at + marker.len());
                        self.emit_text(text, &mut deltas)?;
                        if phase == Phase::Reasoning {
                            if self.reasoning_seen
                                || self.tools_seen
                                || !self.text.trim().is_empty()
                            {
                                return Err(OutputError::Malformed);
                            }
                            self.reasoning_seen = true;
                        } else {
                            self.tools_seen = true;
                            self.calls.push_str(marker);
                        }
                        self.phase = phase;
                        continue;
                    }
                    let end = self.pending.len()
                        - held_prefix(
                            &self.pending,
                            &[
                                "<think>",
                                "</think>",
                                "<tool_call>",
                                "</tool_call>",
                                "<function",
                                "</function",
                                "<parameter",
                                "</parameter",
                                "<|",
                            ],
                        );
                    let text = self.pending[..end].to_owned();
                    self.pending.drain(..end);
                    self.emit_text(text, &mut deltas)?;
                    break;
                }
            }
        }
        Ok(deltas)
    }
    fn emit_reasoning(&mut self, text: String, deltas: &mut Vec<Delta>) {
        if !text.is_empty() {
            self.reasoning.push_str(&text);
            deltas.push(Delta::Reasoning(text));
        }
    }
    fn emit_text(&mut self, text: String, deltas: &mut Vec<Delta>) -> Result<(), OutputError> {
        if text.contains("</think>")
            || text.contains("</tool_call>")
            || text.contains("<function")
            || text.contains("</function")
            || text.contains("<parameter")
            || text.contains("</parameter")
            || text.contains("<|")
        {
            return Err(OutputError::Malformed);
        }
        if self.tools_seen {
            if !text.trim().is_empty() {
                return Err(OutputError::Malformed);
            }
            return Ok(());
        }
        if !text.is_empty() {
            self.text.push_str(&text);
            deltas.push(Delta::Text(text));
        }
        Ok(())
    }
    pub fn finish(
        mut self,
        offered: &BTreeMap<String, OfferedTool>,
        clean_stop: bool,
    ) -> Result<(FinalOutput, Vec<Delta>), OutputError> {
        if !clean_stop || self.phase != Phase::Text {
            return Err(OutputError::Unfinished);
        }
        // A withheld marker prefix at EOF is incomplete, never ordinary text.
        if !self.pending.is_empty() {
            return Err(OutputError::Unfinished);
        }
        let calls = if self.calls.is_empty() {
            Vec::new()
        } else {
            output::parse_calls(&self.calls, offered, true)?
        };
        if self.text.trim().is_empty() && calls.is_empty() {
            return Err(OutputError::Malformed);
        }
        let reasoning = (!self.reasoning.is_empty()).then(|| std::mem::take(&mut self.reasoning));
        Ok((
            FinalOutput {
                text: self.text,
                reasoning,
                calls,
            },
            Vec::new(),
        ))
    }
}
fn held_prefix(text: &str, markers: &[&str]) -> usize {
    markers
        .iter()
        .flat_map(|marker| {
            (1..marker.len())
                .filter(move |&n| marker.is_char_boundary(n) && text.ends_with(&marker[..n]))
        })
        .max()
        .unwrap_or(0)
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn tools() -> BTreeMap<String, OfferedTool> {
        output::offered_tools(&json!({"tools":[{"type":"function","name":"click","parameters":{"type":"object","properties":{}}}]})).unwrap()
    }
    #[test]
    fn all_split_boundaries_preserve_reasoning_and_hide_tool_examples() {
        let raw = "private <tool_call>example</tool_call></think><tool_call>{\"name\":\"click\",\"arguments\":{}}</tool_call>";
        for split in 0..=raw.len() {
            let mut parser = LiveOutput::new(true);
            let mut deltas = parser.feed(&raw[..split]).unwrap();
            deltas.extend(parser.feed(&raw[split..]).unwrap());
            let (finalized, _) = parser.finish(&tools(), true).unwrap();
            assert_eq!(finalized.calls.len(), 1);
            assert!(finalized.text.is_empty());
            assert_eq!(
                finalized.reasoning.as_deref(),
                Some("private <tool_call>example</tool_call>")
            );
            assert!(deltas.iter().all(|d| matches!(d, Delta::Reasoning(_))));
        }
    }
    #[test]
    fn dangling_marker_or_cancelled_bundle_never_completes() {
        for raw in [
            "Hello <t",
            "<think>unfinished",
            "<tool_call>{\"name\":\"click\",\"arguments\":{}}",
        ] {
            let mut parser = LiveOutput::new(false);
            parser.feed(raw).unwrap();
            assert!(parser.finish(&tools(), true).is_err());
        }
        let mut parser = LiveOutput::new(false);
        parser
            .feed("<tool_call>{\"name\":\"click\",\"arguments\":{}}</tool_call>")
            .unwrap();
        assert!(parser.finish(&tools(), false).is_err());
    }
    #[test]
    fn public_unicode_deltas_equal_terminal_content() {
        let mut parser = LiveOutput::new(false);
        let mut public = String::new();
        for piece in ["Hello ", "🦀", " & ", "مرحبا"] {
            for delta in parser.feed(piece).unwrap() {
                if let Delta::Text(text) = delta {
                    public.push_str(&text);
                }
            }
        }
        let (reply, _) = parser.finish(&tools(), true).unwrap();
        assert_eq!(public, reply.text);
    }
    #[test]
    fn forced_close_retains_causal_bytes_but_publishes_only_model_text() {
        for text in ["EXACT", "\n\nEXACT", "  EXACT 🦀\n"] {
            let mut parser = LiveOutput::new(true);
            let mut deltas = parser.feed("private reasoning</t").unwrap();
            deltas.extend(parser.force_reasoning_close().unwrap());
            deltas.extend(parser.feed(text).unwrap());
            assert_eq!(
                parser.raw(),
                format!("private reasoning</t{FORCED_REASONING_CLOSE}{text}")
            );
            let public: String = deltas
                .iter()
                .filter_map(|d| match d {
                    Delta::Text(t) => Some(t.as_str()),
                    Delta::Reasoning(_) => None,
                })
                .collect();
            let (reply, _) = parser.finish(&BTreeMap::new(), true).unwrap();
            assert_eq!(public, text);
            assert_eq!(reply.text, text);
            assert_eq!(reply.reasoning.as_deref(), Some("private reasoning</t"));
        }
        assert!(LiveOutput::new(false).force_reasoning_close().is_err());
    }
}

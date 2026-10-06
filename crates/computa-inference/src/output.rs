use regex::Regex;
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Debug)]
pub struct OfferedTool {
    pub name: String,
    pub namespace: Option<String>,
    pub schema: Value,
}
#[derive(Clone, Debug, serde::Serialize)]
pub struct ToolCall {
    pub name: String,
    pub namespace: Option<String>,
    pub arguments: String,
}
#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum OutputError {
    #[error("The model output did not stop cleanly; no tool was dispatched.")]
    Unfinished,
    #[error("Malformed model tool or reasoning envelope; no tool was dispatched.")]
    Malformed,
    #[error("The model requested an unoffered tool; no tool was dispatched.")]
    Unoffered,
    #[error("The model arguments are not a JSON object; no tool was dispatched.")]
    Arguments,
    #[error("The tool schema is invalid or ambiguous.")]
    Schema,
}
pub fn offered_tools(raw: &Value) -> Result<BTreeMap<String, OfferedTool>, OutputError> {
    let mut result = BTreeMap::new();
    fn insert(
        result: &mut BTreeMap<String, OfferedTool>,
        tool: &Value,
        namespace: Option<&str>,
    ) -> Result<(), OutputError> {
        if tool["type"] != "function" || !tool["parameters"].is_object() {
            return Err(OutputError::Schema);
        }
        let name = tool["name"]
            .as_str()
            .filter(|n| !n.is_empty())
            .ok_or(OutputError::Schema)?;
        let full = namespace.map_or_else(|| name.into(), |ns| format!("{ns}.{name}"));
        if result
            .insert(
                full,
                OfferedTool {
                    name: name.into(),
                    namespace: namespace.map(str::to_owned),
                    schema: tool.clone(),
                },
            )
            .is_some()
        {
            return Err(OutputError::Schema);
        }
        Ok(())
    }
    if let Some(tools) = raw.get("tools").filter(|v| !v.is_null()) {
        for tool in tools.as_array().ok_or(OutputError::Schema)? {
            if tool["type"] == "namespace" {
                let ns = tool["name"]
                    .as_str()
                    .filter(|n| !n.is_empty())
                    .ok_or(OutputError::Schema)?;
                for child in tool["tools"].as_array().ok_or(OutputError::Schema)? {
                    insert(&mut result, child, Some(ns))?;
                }
            } else {
                insert(&mut result, tool, None)?;
            }
        }
    }
    Ok(result)
}
pub fn final_content(raw: &str) -> Result<&str, OutputError> {
    if raw.matches("<think>").count() > 1 || raw.matches("</think>").count() > 1 {
        return Err(OutputError::Malformed);
    }
    let content = if let Some((before, after)) = raw.split_once("</think>") {
        if before.contains("</think>") || after.contains("<think>") {
            return Err(OutputError::Malformed);
        }
        after
    } else if raw.contains("<think>") {
        return Err(OutputError::Unfinished);
    } else {
        raw
    };
    if content.contains('\0') || Regex::new(r"(?i)<\s*/?\s*think").unwrap().is_match(content) {
        return Err(OutputError::Malformed);
    }
    Ok(content.trim())
}
pub fn parse_calls(
    raw: &str,
    offered: &BTreeMap<String, OfferedTool>,
    clean_stop: bool,
) -> Result<Vec<ToolCall>, OutputError> {
    if !clean_stop {
        return Err(OutputError::Unfinished);
    }
    let content = final_content(raw)?;
    let pattern = Regex::new(r"(?s)<tool_call>\s*(.*?)\s*</tool_call>").unwrap();
    let matches: Vec<_> = pattern.captures_iter(content).collect();
    if matches.is_empty() {
        if Regex::new(r"(?i)<\s*/?\s*(?:tool|function|parameter)|<\|")
            .unwrap()
            .is_match(content)
        {
            return Err(OutputError::Malformed);
        }
        return Ok(Vec::new());
    }
    if content.matches("<tool_call>").count() != matches.len()
        || content.matches("</tool_call>").count() != matches.len()
    {
        return Err(OutputError::Malformed);
    }
    let mut calls = Vec::new();
    let mut previous = 0;
    for (index, capture) in matches.iter().enumerate() {
        let matched = capture.get(0).unwrap();
        if index > 0 && !content[previous..matched.start()].trim().is_empty() {
            return Err(OutputError::Malformed);
        }
        let body = &capture[1];
        let value = if body.trim_start().starts_with('{') {
            computa_contracts::strict_json::parse(body.as_bytes())
                .map_err(|_| OutputError::Malformed)?
        } else {
            parse_xml_call(body, offered)?
        };
        let object = value.as_object().ok_or(OutputError::Malformed)?;
        if object.len() != 2 || !object.contains_key("name") || !object.contains_key("arguments") {
            return Err(OutputError::Malformed);
        }
        let name = value["name"].as_str().ok_or(OutputError::Malformed)?;
        let tool = offered.get(name).ok_or(OutputError::Unoffered)?;
        if !value["arguments"].is_object() {
            return Err(OutputError::Arguments);
        }
        calls.push(ToolCall {
            name: tool.name.clone(),
            namespace: tool.namespace.clone(),
            arguments: value["arguments"].to_string(),
        });
        previous = matched.end();
    }
    if !content[previous..].trim().is_empty() {
        return Err(OutputError::Malformed);
    }
    Ok(calls)
}
fn parse_xml_call(
    body: &str,
    offered: &BTreeMap<String, OfferedTool>,
) -> Result<Value, OutputError> {
    let function =
        Regex::new(r"(?s)^\s*<function=([a-zA-Z_][\w.-]*)>\s*(.*?)\s*</function>\s*$").unwrap();
    let captures = function.captures(body).ok_or(OutputError::Malformed)?;
    let name = &captures[1];
    let tool = offered.get(name).ok_or(OutputError::Unoffered)?;
    let param = Regex::new(r"(?s)^\s*<parameter=([a-zA-Z_][\w]*)>\n?(.*?)\n?</parameter>").unwrap();
    let mut rest = &captures[2];
    let mut args = serde_json::Map::new();
    let mut keys = HashSet::new();
    while !rest.trim().is_empty() {
        let captures = param.captures(rest).ok_or(OutputError::Malformed)?;
        let key = &captures[1];
        let value = &captures[2];
        if !keys.insert(key.to_owned()) {
            return Err(OutputError::Malformed);
        }
        let schema = &tool.schema["parameters"]["properties"][key];
        let numeric = matches!(
            schema["type"].as_str(),
            Some("number" | "integer" | "boolean" | "array" | "object" | "null")
        );
        let value = if numeric {
            computa_contracts::strict_json::parse(value.as_bytes())
                .map_err(|_| OutputError::Arguments)?
        } else {
            Value::String(value.into())
        };
        args.insert(key.into(), value);
        rest = &rest[captures.get(0).unwrap().end()..];
    }
    Ok(json!({"name":name,"arguments":args}))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn tools() -> BTreeMap<String, OfferedTool> {
        offered_tools(&json!({"tools":[{"type":"function","name":"click","parameters":{"type":"object","properties":{"x":{"type":"number"},"text":{"type":"string"}}}}]})).unwrap()
    }
    #[test]
    fn cancelled_or_partial_calls_never_become_actions() {
        for raw in [
            "<tool_call>{\"name\":\"click\",\"arguments\":{}}</tool_call><tool_call>",
            "<think>unfinished",
            "<tool_call>{\"name\":\"click\",\"arguments\":{}}</tool_call> trailing",
        ] {
            assert!(parse_calls(raw, &tools(), true).is_err());
        }
        assert_eq!(
            parse_calls(
                "<tool_call>{\"name\":\"click\",\"arguments\":{}}</tool_call>",
                &tools(),
                false
            )
            .unwrap_err(),
            OutputError::Unfinished
        );
    }
    #[test]
    fn whole_bundle_and_duplicate_arguments_fail_closed() {
        assert!(parse_calls("<tool_call>{\"name\":\"click\",\"arguments\":{}}</tool_call><tool_call>{\"name\":\"unoffered\",\"arguments\":{}}</tool_call>",&tools(),true).is_err());
        assert!(
            parse_calls(
                "<tool_call>{\"name\":\"click\",\"arguments\":{\"x\":1,\"x\":2}}</tool_call>",
                &tools(),
                true
            )
            .is_err()
        );
    }
    #[test]
    fn native_xml_preserves_literal_strings_and_schema_numeric_types() {
        let calls=parse_calls("reason</think><tool_call><function=click><parameter=x>12.5</parameter><parameter=text>hello & world</parameter></function></tool_call>",&tools(),true).unwrap();
        let args: Value = serde_json::from_str(&calls[0].arguments).unwrap();
        assert_eq!(args["x"], 12.5);
        assert_eq!(args["text"], "hello & world");
    }
}

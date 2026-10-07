use serde_json::{Value, json};
use std::collections::HashSet;
pub fn keys(value: &Value, expected: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|m| m.len() == expected.len() && expected.iter().all(|k| m.contains_key(*k)))
}
pub fn eligible(raw: &str) -> bool {
    raw.len() <= 16_384
        && url::Url::parse(raw)
            .is_ok_and(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some())
}
pub fn eligible_owned(raw: &str) -> bool {
    eligible(raw)
        || raw.len() <= 16_384
            && url::Url::parse(raw).is_ok_and(|u| {
                u.scheme() == "file"
                    && u.host_str().is_none_or(|host| host == "localhost")
                    && u.path().starts_with('/')
                    && !u.path().is_empty()
            })
}
pub fn validate_owned(method: &str, params: &Value) -> Result<(), String> {
    if method == "Runtime.callFunctionOn"
        && params["arguments"][0]["value"]
            .as_str()
            .is_some_and(|url| eligible_owned(url) && !eligible(url))
    {
        let mut shape = params.clone();
        shape["arguments"][0]["value"] = json!("https://owned.invalid/");
        validate(method, &shape)
    } else {
        validate(method, params)
    }
}
pub use super::{PRESS_FUNCTION as PRESS, SET_TEXT_FUNCTION as SET_TEXT};
pub fn validate(method: &str, p: &Value) -> Result<(), String> {
    let positive = |v: &Value| v.as_u64().is_some_and(|n| n > 0);
    let object_group = |v: &Value| {
        v.as_str().is_some_and(|s| {
            s.strip_prefix("heydash-mutation-")
                .is_some_and(super::uuid_text)
        })
    };
    let allowed = match method {
        "Page.getFrameTree" | "Accessibility.enable" => keys(p, &[]),
        "Accessibility.getFullAXTree" => {
            keys(p, &["depth"]) && matches!(p["depth"].as_u64(), Some(16 | 64))
        }
        "DOMSnapshot.captureSnapshot" => {
            keys(p, &["computedStyles"])
                && p["computedStyles"]
                    == json!(["cursor", "visibility", "display", "pointer-events"])
        }
        "Page.createIsolatedWorld" => {
            keys(p, &["frameId", "worldName"])
                && p["frameId"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty() && s.len() <= 256)
                && p["worldName"] == "LocalCodexBrowserBroker"
        }
        "DOM.resolveNode" => {
            keys(p, &["backendNodeId", "executionContextId", "objectGroup"])
                && positive(&p["backendNodeId"])
                && positive(&p["executionContextId"])
                && object_group(&p["objectGroup"])
        }
        "Runtime.releaseObjectGroup" => {
            keys(p, &["objectGroup"]) && object_group(&p["objectGroup"])
        }
        "Runtime.callFunctionOn" => {
            let declaration = p["functionDeclaration"].as_str();
            let press = declaration == Some(PRESS);
            let text = declaration == Some(SET_TEXT);
            keys(
                p,
                &[
                    "objectId",
                    "functionDeclaration",
                    "arguments",
                    "returnByValue",
                    "awaitPromise",
                    "userGesture",
                ],
            ) && (press || text)
                && p["objectId"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty() && s.len() <= 2048)
                && p["returnByValue"] == true
                && p["awaitPromise"] == true
                && p["userGesture"] == true
                && p["arguments"].as_array().is_some_and(|a| {
                    a.len() == if press { 1 } else { 2 }
                        && a.iter().all(|v| keys(v, &["value"]))
                        && a[0]["value"].as_str().is_some_and(eligible)
                        && (press || a[1]["value"].as_str().is_some_and(|s| s.len() <= 65_536))
                })
        }
        _ => return Err("unsupported_command".into()),
    };
    if allowed {
        Ok(())
    } else {
        Err("invalid_request".into())
    }
}
pub fn project_ax(result: &Value, limit: usize) -> Result<Value, String> {
    let Some(nodes) = result["nodes"].as_array() else {
        return Ok(result.clone());
    };
    let mut out = vec![];
    let mut bytes = 1024;
    for node in nodes {
        let Some(object) = node.as_object() else {
            break;
        };
        let mut value = serde_json::Map::new();
        for key in [
            "nodeId",
            "parentId",
            "childIds",
            "backendDOMNodeId",
            "frameId",
            "ignored",
        ] {
            if let Some(v) = object.get(key) {
                value.insert(key.into(), v.clone());
            }
        }
        for key in ["role", "chromeRole", "name", "description", "value"] {
            if let Some(v) = object.get(key) {
                value.insert(key.into(), ax_value(v));
            }
        }
        if let Some(properties) = object.get("properties").and_then(Value::as_array) {
            value.insert(
                "properties".into(),
                json!(
                    properties
                        .iter()
                        .filter(|v| v.is_object())
                        .map(|v| json!({"name":v["name"],"value":ax_value(&v["value"])}))
                        .collect::<Vec<_>>()
                ),
            );
        }
        let value = Value::Object(value);
        let size = serde_json::to_vec(&value)
            .map_err(|_| "invalid_document")?
            .len()
            + 1;
        if out.len() >= 12_000 || bytes + size > limit {
            break;
        }
        bytes += size;
        out.push(value);
    }
    Ok(
        json!({"nodes":out,"macrouseSourceTruncated":out.len()!=nodes.len(),"macrouseSourceNodeCount":nodes.len()}),
    )
}
fn ax_value(value: &Value) -> Value {
    if let Some(object) = value.as_object() {
        let mut output = serde_json::Map::new();
        for key in ["type", "value", "relatedNodes"] {
            if let Some(value) = object.get(key) {
                output.insert(key.into(), value.clone());
            }
        }
        Value::Object(output)
    } else {
        value.clone()
    }
}
pub fn project_clickability(result: &Value, limit: usize, frame: &Value) -> Result<Value, String> {
    project_clickability_scope(result, limit, frame, false)
}
pub fn project_clickability_owned(
    result: &Value,
    limit: usize,
    frame: &Value,
) -> Result<Value, String> {
    project_clickability_scope(result, limit, frame, true)
}
fn project_clickability_scope(
    result: &Value,
    limit: usize,
    frame: &Value,
    owned: bool,
) -> Result<Value, String> {
    let invalid = || "invalid_document".to_owned();
    let docs = result["documents"].as_array().ok_or_else(invalid)?;
    let strings = result["strings"].as_array().ok_or_else(invalid)?;
    if docs.is_empty() || docs.len() > 256 {
        return Err(invalid());
    }
    let string = |v: &Value| -> Result<&str, String> {
        let index = v.as_u64().ok_or_else(invalid)? as usize;
        strings
            .get(index)
            .and_then(Value::as_str)
            .ok_or_else(invalid)
    };
    let mut frames = HashSet::new();
    let mut main = None;
    for doc in docs {
        let id = string(&doc["frameId"])?;
        if id.is_empty() || !frames.insert(id) {
            return Err(invalid());
        }
        if Some(id) == frame["id"].as_str() {
            main = Some(doc);
        }
    }
    let main = main.ok_or_else(invalid)?;
    let raw = string(&main["documentURL"])?;
    if Some(raw) != frame["url"].as_str()
        || !(if owned {
            eligible_owned(raw)
        } else {
            eligible(raw)
        })
    {
        return Err(invalid());
    }
    let ids = main["nodes"]["backendNodeId"]
        .as_array()
        .ok_or_else(invalid)?;
    let mut unique = HashSet::new();
    if ids.len() > 100_000
        || ids
            .iter()
            .any(|id| id.as_u64().is_none_or(|n| n == 0 || !unique.insert(n)))
    {
        return Err(invalid());
    }
    let mut clickable = vec![];
    let mut indices = HashSet::new();
    if let Some(rare) = main["nodes"].get("isClickable") {
        if !keys(rare, &["index"]) {
            return Err(invalid());
        }
        for index in rare["index"].as_array().ok_or_else(invalid)? {
            let index = index.as_u64().ok_or_else(invalid)? as usize;
            if index >= ids.len() || !indices.insert(index) {
                return Err(invalid());
            }
            clickable.push(ids[index].clone());
        }
    }
    let layout = &main["layout"];
    let node_indices = layout["nodeIndex"].as_array().ok_or_else(invalid)?;
    let styles = layout["styles"].as_array().ok_or_else(invalid)?;
    let bounds = layout["bounds"].as_array().ok_or_else(invalid)?;
    if node_indices.len() > 100_000
        || styles.len() != node_indices.len()
        || bounds.len() != node_indices.len()
    {
        return Err(invalid());
    }
    let mut pointer = vec![];
    let mut pointer_ids = HashSet::new();
    for i in 0..node_indices.len() {
        let index = node_indices[i].as_u64().ok_or_else(invalid)? as usize;
        if index >= ids.len() {
            return Err(invalid());
        }
        let style = styles[i].as_array().ok_or_else(invalid)?;
        let rect = bounds[i].as_array().ok_or_else(invalid)?;
        if !matches!(style.len(), 0 | 4)
            || rect.len() != 4
            || rect
                .iter()
                .any(|v| v.as_f64().is_none_or(|n| !n.is_finite()))
            || rect[2].as_f64().unwrap() < 0.0
            || rect[3].as_f64().unwrap() < 0.0
        {
            return Err(invalid());
        }
        if style.len() == 4 {
            let a = string(&style[0])?;
            let b = string(&style[1])?;
            let c = string(&style[2])?;
            let d = string(&style[3])?;
            if a == "pointer"
                && b == "visible"
                && !matches!(c, "" | "none")
                && !matches!(d, "" | "none")
                && rect[2].as_f64().unwrap() > 0.0
                && rect[3].as_f64().unwrap() > 0.0
                && pointer_ids.insert(ids[index].as_u64().unwrap())
            {
                pointer.push(ids[index].clone());
            }
        }
    }
    let mut empty = vec![];
    let mut value_indices = HashSet::new();
    for (field, tag) in [("inputValue", "INPUT"), ("textValue", "TEXTAREA")] {
        if let Some(rare) = main["nodes"].get(field) {
            if !keys(rare, &["index", "value"]) {
                return Err(invalid());
            }
            let list = rare["index"].as_array().ok_or_else(invalid)?;
            let values = rare["value"].as_array().ok_or_else(invalid)?;
            if list.len() != values.len() {
                return Err(invalid());
            }
            for (i, v) in list.iter().zip(values) {
                let index = i.as_u64().ok_or_else(invalid)? as usize;
                if index >= ids.len() || !value_indices.insert(index) {
                    return Err(invalid());
                }
                let value = if v.as_i64() == Some(-1) {
                    ""
                } else {
                    string(v)?
                };
                let nodes = &main["nodes"];
                if string(&nodes["nodeName"][index])? != tag || nodes["nodeType"][index] != 1 {
                    return Err(invalid());
                }
                if !value.is_empty() {
                    continue;
                }
                let mut current = index as i64;
                let mut seen = HashSet::new();
                let mut allowed = true;
                while current >= 0 {
                    let j = current as usize;
                    if j >= ids.len() || !seen.insert(j) {
                        return Err(invalid());
                    }
                    if seen.len() > 128 {
                        allowed = false;
                        break;
                    }
                    let attrs = nodes["attributes"][j].as_array().ok_or_else(invalid)?;
                    if attrs.len() % 2 != 0 || attrs.len() > 4096 {
                        return Err(invalid());
                    }
                    let mut map = std::collections::HashMap::new();
                    for pair in attrs.chunks(2) {
                        let key = string(&pair[0])?.to_lowercase();
                        if key.is_empty()
                            || map
                                .insert(
                                    key,
                                    if pair[1].as_i64() == Some(-1) {
                                        ""
                                    } else {
                                        string(&pair[1])?
                                    },
                                )
                                .is_some()
                        {
                            return Err(invalid());
                        }
                    }
                    if ["disabled", "readonly", "inert"]
                        .iter()
                        .any(|key| map.contains_key(*key))
                        || ["aria-disabled", "aria-readonly"].iter().any(|key| {
                            map.get(*key)
                                .is_some_and(|v| v.eq_ignore_ascii_case("true"))
                        })
                    {
                        allowed = false;
                    }
                    if j == index
                        && tag == "INPUT"
                        && !matches!(
                            map.get("type")
                                .copied()
                                .unwrap_or("text")
                                .to_ascii_lowercase()
                                .as_str(),
                            "" | "text" | "search" | "email" | "url" | "tel"
                        )
                    {
                        allowed = false;
                    }
                    current = nodes["parentIndex"][j].as_i64().ok_or_else(invalid)?;
                    if current < -1 || current >= ids.len() as i64 {
                        return Err(invalid());
                    }
                }
                if allowed {
                    empty.push(ids[index].clone());
                }
            }
        }
    }
    let mut links = vec![];
    let base = url::Url::parse(raw).map_err(|_| invalid())?;
    if let Some(names) = main["nodes"]["nodeName"].as_array() {
        if names.len() != ids.len() {
            return Err(invalid());
        }
        for (index, name) in names.iter().enumerate() {
            if string(name)? != "A" {
                continue;
            }
            let attributes = main["nodes"]["attributes"][index]
                .as_array()
                .ok_or_else(invalid)?;
            if attributes.len() % 2 != 0 || attributes.len() > 4096 {
                return Err(invalid());
            }
            let mut href = None;
            for pair in attributes.chunks(2) {
                if string(&pair[0])?.eq_ignore_ascii_case("href") {
                    if href.is_some() {
                        return Err(invalid());
                    }
                    href = Some(if pair[1].as_i64() == Some(-1) {
                        ""
                    } else {
                        string(&pair[1])?
                    });
                }
            }
            let allowed_destination = if owned { eligible_owned } else { eligible };
            if let Some(href) = href
                && let Ok(destination) = base.join(href)
                && allowed_destination(destination.as_str())
            {
                links.push(json!({"backendNodeId":ids[index],"url":destination.as_str()}));
            }
        }
    }
    let mut evidence = json!({"frameId":frame["id"],"documentURL":raw,"clickableBackendNodeIds":[],"pointerBackendNodeIds":[],"linkURLs":[],"sourceTruncated":false,"sourceNodeCount":ids.len()});
    if !empty.is_empty() {
        evidence["emptyTextValueBackendNodeIds"] = json!([]);
    }
    // Frame identity cannot be truncated. If even the empty projection exceeds
    // the caller's budget, reject it instead of returning an oversized receipt.
    if serde_json::to_vec(&json!({"mactopusClickability":evidence}))
        .map_err(|_| invalid())?
        .len()
        > limit
    {
        return Err("response_too_large".into());
    }
    for (key, list) in [
        ("clickableBackendNodeIds", clickable),
        ("pointerBackendNodeIds", pointer),
        ("emptyTextValueBackendNodeIds", empty),
    ] {
        for id in list {
            let n = evidence[key].as_array().map_or(0, Vec::len);
            evidence[key].as_array_mut().ok_or_else(invalid)?.push(id);
            if n >= 12_000
                || serde_json::to_vec(&json!({"mactopusClickability":evidence}))
                    .map_err(|_| invalid())?
                    .len()
                    > limit
            {
                evidence[key].as_array_mut().unwrap().pop();
                evidence["sourceTruncated"] = json!(true);
                break;
            }
        }
    }
    for link in links {
        let n = evidence["linkURLs"].as_array().unwrap().len();
        evidence["linkURLs"].as_array_mut().unwrap().push(link);
        if n >= 12_000
            || serde_json::to_vec(&json!({"mactopusClickability":evidence}))
                .map_err(|_| invalid())?
                .len()
                > limit
        {
            evidence["linkURLs"].as_array_mut().unwrap().pop();
            evidence["sourceTruncated"] = json!(true);
            break;
        }
    }
    Ok(json!({"mactopusClickability":evidence}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arbitrary_execution_is_rejected() {
        for method in ["Runtime.evaluate", "Page.navigate", "Target.createTarget"] {
            assert_eq!(
                validate(method, &json!({})),
                Err("unsupported_command".into())
            );
        }
    }
    #[test]
    fn ax_sources_are_removed() {
        let result = project_ax(
            &json!({"nodes":[{"nodeId":"1","name":{"value":"button","sources":["secret"]}}]}),
            1000,
        )
        .unwrap();
        assert!(!result.to_string().contains("secret"));
    }
    fn dom() -> Value {
        json!({"strings":["main","https://example.test/base/","A","href","../observed?q=1","javascript:alert(1)"],"documents":[{"frameId":0,"documentURL":1,"nodes":{"backendNodeId":[7,8],"nodeName":[2,2],"attributes":[[3,4],[3,5]],"isClickable":{"index":[0,1]}},"layout":{"nodeIndex":[],"styles":[],"bounds":[]}}]})
    }
    #[test]
    fn observed_links_require_exact_document_and_finite_destination() {
        let source = dom();
        let frame = json!({"id":"main","url":"https://example.test/base/"});
        let projected = project_clickability(&source, 8192, &frame).unwrap();
        assert_eq!(
            projected["mactopusClickability"]["linkURLs"],
            json!([{"backendNodeId":7,"url":"https://example.test/observed?q=1"}])
        );
        let changed = json!({"id":"main","url":"https://example.test/replaced"});
        assert!(project_clickability(&source, 8192, &changed).is_err());
        let mut duplicate = source.clone();
        duplicate["documents"][0]["nodes"]["backendNodeId"] = json!([7, 7]);
        assert!(project_clickability(&duplicate, 8192, &frame).is_err());
        let mut frames = source.clone();
        frames["documents"]
            .as_array_mut()
            .unwrap()
            .push(source["documents"][0].clone());
        assert!(project_clickability(&frames, 8192, &frame).is_err());
    }
    #[test]
    fn projection_never_exceeds_budget_or_drops_frame_identity() {
        let frame = json!({"id":"main","url":"https://example.test/base/"});
        assert_eq!(
            project_clickability(&dom(), 16, &frame),
            Err("response_too_large".into())
        );
        let projected = project_clickability(&dom(), 240, &frame).unwrap();
        assert!(serde_json::to_vec(&projected).unwrap().len() <= 240);
        assert_eq!(
            projected["mactopusClickability"]["documentURL"],
            frame["url"]
        );
        assert_eq!(projected["mactopusClickability"]["sourceTruncated"], true);
    }
}

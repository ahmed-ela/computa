//! Import only the first-party keys from the original app's native defaults.
//! Qualification profiles never read the production defaults or Keychain.
use objc2::{AnyThread, rc::Retained};
use objc2_foundation::{NSJSONSerialization, NSJSONWritingOptions, NSString, NSUserDefaults};
use serde_json::{Map, Value};
use uuid::Uuid;
pub fn legacy_defaults() -> std::io::Result<Map<String, Value>> {
    let suite = NSString::from_str("com.ahmedelamin.LocalCodex");
    let defaults = NSUserDefaults::initWithSuiteName(NSUserDefaults::alloc(), Some(&suite))
        .ok_or_else(|| std::io::Error::other("Native preferences are unavailable"))?;
    let mut result = Map::new();
    for key in [
        "LocalCodex.defaultModelID",
        "HeyDash.accessMode",
        "ComputaReferenceToolThreads.v1",
    ] {
        if let Some(value) = defaults.objectForKey(&NSString::from_str(key)) {
            // SAFETY: these known preference keys contain property-list scalar,
            // array, or dictionary JSON values. Foundation rejects unsupported types;
            // no object is shared with concurrent mutation while encoding it.
            if let Ok(data) = unsafe {
                NSJSONSerialization::dataWithJSONObject_options_error(
                    &value,
                    NSJSONWritingOptions::FragmentsAllowed,
                )
            } {
                let bytes = data.to_vec();
                if bytes.len() <= 1024 * 1024
                    && let Ok(value) = computa_contracts::strict_json::parse(&bytes)
                {
                    result.insert(key.into(), value);
                }
            }
        }
    }
    Ok(result)
}
pub fn browser_profile(private: bool) -> std::io::Result<Uuid> {
    if private {
        return Ok(Uuid::new_v4());
    }
    let defaults = NSUserDefaults::initWithSuiteName(
        NSUserDefaults::alloc(),
        Some(&NSString::from_str("com.ahmedelamin.LocalCodex")),
    )
    .ok_or_else(|| std::io::Error::other("Native browser preferences are unavailable"))?;
    let key = NSString::from_str("Computa.EmbeddedBrowser.ProfileIdentifier.v1");
    if let Some(existing) = defaults
        .stringForKey(&key)
        .and_then(|s| Uuid::parse_str(&s.to_string()).ok())
    {
        return Ok(existing);
    }
    let id = Uuid::new_v4();
    let value: Retained<NSString> = NSString::from_str(&id.to_string());
    // SAFETY: the UUID is an immutable Foundation property-list string and
    // this exact app suite owns the well-known browser profile key.
    unsafe {
        defaults.setObject_forKey(Some(&value), &key);
    }
    Ok(id)
}

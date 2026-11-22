//! Emit the catalog bundled with the Swift host.
use computa_contracts::browser_tools::catalog;

fn bundled_json() -> String {
    let mut value = catalog();
    value.sort_all_objects();
    format!("{}\n", serde_json::to_string_pretty(&value).unwrap())
}

fn main() {
    print!("{}", bundled_json());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shipped_catalog_matches_rust_generator() {
        let bundled = include_str!("../../../../Sources/Computa/Resources/BrowserToolCatalog.json");
        assert_eq!(
            bundled,
            bundled_json(),
            "Regenerate BrowserToolCatalog.json after changing its Rust declarations"
        );
    }
}

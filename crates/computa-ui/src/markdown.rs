use pulldown_cmark::{CowStr, Event, Options, Parser, Tag, TagEnd, html};

/// Render only passive Markdown. Model text cannot load media, execute HTML,
/// create an application action, or navigate to a non-HTTP scheme.
pub fn render(text: &str) -> String {
    let parser = Parser::new_ext(
        text,
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS,
    );
    let mut links = Vec::new();
    let events = parser.map(|event| match event {
        Event::Html(raw) | Event::InlineHtml(raw) => Event::Text(raw),
        Event::Start(Tag::Image { .. }) => Event::Text(CowStr::Borrowed("[Image: ")),
        Event::End(TagEnd::Image) => Event::Text(CowStr::Borrowed("]")),
        Event::Start(Tag::Link {
            dest_url, title, ..
        }) => {
            let href = url::Url::parse(&dest_url)
                .ok()
                .filter(|u| matches!(u.scheme(), "http" | "https"));
            links.push(href.is_some());
            Event::InlineHtml(match href {
                Some(href) => CowStr::from(format!(
                    "<a href=\"{}\" rel=\"noreferrer noopener\" title=\"{}\">",
                    escape(href.as_str()),
                    escape(&title)
                )),
                None => CowStr::Borrowed("<span>"),
            })
        }
        Event::End(TagEnd::Link) => {
            Event::InlineHtml(CowStr::Borrowed(if links.pop().unwrap_or(false) {
                "</a>"
            } else {
                "</span>"
            }))
        }
        other => other,
    });
    let mut output = String::new();
    html::push_html(&mut output, events);
    output
}

pub fn escape(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            '"' => output.push_str("&quot;"),
            '\'' => output.push_str("&#39;"),
            _ => output.push(c),
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malicious_markdown_stays_passive() {
        let html = render(
            "<script>window.ipc.postMessage('approve')</script>\n\n![secret](https://tracker.test/a) [run](javascript:alert(1)) [file](file:///private/a)",
        );
        assert!(!html.contains("<script>"));
        assert!(!html.contains("<img"));
        assert!(!html.contains("href=\"javascript:"));
        assert!(!html.contains("href=\"file:"));
        assert!(html.contains("[Image: secret]"));
    }
    #[test]
    fn code_indentation_and_tables_survive() {
        let html = render("```rust\n  let x = 1;\n\n    x\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |");
        assert!(html.contains("  let x = 1;\n\n    x\n"));
        assert!(html.contains("<table>"));
    }
}

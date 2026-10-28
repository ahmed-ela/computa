#!/usr/bin/env python3
"""Safe mailbox whose unfocused compose panel starts collapsed behind a wide inbox.

Reuse the original loopback transport, recipient restriction and append-only
delivery ledger. Only this separate process's page factory changes; existing
crowded mailbox fixtures and their recorded source hashes remain unchanged.
"""
import html
import importlib.util
from pathlib import Path

_source = Path(__file__).with_name("crowded_browser_mailbox.py")
_spec = importlib.util.spec_from_file_location("computa_crowded_mailbox_fixture", _source)
mailbox = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mailbox)


INBOX_ROWS = 5001
OVERLAY_DEPTH = 12


def minimized_document(*, focus=False, prefill=False, missing_send=False):
    # A single wide inbox branch exhausted the former breadth-first discovery
    # queue before it reached a small, deeply nested sibling control panel.
    preview = ("Synthetic inbox preview for the safe minimized compose fixture. "
               "This row contains no requested form fields or delivery action. ")
    rows = "".join(f"<div role='row'><span>Fixture message {index:04d}. {preview}</span></div>"
                   for index in range(INBOX_ROWS))
    old = {"to": "old-draft@example.invalid", "subject": "Old unsent draft", "body": "Replace this old draft."} if prefill else {}
    fields = ("<form method='post' action='/draft'>"
              "<label>To<input name='to' type='email' required value='"
              + html.escape(old.get("to", ""), quote=True) + "'></label>"
              "<label>Subject<input name='subject' required value='"
              + html.escape(old.get("subject", ""), quote=True) + "'></label>"
              "<label>Message body<textarea name='body' required rows='4'>"
              + html.escape(old.get("body", "")) + "</textarea></label>"
              "<button type='submit'>Save draft</button></form>")
    # The panel deliberately has no dialog/form role and no editable controls
    # while collapsed. No focus call can rescue its discovery. Maximize models
    # a narrow viewport where that action does not reveal the composer fields.
    panel = ("<div id='compose' aria-label='Compose: New Message' hidden>"
             "<h2>New Message</h2><div class='panel-actions'>"
             "<button id='maximize' type='button'>Maximize</button>"
             "<button id='full-screen' type='button'>Full screen</button>"
             "<button id='save-close' type='button'>Save &amp; close</button>"
             "</div></div>")
    for _ in range(OVERLAY_DEPTH):
        panel = "<div>" + panel + "</div>"
    body = ("<style>#compose{width:300px}#compose.expanded{width:min(640px,90vw);"
            "max-height:85vh;overflow:auto}.panel-actions{display:flex;gap:8px}"
            "#inbox{height:65vh;overflow:auto}</style>"
            "<header><h1>Minimized local mailbox</h1>"
            "<button id='open-compose' type='button'>Compose</button>"
            "<a href='/drafts'>Drafts</a><a href='/sent'>Sent</a></header>"
            "<main><h2>Inbox</h2><p>All messages and actions are synthetic and local.</p>"
            f"<section id='inbox' role='grid' aria-label='Inbox messages'>{rows}</section></main>"
            + panel + "<template id='composer-fields'>" + fields + "</template>")
    script = """
const panel = document.getElementById('compose');
document.getElementById('open-compose').addEventListener('click', () => {
  panel.hidden = false;
  history.replaceState(null, '', location.pathname + location.search + '#compose');
});
document.getElementById('maximize').addEventListener('click', () => {
  panel.dataset.maximizeAttempts = String(Number(panel.dataset.maximizeAttempts || 0) + 1);
});
document.getElementById('full-screen').addEventListener('click', () => {
  if (!panel.querySelector('form'))
    panel.append(document.getElementById('composer-fields').content.cloneNode(true));
  panel.classList.add('expanded');
});
document.getElementById('save-close').addEventListener('click', () => { panel.hidden = true; });
"""
    return mailbox.page("Minimized local mailbox", body, script)


if __name__ == "__main__":
    mailbox.INBOX_ROWS = INBOX_ROWS
    mailbox.crowded_document = minimized_document
    mailbox.main()

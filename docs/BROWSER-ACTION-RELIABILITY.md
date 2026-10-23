# Browser action reliability

An Outlook follow-up exposed several independent failures. The model reused a
task tab that cleanup had closed, mixed continuation cursors with changed read
filters, and attempted stale or non-actionable targets. A later documentation
request was restricted to chatgpt.com merely because its text mentioned ChatGPT.
Finally, an explicitly requested message send was refused without any tool call:
the model described background-only operation as a read-only permission policy.

The saved runtime evidence distinguishes these failures. The browser recovery
stop belonged to the earlier search turn, not the later message request. Turn
scope and retry counters were already reset correctly. On reload, however, the
old stop notice was appended after every subsequent turn, making it appear current.

## Changes

- Fresh per-turn instructions distinguish input delivery from authorized effects.
  Background operation forbids activation and global input; offered background
  tools can perform user-authorized actions. Read-only work still permits search
  inputs and navigation, while account/content changes need authorization.
- Historical assistant refusals and outcome corrections do not establish current
  permissions. Actual denials, Stop, approval checks and ongoing user constraints
  remain binding. Each user turn reacquires browser handles and observations.
- Known-service restrictions require destination language. A documentation topic
  does not create an exclusive service-host restriction. Explicit destination,
  URL, title and browser constraints remain enforced.
- A changed-filter continuation is rejected before discarding the prior valid
  observation. The error gives separate instructions for continuing the captured
  read and starting a new filtered read.
- Navigation-related stale preflight errors can return a bounded fresh read,
  like other stale snapshot errors. They remain failed, undispatched actions;
  input is never replayed. Approval, ownership and unchanged-attempt limits remain.
- Saved stop notices retain their turn identity and appear beside that turn after
  reload rather than below an unrelated later reply.

## Reproduction and qualification

`Tests/Fixtures/browser_action_mailbox.py` serves an isolated loopback mailbox.
It cannot send external mail. Start it with a new `--evidence-dir` and use the
origin in its `connection.json` through Computa's installed model-driven browser.

1. Ask the model to read the ODE announcement and attachment filename, with an
   explicit read-only constraint. Confirm no POST delivery in `events.jsonl`.
2. After the app closes its task-created tab, ask in the same chat to send
   `course-staff@example.invalid` a message about the Teams screenshot and exam
   change, with a unique subject. Supply no tool names or navigation instructions.
3. Require a fresh binding, one delivery with the requested fields, a browser
   observation of the server-generated receipt, a matching final answer, and
   cleanup of owned tabs. A model's success claim alone is not a pass.
4. Repeat after a previously failed/refusing turn to check recovery from history.

The fixture uses a threaded server because WebKit can open idle preconnections;
a serial HTTP server can block real navigation behind those sockets. Such a
fixture timeout is not evidence of a production browser navigation failure.

Synthetic mailbox qualification does not establish delivery through a real mail
provider. Real mailbox checks must preserve the user's task-specific limits.

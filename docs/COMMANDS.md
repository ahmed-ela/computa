# Running CLI commands

Mactopus can use command-line tools as well as browser and desktop controls.
Ask in the task composer, for example:

> Run `uname -m` and `pwd`, then report their output and exit status.

> In `/absolute/path/to/my/repo`, run `git status --short` and summarize the changes.

Commands run through the app-owned agent runtime. They do not type into, close,
or reuse an existing Terminal window. The task's **Command** entries show the
working directory, command, output, and exit status. Output updates while the
command runs; each command entry retains at most 32 KiB and labels truncation.
A running command is not shown as successful. A nonzero or missing exit status
is not a success.

## Working directory and tools

The default working directory is Mactopus's private workspace under
`~/Library/Application Support/LocalCodex/CodexHome/Workspace`. Give an absolute
working directory when asking about a project elsewhere.

System command directories, `/opt/homebrew/bin`, and `/usr/local/bin` are on the
runtime PATH. Mactopus does not install missing tools automatically. The engine
keeps a private HOME and configuration directory; shell startup files, aliases,
personal Codex configuration, and ambient credentials are not imported. Commands
requiring an existing login or configuration may need an explicit path or their
normal authorization flow. No password or API key should be pasted into a task.

## Permissions and running processes

The existing workspace-write sandbox remains enabled. The engine requests
approval when an operation needs it. **Ask every time** presents those engine
requests with the command and working directory; sandbox-permitted commands may
run without a prompt. **Full access** resolves the same requests automatically
under the app's existing rules; it does not remove tool validation or macOS
permissions. CLI support does not authorize bypassing browser, app, or system
access controls.

The model can start a command with `exec_command` and poll or provide input to
its live session with `write_stdin`. These session IDs belong to the current
engine session; history and compacted text do not grant new process authority.
Use **Stop task** to interrupt the task and request cleanup of its background
commands. A cleanup failure is reported as unconfirmed, not as a successful stop.
Normal app quit also requests cleanup. Background commands can outlive a model
turn; use a follow-up task message to manage the returned session when Stop is
no longer shown. An engine cleanup receipt confirms its session inventory, not
the exit of every possible escaped OS descendant.

Command text, output, and exit results become part of the local conversation.
Avoid commands that print credentials or other information you do not want in
the transcript.

## Current limitations

- The model can choose a wrong command or stop before completing a task. Review
  the actual output and exit status; a confident final message is not proof.
- The current compaction patch bounds tool receipts and may clip process-session
  metadata in long output. More than 32 retained calls or a serialized call
  above 1 KiB can fail closed. Do not guess a missing session ID or rerun a
  command merely because its output was compacted.
- A disconnected engine cannot prove that every previously started external
  process terminated. The app reports that uncertainty and avoids unrelated
  process-name or global termination.
- CLI support does not resolve the existing browser search-planning or MLX
  stream/final-consistency issues tracked in [TODO.md](../TODO.md).

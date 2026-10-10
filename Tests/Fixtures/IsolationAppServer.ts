#!/usr/bin/env bun
// Owned transport fixture only: no inference, tools, shell, or desktop actions.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const root = process.env.CODEX_HOME!;
const mode = readFileSync(join(root, "scenario"), "utf8");
const threadId = "isolation-existing-thread";
let turnCount = 0;
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: object) => emit({ method, params: { threadId, ...params } });
const lines = createInterface({ input: process.stdin });
lines.on("line", line => {
  const request = JSON.parse(line);
  if (!Object.hasOwn(request, "id") || !request.method) return;
  appendFileSync(join(root, "requests.jsonl"), JSON.stringify({ method: request.method, params: request.params }) + "\n");
  switch (request.method) {
    case "initialize":
      writeFileSync(join(root, "child.json"), JSON.stringify({
        home: process.env.HOME, codexHome: root, cwd: process.cwd(), path: process.env.PATH,
        environmentKeys: Object.keys(process.env).sort(),
      }));
      result(request.id, { userAgent: "isolation-fixture" });
      break;
    case "thread/list":
      result(request.id, { data: mode === "resume" ? [{
        id: threadId, model, name: "Existing isolated task", cwd: join(root, "PersistedProject"),
        preview: "Prior fixture history", status: { type: "idle" }, updatedAt: 1_790_000_000,
      }] : [], nextCursor: null });
      break;
    case "thread/start":
      result(request.id, { thread: { id: threadId, turns: [] } });
      break;
    case "thread/resume": {
      const turnId = "isolation-prior-turn";
      const usage = { totalTokens: 128, inputTokens: 100, outputTokens: 28, cachedInputTokens: 0, reasoningOutputTokens: 0 };
      notify("thread/tokenUsage/updated", { turnId, tokenUsage: { modelContextWindow: 16_384, last: usage, total: usage } });
      result(request.id, {
        thread: { id: threadId, model, turns: [], status: { type: "idle" } },
        initialTurnsPage: { data: [{ id: turnId, status: "completed", error: null, itemsView: "full", items: [
          { id: "prior-user", type: "userMessage", content: [{ type: "text", text: "PRIOR_FIXTURE_PROMPT" }] },
          { id: "prior-answer", type: "agentMessage", phase: "final_answer", text: "PRIOR_FIXTURE_ANSWER" },
        ] }], nextCursor: null, hasMore: false },
      });
      break;
    }
    case "thread/name/set": result(request.id); break;
    case "turn/start": {
      const turnId = `isolation-turn-${++turnCount}`;
      result(request.id, { turn: { id: turnId, status: "inProgress" } });
      setTimeout(() => {
        notify("turn/started", { turn: { id: turnId, status: "inProgress" } });
        notify("item/completed", { turnId, item: {
          id: "isolation-answer", type: "agentMessage", phase: "final_answer", text: "ISOLATION_TRANSPORT_OK",
        } });
        notify("turn/completed", { turn: { id: turnId, status: "completed", error: null } });
      }, 10);
      break;
    }
    default:
      emit({ id: request.id, error: { code: -32601, message: "Unexpected isolation fixture method: " + request.method } });
  }
});
lines.on("close", () => process.exit(0));

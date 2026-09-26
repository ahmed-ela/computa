#!/Users/ahmedelamin/.bun/bin/bun
// Isolated deterministic transport only; no model or desktop operation.
import { join } from "node:path";
const root = process.env.CODEX_HOME!;
await Bun.write(join(root, "fixture-pid"), String(process.pid));
let input = "";
for await (const chunk of Bun.stdin.stream()) {
  input += new TextDecoder().decode(chunk);
  let newline: number;
  while ((newline = input.indexOf("\n")) >= 0) {
    const message = JSON.parse(input.slice(0, newline));
    input = input.slice(newline + 1);
    if (message.method === "initialize") {
      await Bun.write(join(root, "initialize-received"), "yes");
      const mode = await Bun.file(join(root, "mode")).text();
      if (mode === "reject") {
        process.stdout.write(JSON.stringify({ id: message.id, error: { code: -32600, message: "fixture initialize rejection" } }) + "\n");
      } else if (mode === "reject-structured") {
        process.stdout.write(JSON.stringify({ id: message.id, error: {
          code: -32603, message: "fixture reconciliation required",
          data: { reason: "poisoned", reconcileRequired: true, marker: "preserve-🧭" },
        } }) + "\n");
      }
      // All other modes deliberately keep initialization pending.
    }
  }
}

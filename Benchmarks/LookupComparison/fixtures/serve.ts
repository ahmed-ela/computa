import { join } from "node:path";

// Serve only inert page surfaces. The task manifest and evaluator oracles must
// never become discoverable page content for the model being evaluated.
const pages = new Set([
  "archive.html", "sidebar.html", "toolbar.html", "document.html", "email.html",
  "no-landmarks.html", "long-field.html", "continued-field.html", "virtualized.html",
  "meridian-home.html", "meridian-search.html", "meridian-results.html", "meridian-record.html",
  "lumen-home.html", "lumen-results.html", "lumen-record.html",
]);
const policy = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; base-uri 'none'";

export function fixtureResponse(request: Request): Response {
  if (!["GET", "HEAD"].includes(request.method)) return new Response("Method not allowed", { status: 405 });
  const name = new URL(request.url).pathname.slice(1);
  if (!pages.has(name)) return new Response("Not found", { status: 404 });
  return new Response(request.method === "HEAD" ? null : Bun.file(join(import.meta.dir, name)), {
    headers: {
      "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": policy,
      "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
    },
  });
}

if (import.meta.main) {
  const port = Number(process.argv[2] ?? "8765");
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Port must be an integer from 1024 through 65535.");
  const server = Bun.serve({ hostname: "127.0.0.1", port, fetch: fixtureResponse });
  console.log(`Synthetic lookup fixtures: http://127.0.0.1:${server.port}/archive.html`);
  console.log("Inputs only; no model evaluation has run. Stop this process when finished.");
}

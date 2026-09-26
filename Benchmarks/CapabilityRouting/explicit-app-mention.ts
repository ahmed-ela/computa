// Frozen benchmark-only metadata transform. A literal mention is neither
// intent, target ownership, permission, nor evidence that an action can work.
const annotation = "user_request_mentions_app";
const normalize = (text: string) => text.normalize("NFC").replace(/\s+/gu, " ").trim().toLowerCase();
const stringToken = '"(?:[^"\\\\\\u0000-\\u001f]|\\\\(?:["\\\\/bfnrt]|u[0-9a-fA-F]{4}))*"';
// Native APPS records contain flat JSON values. Unsupported/nested shapes fail
// closed, including duplicate decoded keys that JSON.parse would overwrite.
function parseRow(raw: string): Record<string, unknown> | null {
  const text = raw.trim(); if (!text.startsWith("{") || !text.endsWith("}")) return null;
  const member = new RegExp(`(${stringToken})[ \\t\\r\\n]*:[ \\t\\r\\n]*(${stringToken}|true|false|null|-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)`, "y");
  const value: Record<string, unknown> = Object.create(null); let offset = 1;
  const whitespace = () => { while (/[ \t\r\n]/.test(text[offset] ?? "")) offset++; };
  try {
    whitespace();
    while (offset < text.length - 1) {
      member.lastIndex = offset; const match = member.exec(text); if (!match) return null;
      const key = JSON.parse(match[1]); if (Object.hasOwn(value, key)) return null;
      value[key] = JSON.parse(match[2]); offset = member.lastIndex; whitespace();
      if (offset === text.length - 1) break;
      if (text[offset++] !== ",") return null; whitespace(); if (offset === text.length - 1) return null;
    }
    return offset === text.length - 1 ? value : null;
  } catch { return null; }
}
function mentioned(task: string, label: string): boolean {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // Unicode letters, marks, digits, connectors and format characters continue
  // a word. Hyphens/dotted suffixes also prevent matching a larger identifier;
  // an ordinary final sentence period remains a boundary.
  const word = "\\p{L}\\p{N}\\p{M}\\p{Pc}\\p{Cf}";
  return new RegExp(`(?<![${word}.\\-])${escaped}(?![${word}\\-]|\\.[${word}])`, "u").test(task);
}
export function annotateExplicitAppMention(prompt: string, inventory: string): string {
  if (typeof prompt !== "string" || !prompt || prompt.length > 8192 || typeof inventory !== "string" || inventory.length > 65536) return inventory;
  const lines = inventory.split("\n"), header = lines.shift()!;
  if (!header.startsWith("APPS scope=user_facing ")) return inventory;
  const counts = /^APPS\b[^\r\n]*\bmatched=(\d+) returned=(\d+) omitted=(\d+)\./.exec(header);
  if (!counts) return inventory;
  const trailing = lines.at(-1) === "" ? "\n" : ""; if (trailing) lines.pop();
  const [matched, returned, omitted] = counts.slice(1).map(Number);
  if (![matched, returned, omitted].every(Number.isSafeInteger) || omitted !== 0 || matched !== returned + omitted
      || returned !== lines.length || !lines.length || lines.length > 128) return inventory;
  const names = new Set<string>(), ids = new Set<string>(), matching: number[] = [], task = normalize(prompt);
  for (const [index, raw] of lines.entries()) {
    const row = parseRow(raw);
    if (!row || Object.hasOwn(row, annotation) || typeof row.name !== "string" || row.name.length > 256
        || /[\p{Cc}\p{Cf}]/u.test(row.name) || typeof row.bundle_id !== "string" || row.bundle_id.length > 255
        || !/^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/.test(row.bundle_id)) return inventory;
    const name = normalize(row.name), id = normalize(row.bundle_id);
    if (!name || names.has(name) || ids.has(id)) return inventory;
    names.add(name); ids.add(id);
    if (mentioned(task, name) || mentioned(task, id)) matching.push(index);
  }
  if (matching.length !== 1) return inventory;
  const index = matching[0], raw = lines[index], end = raw.lastIndexOf("}");
  const marked = raw.slice(0, end) + `,"${annotation}":true` + raw.slice(end);
  const output = [header, marked, ...lines.filter((_, i) => i !== index)].join("\n") + trailing;
  return new TextEncoder().encode(output).byteLength <= 3500 ? output : inventory;
}

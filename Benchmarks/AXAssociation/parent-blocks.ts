// Offline representation-only experiment. No acquisition, selection, or inference.
const MAX_RECORDS = 2_000;
const MAX_CHARACTERS = 1_000_000;
const MAX_PARENT_LINKS = 32;
const ID = /^(?:0|[1-9][0-9]*)$/;

type RecordLine = { raw: string; id: number; parent: number | null; stem: string | null };

function parseID(value: string): number | null {
  if (!ID.test(value)) return null;
  const result = Number(value);
  return Number.isSafeInteger(result) ? result : null;
}

// Recognize field boundaries without interpreting quoted labels as metadata.
function fields(line: string): string[] | null {
  const result: string[] = [];
  let start = 0, quoted = false, escaped = false;
  for (let index = 0; index < line.length; index++) {
    const character = line[index];
    if (quoted) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') quoted = false;
    } else if (character === '"') quoted = true;
    else if (character === " ") {
      if (index > start) result.push(line.slice(start, index));
      start = index + 1;
    } else if (character === "\t" || character === "\r") return null;
  }
  if (quoted || escaped) return null;
  if (start < line.length) result.push(line.slice(start));
  return result;
}

function parseHeader(header: string): { root: number; parents: Map<number, number | null> } | null {
  const tokens = fields(header);
  if (!tokens || tokens[0] !== "AXSNAPSHOT") return null;
  const rootFields = tokens.filter(token => token.startsWith("root="));
  const mapFields = tokens.filter(token => token.startsWith("parents="));
  if (rootFields.length !== 1 || mapFields.length !== 1) return null;
  const root = parseID(rootFields[0].slice(5));
  const map = /^parents=\[([^\]]*)\]$/.exec(mapFields[0]);
  if (root === null || !map || !map[1]) return null;
  const entries = map[1].split(",");
  if (entries.length > MAX_RECORDS) return null;
  const parents = new Map<number, number | null>();
  for (const entry of entries) {
    const pair = entry.split(":");
    if (pair.length !== 2) return null;
    const child = parseID(pair[0]);
    const parent = pair[1] === "-" ? null : parseID(pair[1]);
    if (child === null || (pair[1] !== "-" && parent === null) || parents.has(child)) return null;
    parents.set(child, parent);
  }
  if (!parents.has(root) || parents.get(root) !== null) return null;
  return { root, parents };
}

function parseRecord(raw: string): RecordLine | null {
  const prefix = /^#([^ ]+) /.exec(raw);
  const id = prefix ? parseID(prefix[1]) : null;
  const tokens = fields(raw);
  if (id === null || !tokens) return null;
  const suffix = / parent=((?:0|[1-9][0-9]*))$/.exec(raw);
  const parentFields = tokens.filter(token => token.startsWith("parent="));
  const ancestryUnknown = tokens.some(token => token.startsWith("ancestry_unknown=") || token.startsWith("ancestry_truncated="));
  const parent = suffix ? parseID(suffix[1]) : null;
  if (parent === null || parentFields.length !== 1 || ancestryUnknown) {
    return { raw, id, parent: null, stem: null };
  }
  return { raw, id, parent, stem: raw.slice(0, suffix!.index) };
}

function hasValidChain(record: RecordLine, root: number, parents: Map<number, number | null>, duplicates: Set<number>): boolean {
  if (record.parent === null || duplicates.has(record.id) || record.id === root) return false;
  // A record may itself also be an ancestor of another emitted record. Both
  // source representations must agree when its edge occurs in the shared map.
  if (parents.has(record.id) && parents.get(record.id) !== record.parent) return false;
  const seen = new Set([record.id]);
  let cursor = record.parent;
  for (let links = 1; links <= MAX_PARENT_LINKS; links++) {
    if (seen.has(cursor) || duplicates.has(cursor) || !parents.has(cursor)) return false;
    seen.add(cursor);
    if (cursor === root) return parents.get(cursor) === null;
    const parent = parents.get(cursor);
    if (parent === null || parent === undefined) return false;
    cursor = parent;
  }
  return false;
}

function sameRecordMultiset(original: string[], encoded: string[]): boolean {
  const counts = new Map<string, number>();
  for (const record of original) counts.set(record, (counts.get(record) ?? 0) + 1);
  let parent: string | null = null, members = 0, decoded = 0;
  for (const line of encoded) {
    const block = /^parent=((?:0|[1-9][0-9]*)) \{$/.exec(line);
    if (block) {
      if (parent !== null) return false;
      parent = block[1];
      members = 0;
      continue;
    }
    if (line === "}") {
      if (parent === null || members < 2) return false;
      parent = null;
      continue;
    }
    if (!/^#(?:0|[1-9][0-9]*) /.test(line)) return false;
    const record = parent === null ? line : `${line} parent=${parent}`;
    const count = counts.get(record) ?? 0;
    if (!count) return false;
    counts.set(record, count - 1);
    members++;
    decoded++;
  }
  return parent === null && decoded === original.length && [...counts.values()].every(count => count === 0);
}

/**
 * Factor repeated terminal parent=N fields into direct-parent blocks, retaining
 * the original header and all other record bytes. Blocks describe containment,
 * not semantic ownership. No source nodes or facts are added or reselected.
 *
 * Bounds use JS UTF-16 length, conservatively stricter than Swift grapheme count.
 * On ambiguity, expansion, or an output over budget, return the ORIGINAL input;
 * this is deliberately not a truncator, even if that input already exceeds budget.
 */
export function groupAXSnapshotParents(snapshot: string, characterBudget: number): string {
  if (!Number.isSafeInteger(characterBudget) || characterBudget < 1 || snapshot.length > MAX_CHARACTERS) return snapshot;
  const trailingNewline = snapshot.endsWith("\n");
  const lines = (trailingNewline ? snapshot.slice(0, -1) : snapshot).split("\n");
  if (lines.length < 3 || lines.length > MAX_RECORDS + 1) return snapshot;
  const header = parseHeader(lines[0]);
  if (!header) return snapshot;
  const records: RecordLine[] = [];
  const seen = new Set<number>(), duplicates = new Set<number>();
  for (const line of lines.slice(1)) {
    const record = parseRecord(line);
    if (!record) return snapshot;
    if (seen.has(record.id)) duplicates.add(record.id);
    seen.add(record.id);
    records.push(record);
  }
  const groups = new Map<number, RecordLine[]>();
  for (const record of records) {
    if (!hasValidChain(record, header.root, header.parents, duplicates)) continue;
    const parent = record.parent!;
    const members = groups.get(parent) ?? [];
    members.push(record);
    groups.set(parent, members);
  }
  const emitted = new Set<number>();
  const output: string[] = [];
  for (const record of records) {
    const members = record.parent === null ? undefined : groups.get(record.parent);
    // Invalid records sharing the same parent remain verbatim, not block members.
    if (!members || members.length < 2 || !members.includes(record)) {
      output.push(record.raw);
    } else if (!emitted.has(record.parent!)) {
      emitted.add(record.parent!);
      output.push(`parent=${record.parent} {`, ...members.map(member => member.stem!), "}");
    }
  }
  const grouped = [lines[0], ...output].join("\n") + (trailingNewline ? "\n" : "");
  if (grouped.length > snapshot.length || grouped.length > characterBudget || !sameRecordMultiset(lines.slice(1), output)) return snapshot;
  return grouped;
}

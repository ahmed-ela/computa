import { describe, expect, test } from "bun:test";
import { groupAXSnapshotParents } from "./parent-blocks";

const header = (parents = "0:-,1:0,26:1,27:26,31:26", extra = "") =>
  `AXSNAPSHOT id=synthetic pid=4242 app="Google Chrome" bundle="com.google.Chrome" root=0 shown=6 total=35 source_truncated=0 output_truncated=1${extra} parents=[${parents}]`;
const line = (id: number, parent: number | string, body = 'role="AXButton" label="Details" actions=["AXPress"] screen_frame=[950,256,110,28]') =>
  `#${id} ${body} parent=${parent}`;
const snapshot = (records: string[], map?: string) => [header(map), ...records].join("\n");
const transform = (value: string, budget = value.length) => groupAXSnapshotParents(value, budget);

// Independent decoder checks byte preservation, including duplicate multiplicity.
function decode(value: string): string[] {
  let parent: string | null = null;
  const records: string[] = [];
  for (const entry of value.split("\n").slice(1)) {
    if (!entry) continue;
    const match = /^parent=([0-9]+) \{$/.exec(entry);
    if (match) { expect(parent).toBeNull(); parent = match[1]; }
    else if (entry === "}") { expect(parent).not.toBeNull(); parent = null; }
    else records.push(parent === null ? entry : `${entry} parent=${parent}`);
  }
  expect(parent).toBeNull();
  return records;
}
function exactRecords(input: string, output: string) {
  expect(output.split("\n")[0]).toBe(input.split("\n")[0]);
  expect(decode(output).sort()).toEqual(input.split("\n").slice(1).filter(Boolean).sort());
  expect(output.length).toBeLessThanOrEqual(input.length);
}

describe("bounded representation-only AX parent blocks", () => {
  test("groups non-adjacent direct siblings at first occurrence with original member order", () => {
    const records = [line(28, 27), line(0, "-"), line(33, 31), line(29, 27), line(34, 31), line(30, 27)];
    const input = snapshot(records), output = transform(input);
    expect(output).toBe([header(), "parent=27 {", ...[records[0], records[3], records[5]].map(x => x.replace(/ parent=27$/, "")), "}",
      records[1], "parent=31 {", ...[records[2], records[4]].map(x => x.replace(/ parent=31$/, "")), "}"].join("\n"));
    exactRecords(input, output);
  });

  test("the observed initial fixture keeps the omitted A status and B heading omitted", () => {
    const records = [
      line(0, "-", 'role="AXWindow" label="Orders — Google Chrome" actions=[] screen_frame=[0,0,1280,900]'),
      line(1, 0, 'role="AXWebArea" label="Orders" actions=[]'),
      line(28, 27, 'role="AXHeading" label="Order A — USB-C charging cable and accessories for everyday desk use x" actions=[] screen_frame=[200,220,740,26]'),
      line(30, 27),
      line(33, 31, 'role="AXStaticText" label="Delivered Friday" actions=[] screen_frame=[200,456,300,24] sibling_heading=#32:"Order B — USB-C charging cable and accessories for everyday desk use x"'),
      line(34, 31)
    ];
    const input = snapshot(records), output = transform(input);
    expect(output).toContain('sibling_heading=#32:"Order B — USB-C charging cable and accessories for everyday desk use x"\n');
    expect(output).not.toContain("Arrives Tuesday");
    expect(output).not.toMatch(/^#(?:29|32) /m);
    expect(output).toContain("parent=27 {\n#28");
    expect(output).toContain("parent=31 {\n#33");
    exactRecords(input, output);
  });

  test("the targeted fixture retains every fact and cue but does not restore omitted B status", () => {
    const input = snapshot([
      line(28, 27, 'role="AXHeading" label="Order A — USB-C charging cable and accessories for everyday desk use x" actions=[] screen_frame=[200,220,740,26]'),
      line(0, "-", 'role="AXWindow" label="Orders — Google Chrome" actions=[] screen_frame=[0,0,1280,900]'),
      line(29, 27, 'role="AXStaticText" value="Arrives Tuesday" actions=[] screen_frame=[200,256,300,24] sibling_heading=#28:"Order A — USB-C charging cable and accessories for everyday desk use x"'),
      line(30, 27),
      line(32, 31, 'role="AXHeading" label="Order B — USB-C charging cable and accessories for everyday desk use x" actions=[] screen_frame=[200,420,740,26]'),
      line(34, 31)
    ]);
    const output = transform(input);
    expect(output.indexOf("#29 ")).toBeLessThan(output.indexOf("#0 "));
    expect(output).toContain('value="Arrives Tuesday"');
    expect(output).not.toContain("Delivered Friday");
    exactRecords(input, output);
  });

  test("nested ancestors do not merge cousins or singleton records", () => {
    const input = snapshot([line(4, 2), line(7, 3), line(5, 2), line(8, 3), line(2, 1)], "0:-,1:0,2:1,3:1");
    const output = transform(input);
    expect(output).toContain("parent=2 {\n#4");
    expect(output).toContain("parent=3 {\n#7");
    expect(output).toContain(line(2, 1));
    expect(output).not.toContain("parent=1 {");
    exactRecords(input, output);
  });

  test("singletons, missing parents, and unknown or truncated ancestry remain verbatim", () => {
    const unresolved = [line(5, 999), line(6, 999), line(7, "- ancestry_unknown=1"), line(8, "- ancestry_truncated=1"),
      line(9, 27, 'role="AXButton" ancestry_unknown=1'), line(10, 31)];
    const input = snapshot([line(28, 27), ...unresolved, line(29, 27)]), output = transform(input);
    expect(output).toContain("parent=27 {");
    for (const record of unresolved) expect(output).toContain(record);
    exactRecords(input, output);
  });

  test("duplicate emitted IDs and chains through them are not grouped; unrelated valid siblings are", () => {
    const duplicate = line(27, 26);
    const input = snapshot([duplicate, duplicate, line(28, 27), line(29, 27), line(33, 31), line(34, 31)]);
    const output = transform(input);
    expect(output).not.toContain("parent=27 {");
    expect(output).not.toContain("parent=26 {");
    expect(output).toContain("parent=31 {");
    exactRecords(input, output);
  });

  test("duplicate leaf records are retained with exact multiplicity outside valid blocks", () => {
    const duplicate = line(28, 27);
    const input = snapshot([duplicate, duplicate, line(29, 27), line(30, 27)]), output = transform(input);
    expect(decode(output).filter(value => value === duplicate)).toHaveLength(2);
    expect(output.split("parent=27 {")[1]).toStartWith("\n#29 ");
    exactRecords(input, output);
  });

  test("conflicting shared-map edge versus record edge remains ungrouped", () => {
    const records = [line(28, 27), line(29, 27)];
    const input = snapshot(records, "0:-,1:0,26:1,27:26,28:31,31:26");
    expect(transform(input)).toBe(input);
  });

  test("invalid parent maps and root declarations fail closed", () => {
    for (const map of ["", "0:-,27:0,27:0", "0:-,27:0,27:1", "27:0", "0:1,1:0,27:0", "0:-,27:-",
      "0:-,27:28,28:27", "0:-,27:999", "0:-,027:0", "0:-,27:9007199254740992", "0:-,27:0:0"]) {
      const input = snapshot([line(28, 27), line(29, 27)], map);
      expect(transform(input)).toBe(input);
    }
    const input = snapshot([line(28, 27), line(29, 27)]);
    for (const malformed of [input.replace(" root=0 ", " root=0 root=0 "), input.replace(" root=0 ", " root=01 "),
      input.replace(" root=0 ", " "), input.replace(" parents=", " parents=[] parents="), input.replace("AXSNAPSHOT", "OTHER")]) {
      expect(transform(malformed)).toBe(malformed);
    }
  });

  test("cycles including the emitted child and non-root terminal nodes do not establish ancestry", () => {
    for (const map of ["0:-,27:28,28:27", "0:-,27:1,1:-", "0:-,27:28,28:0"]) {
      const input = snapshot([line(28, 27), line(29, 27)], map);
      expect(transform(input)).toBe(input);
    }
  });

  test("exactly 32 parent links are permitted, 33 are not", () => {
    const chain = (depth: number) => ["0:-", ...Array.from({ length: depth }, (_, i) => `${i + 1}:${i}`)].join(",");
    const within = snapshot([line(100, 31), line(101, 31)], chain(31));
    expect(transform(within)).toContain("parent=31 {");
    const beyond = snapshot([line(100, 32), line(101, 32)], chain(32));
    expect(transform(beyond)).toBe(beyond);
  });

  test("quoted metadata-looking text, escaped quotes, URLs, Unicode and fields remain byte-exact", () => {
    const body = 'role="AXStaticText" label="🍀 é 東京 parent=999 { } ancestry_unknown=1 \\"' +
      'quoted\\" \\\\ tail" value="parent=8" actions=["AXPress"] screen_frame=[0,1,2,3] url="https://example.test/?parent=9" ' +
      'sibling_heading=#44:"Heading parent=77 { \\"title\\" }"';
    const input = snapshot([line(28, 27, body), line(29, 27, body)]), output = transform(input);
    expect(output).toContain("parent=27 {");
    expect(output).toContain(body);
    exactRecords(input, output);
  });

  test("only terminal parent fields are factored; ambiguous duplicate metadata remains verbatim", () => {
    const invalid = [line(28, "27 extra=1"), line(29, 27, 'role="AXStaticText" parent=27'), line(30, "027"), line(31, "9007199254740992")];
    const input = snapshot([...invalid, line(33, 31), line(34, 31)]), output = transform(input);
    for (const record of invalid) expect(output).toContain(record);
    exactRecords(input, output);
  });

  test("quoted header text cannot supply or override structural metadata", () => {
    const input = snapshot([line(28, 27), line(29, 27)]).replace('app="Google Chrome"', 'app="root=99 parents=[0:-,27:99] \\"quoted\\""');
    const output = transform(input);
    expect(output).toContain("parent=27 {");
    exactRecords(input, output);
    const missing = input.replace(" root=0 ", " ");
    expect(transform(missing)).toBe(missing);
  });

  test("malformed records, unclosed quotations, extra lines and unsafe IDs fail closed", () => {
    const input = snapshot([line(28, 27), line(29, 27)]);
    for (const malformed of [input.replace("#28 ", "#028 "), input.replace("#28 ", "#9007199254740992 "),
      input.replace('label="Details"', 'label="Details'), `${input}\nunknown`, `${input}\n\n`, input.replace("#28 ", "#28\t"),
      input.replace(" parent=27", "\r parent=27")]) {
      expect(transform(malformed)).toBe(malformed);
    }
  });

  test("the supplied size bound is strict and never causes partial records or truncation", () => {
    const input = snapshot([line(28, 27), line(29, 27)]), output = transform(input);
    expect(output).not.toBe(input);
    expect(transform(input, output.length)).toBe(output);
    expect(transform(input, output.length - 1)).toBe(input);
    for (const budget of [0, -1, NaN, Infinity, 1.5]) expect(transform(input, budget)).toBe(input);
    exactRecords(input, output);
  });

  test("optional final newline is preserved and counts toward budget", () => {
    const input = snapshot([line(28, 27), line(29, 27)]) + "\n", output = transform(input);
    expect(output).toEndWith("}\n");
    expect(transform(input, output.length - 1)).toBe(input);
    exactRecords(input, output);
  });

  test("no grouping, no parent map, already grouped or empty input returns unchanged", () => {
    const input = snapshot([line(28, 27), line(33, 31)]);
    for (const value of ["", header(), input, input.replace(/ parents=\[[^\]]*\]/, "")]) expect(transform(value)).toBe(value);
    const grouped = transform(snapshot([line(28, 27), line(29, 27)]));
    expect(transform(grouped)).toBe(grouped);
  });

  test("record and map limits fail closed before unbounded processing", () => {
    const records = Array.from({ length: 2_000 }, (_, i) => line(i + 100, 27));
    const accepted = snapshot(records);
    expect(transform(accepted)).toContain("parent=27 {");
    const tooMany = snapshot([...records, line(2100, 27)]);
    expect(transform(tooMany)).toBe(tooMany);
    const map = ["0:-", ...Array.from({ length: 2_000 }, (_, i) => `${i + 1}:0`)].join(",");
    const tooManyParents = snapshot([line(2100, 27), line(2101, 27)], map);
    expect(transform(tooManyParents)).toBe(tooManyParents);
    const huge = snapshot([line(28, 27, `label="${"x".repeat(1_000_000)}"`), line(29, 27)]);
    expect(transform(huge)).toBe(huge);
  });
});

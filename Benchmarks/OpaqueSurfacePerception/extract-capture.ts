// Reads original tool receipts only, never reasoning/compaction summaries.
// Selected pixels/AX stay in a new private temp directory, never in this repo.
import { createReadStream } from "node:fs";
import { chmod, lstat, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { isAbsolute, relative, resolve } from "node:path";
import { receiptText } from "./receipt-text";
const [rollout, captureID, outputDirectory] = Bun.argv.slice(2);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
if (!isAbsolute(rollout ?? "") || !isAbsolute(outputDirectory ?? "") || !uuid.test(captureID ?? "")) {
  throw new Error("Usage: bun extract-capture.ts ABS_ROLLOUT CAPTURE_UUID EXISTING_EMPTY_PRIVATE_TEMP_DIR");
}
const root = resolve(import.meta.dir, "../..");
const output = await realpath(outputDirectory);
if (!relative(root, output).startsWith("..") || !(await lstat(outputDirectory)).isDirectory()
    || (await readdir(output)).length !== 0 || !output.startsWith("/private/tmp/")) {
  throw new Error("Output must be an empty real private /tmp directory outside the repository");
}
await chmod(output, 0o700);
if ((await stat(rollout)).size > 64 * 1024 * 1024) throw new Error("Rollout exceeds bounded extraction size");
type Receipt = { call_id: string; timestamp: string; text: string };
const calls = new Map<string, string>();
let precedingAX: Receipt | null = null;
let selected: { png: Buffer; metadata: string; timestamp: string; call_id: string; ax: Receipt | null; synchronized: boolean } | null = null;
let matches = 0;
for await (const line of createInterface({ input: createReadStream(rollout), crlfDelay: Infinity })) {
  if (!line.trim()) continue;
  const row = JSON.parse(line);
  if (row.type !== "response_item") continue;
  const p = row.payload;
  if (p?.type === "function_call" && typeof p.call_id === "string" && typeof p.name === "string") {
    calls.set(p.call_id, p.name);
    if (p.name === "computer_v2_open") precedingAX = null;
    continue;
  }
  if (p?.type !== "function_call_output") continue;
  const name = calls.get(p.call_id);
  const text = receiptText(p.output);
  if (text === null) continue;
  if (name === "computer_v2_snapshot" && text.startsWith("AXSNAPSHOT id=")) {
    precedingAX = { call_id: p.call_id, timestamp: row.timestamp, text };
  }
  if (name !== "computer_v2_capture" || !text.startsWith(`WINDOW_CAPTURE capture_id=${captureID}\n`)) continue;
  matches += 1;
  if (!Array.isArray(p.output)) throw new Error("Selected capture is not image-bearing content");
  const images = p.output.filter((c: any) => c?.type === "input_image");
  if (images.length !== 1 || typeof images[0].image_url !== "string"
      || !/^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(images[0].image_url)) throw new Error("Expected one original PNG receipt");
  const png = Buffer.from(images[0].image_url.split(",")[1], "base64");
  if (png.length > 32 * 1024 * 1024 || !png.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) {
    throw new Error("Invalid bounded PNG");
  }
  const syncedIndex = text.indexOf("SYNCHRONIZED_AX ");
  const axIndex = syncedIndex < 0 ? -1 : text.indexOf("AXSNAPSHOT id=", syncedIndex);
  selected = { png, metadata: text, timestamp: row.timestamp, call_id: p.call_id,
    ax: axIndex < 0 ? precedingAX : { call_id: p.call_id, timestamp: row.timestamp, text: text.slice(axIndex) },
    synchronized: axIndex >= 0 };
}
if (matches !== 1 || !selected) throw new Error("Require exactly one original selected capture receipt");
const width = selected.png.readUInt32BE(16), height = selected.png.readUInt32BE(20);
const declared = selected.metadata.match(/image_width=(\d+) image_height=(\d+)/);
if (!declared || Number(declared[1]) !== width || Number(declared[2]) !== height) throw new Error("Image/metadata dimensions differ");
const source = { capture_id: captureID, image_sha256: new Bun.CryptoHasher("sha256").update(selected.png).digest("hex"), width, height };
const evidence = { source, capture_timestamp: selected.timestamp, capture_call_id: selected.call_id,
  capture_metadata: selected.metadata, native_ax: selected.ax,
  ax_selection: selected.synchronized ? "same_capture" : "latest_preceding_standalone_snapshot_since_open",
  ax_relationship: selected.ax ? selected.synchronized ? "synchronized_same_capture" : "preceding_snapshot_not_synchronized" : "unavailable",
  ax_age_ms: selected.ax ? Date.parse(selected.timestamp) - Date.parse(selected.ax.timestamp) : null,
  notice: "Private original tool observation; no reasoning or model summary included. OCR is not ground truth or input permission." };
for (const [name, bytes] of [["capture.png", selected.png], ["source.json", JSON.stringify(source, null, 2)],
  ["observation.json", JSON.stringify(evidence, null, 2)]] as const) {
  await writeFile(`${output}/${name}`, bytes, { flag: "wx", mode: 0o600 });
}
console.log(JSON.stringify({ output, image_sha256: source.image_sha256, width, height,
  ax_relationship: evidence.ax_relationship, ax_age_ms: evidence.ax_age_ms }));

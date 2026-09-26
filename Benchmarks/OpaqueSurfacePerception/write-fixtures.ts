import { chmod, readdir, realpath, writeFile } from "node:fs/promises";
import { fixtures, expectedCaseCount, syntheticQuestion } from "./fixtures";
const output = Bun.argv[2];
if (!output?.startsWith("/")) throw new Error("Pass an existing empty private temp directory");
const path = await realpath(output);
if (!path.startsWith("/private/tmp/") || (await readdir(path)).length) throw new Error("Use an empty private temp directory");
await chmod(path, 0o700);
if (fixtures.length !== 6 || new Set(fixtures.map(f => f.id)).size !== 6) throw new Error("Frozen fixture count changed");
await writeFile(`${path}/fixtures.json`, JSON.stringify(fixtures, null, 2), { flag: "wx", mode: 0o600 });
await writeFile(`${path}/manifest.json`, JSON.stringify({ version: 1, total_case_count: expectedCaseCount,
  scope: "six synthetic perception classifications plus one private original capture; not an end-to-end computer-use gate",
  renderer: "Benchmarks/EvidenceAssociation/render.swift", question: syntheticQuestion,
  fixture_ids: fixtures.map(f => f.id), source_sha256: new Bun.CryptoHasher("sha256").update(await Bun.file(`${import.meta.dir}/fixtures.ts`).arrayBuffer()).digest("hex"),
  cases: fixtures.map(f => ({ id: f.id, imagePath: `${path}/${f.id}.png`, hostAX: f.hostAX,
    group: "synthetic", expected: f.expected, question: syntheticQuestion })),
  oracles: fixtures.map(({ id, expected }) => ({ id, expected })) }, null, 2), { flag: "wx", mode: 0o600 });
console.log(JSON.stringify({ output: path, synthetic_count: fixtures.length, total_case_count: expectedCaseCount }));

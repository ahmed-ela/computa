// Paired synthetic summary -> continuation probe; never executes a tool or desktop action.
import { readFileSync, writeFileSync, renameSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, isAbsolute } from "node:path";
import { makeEvidenceAssociationFixtures } from "./fixtures";
import { arms, association, checkpoint, type Arm } from "./prompts";
import { scoreAnswer } from "./score";
import { makePoisonedMemoryCheckpoint } from "./poisoned-memory";

const [split, root, imageRoot, captureRoot, selection = arms.join(","), mode = "pipeline"] = Bun.argv.slice(2);
if (!["pipeline", "corrupt"].includes(mode)) throw new Error("Invalid mode");
if (!["development", "holdout"].includes(split) || ![root,imageRoot,captureRoot].every(p => p && isAbsolute(p))) throw new Error("Usage: run.ts development|holdout OUTPUT IMAGE_ROOT CAPTURE_ROOT [arms]");
if ((statSync(root).mode & 0o077) !== 0) throw new Error("Private output directory required");
const selected = selection.split(",") as Arm[];
if (!selected.length || new Set(selected).size !== selected.length || selected.some(a => !arms.includes(a))) throw new Error("Invalid arms");
if (mode === "corrupt" && selected.includes("checkpoint")) throw new Error("A checkpoint-generation candidate cannot use fixed corrupted memory");
const hash = (value: string | Uint8Array) => createHash("sha256").update(value).digest("hex");
const policy = readFileSync("/Users/ahmedelamin/AGENTS.md", "utf8");
const source = readFileSync("Sources/Mactopus/Runtime/CodexAppServerRuntime.swift", "utf8");
const base = source.match(/baseInstructions: """\n([\s\S]*?)\n\s*""",\n\s*reasoningEffort:/)?.[1]?.split("\n").map(l => l.trim()).join("\n");
if (!base) throw new Error("Cannot recover production base instructions");
const raw = readFileSync(join(captureRoot, "connection-03.client-to-upstream.bin"));
const end = raw.indexOf("\r\n\r\n");
const header = raw.subarray(0,end).toString();
if (end < 0 || /transfer-encoding:/i.test(header) || !header.startsWith("POST /v1/responses HTTP/1.1\r\n") || Number(header.match(/content-length:\s*(\d+)/i)?.[1]) !== raw.length-end-4) throw new Error("Invalid captured request");
const template = JSON.parse(raw.subarray(end+4).toString());
if (!template.instructions.startsWith(base + "\n") || template.tools.length !== 13) throw new Error("Captured production instructions changed; refresh template");
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
if (template.model !== model) throw new Error("Wrong model");
const baselineCompact = readFileSync(".build/runtime/codex-source/codex-rs/prompts/templates/compact/prompt.md", "utf8");
const summaryPrefix = readFileSync(".build/runtime/codex-source/codex-rs/prompts/templates/compact/summary_prefix.md", "utf8");
const allCases = makeEvidenceAssociationFixtures().filter(f => f.split === split);
if (allCases.length !== (split === "development" ? 4 : 8)) throw new Error("Unexpected frozen fixture count");
const cases = mode === "corrupt" ? allCases.filter(f => makePoisonedMemoryCheckpoint(f) !== null) : allCases;
if (!cases.length) throw new Error("No cases");
const rows: any[] = [];
let attemptedRequests = 0;
let state = "running", failure: string | null = null;
function save() {
  const value = { scope:mode === "pipeline" ? "synthetic two-stage Responses replay, not App Server or desktop acceptance" : "fixed corrupted-memory recovery stress probe; not a generated summary or untouched holdout", mode, model, split, state, failure,
    instructionSHA256:hash(template.instructions), policySHA256:hash(policy),
    captureSHA256:hash(raw), toolsSHA256:hash(JSON.stringify(template.tools)),
    candidateSHA256: {association:hash(association),checkpoint:hash(checkpoint)},
    fixtureSHA256:hash(JSON.stringify(cases)), plannedLanes:cases.length*selected.length, attemptedRequests,
    differencesFromProduction:["synthetic screenshot and AX text", "constructed summary and receipt context", "temperature=0.1", "max_output_tokens=2048 per stage", "stream=false", "JSON answer requirement", "no tool execution"], rows };
  const tmp = join(root,"summary.json.tmp");
  writeFileSync(tmp, JSON.stringify(value,null,2),{mode:0o600}); renameSync(tmp,join(root,"summary.json"));
}
async function requireIdle() {
  const child = Bun.spawn(["/Users/ahmedelamin/.lmstudio/bin/lms","ps","--json"],{stdout:"pipe",stderr:"pipe"});
  const models = JSON.parse(await new Response(child.stdout).text());
  if (await child.exited !== 0 || models.length !== 1 || models[0].identifier !== model || models[0].status !== "idle" || models[0].queued !== 0 || models[0].parallel !== 1) throw new Error("Sole serial model is not idle; stopping without interference");
}
const message = (text:string) => ({type:"message",role:"user",content:[{type:"input_text",text}]});
async function infer(request:any, id:string, stage:string) {
  await requireIdle(); const started = performance.now();
  attemptedRequests++; save();
  const response = await fetch("http://127.0.0.1:1234/v1/responses",{method:"POST",redirect:"error",headers:{"content-type":"application/json"},body:JSON.stringify(request),signal:AbortSignal.timeout(60000)});
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const result:any = await response.json();
  writeFileSync(join(root,`${id}-${stage}.json`),JSON.stringify({request,response:result}),{mode:0o600});
  if (result.error || result.model !== model || !Array.isArray(result.output)) throw new Error("Invalid model response");
  const calls = result.output.filter((i:any) => i.type === "function_call");
  const text = result.output.filter((i:any) => i.type === "message" && i.role === "assistant").flatMap((i:any)=>i.content??[]).filter((i:any)=>i.type==="output_text").map((i:any)=>i.text).join("").trim();
  return {text,calls:calls.map((i:any)=>({name:i.name,arguments:i.arguments})),status:result.status,incomplete_details:result.incomplete_details??null,elapsed_ms:performance.now()-started,usage:result.usage};
}
try {
  save();
  for (let c = 0; c < cases.length; c++) {
    const fixture = cases[c];
    // Counterbalance warm/cache order, frozen before inspecting any result.
    const order = selected.map((_,i)=>selected[(i+c)%selected.length]);
    const png = readFileSync(join(imageRoot,fixture.id+".png"));
    if (png.length > 2*1024*1024 || png.subarray(0,8).toString("hex") !== "89504e470d0a1a0a") throw new Error("Invalid bounded PNG");
    const receipt = [{type:"function_call",call_id:"call_synthetic_capture",name:"computer_v2_capture",arguments:'{"include_accessibility":true}'},
      {type:"function_call_output",call_id:"call_synthetic_capture",output:[{type:"input_text",text:fixture.ax},{type:"input_image",image_url:`data:image/png;base64,${png.toString("base64")}`}]}];
    const original = [message(policy),message(fixture.prompt)];
    const prior: any[] = [];
    if (fixture.priorObservation) {
      const previousPNG = readFileSync(join(imageRoot,fixture.id+"-prior.png"));
      if (previousPNG.length > 2*1024*1024 || previousPNG.subarray(0,8).toString("hex") !== "89504e470d0a1a0a") throw new Error("Invalid prior PNG");
      prior.push({type:"function_call",call_id:"call_synthetic_prior",name:"computer_v2_capture",arguments:'{"include_accessibility":true}'},
        {type:"function_call_output",call_id:"call_synthetic_prior",output:[{type:"input_text",text:fixture.priorObservation.ax},{type:"input_image",image_url:`data:image/png;base64,${previousPNG.toString("base64")}`} ]});
    }
    for (const arm of order) {
      const id = fixture.id+"-"+arm;
      const row:any = {id,arm,case:fixture.id,tags:fixture.tags,expected:fixture.expected,pngSHA256:hash(png),state:"running"}; rows.push(row); save();
      const instructions = template.instructions + (arm === "association" ? "\n"+association : "");
      const common = {model,instructions,stream:false,temperature:0.1,max_output_tokens:2048};
      row.summary = mode === "corrupt" ? {text:makePoisonedMemoryCheckpoint(fixture),calls:[],status:"completed",elapsed_ms:0,syntheticCorruption:true}
        : await infer({...common,input:[...original,...prior,...receipt,message(arm === "checkpoint" ? checkpoint : baselineCompact)],tools:[]},id,"summary"); save();
      if (row.summary.status !== "completed" || !row.summary.text || row.summary.calls.length) {row.state="summary_incomplete"; row.elapsed_ms=row.summary.elapsed_ms; save();continue;}
      const retainedPrior = fixture.priorObservation ? [prior[0],{...prior[1],output:[{type:"input_text",text:fixture.priorObservation.ax},{type:"input_text",text:"[Earlier image omitted during local compaction; newest eligible capture retained.]"}]}] : [];
      row.final = await infer({...common,input:[...original,message(summaryPrefix+"\n"+row.summary.text),...retainedPrior,...receipt],tools:template.tools},id,"final");
      row.score = scoreAnswer(row.final.text,fixture.expected);
      row.state = row.final.status !== "completed" ? "incomplete" : row.final.calls.length ? "tool_requested_not_executed" : "answered";
      if (row.state !== "answered") row.score.exact = false;
      row.elapsed_ms = row.summary.elapsed_ms+row.final.elapsed_ms;
      save(); console.log(JSON.stringify({id,state:row.state,score:row.score,elapsed_ms:row.elapsed_ms,answer:row.final.text}));
    }
  }
  state="completed";
} catch(error) { state="stopped"; failure=error instanceof Error?error.message:String(error); throw error; }
finally {save();}

// Private, offline replay of an already-recorded failure. No browser or action
// dispatch. Never print prompt, screenshot, private page text or answer bodies.
import {readFileSync,writeFileSync,renameSync,statSync,readdirSync} from "node:fs";
import {join,isAbsolute} from "node:path";
import {createHash} from "node:crypto";
import {association} from "./prompts";
const regressionArms=["baseline","association"] as const;
const [rollout,captureRoot,root,selection=regressionArms.join(",")]=Bun.argv.slice(2);
const selected=selection.split(",");
if(!selected.length||new Set(selected).size!==selected.length||selected.some(a=>!regressionArms.includes(a as typeof regressionArms[number])))throw new Error("Invalid arms");
if (![rollout,captureRoot,root].every(p=>p&&isAbsolute(p)) || (statSync(root).mode&0o077)!==0) throw new Error("Supply rollout, synthetic capture root, private output directory");
const hash=(s:string|Uint8Array)=>createHash("sha256").update(s).digest("hex");
const bytes=readFileSync(rollout), records=bytes.toString().trim().split("\n").map(JSON.parse);
const compact=records.filter(r=>r.type==="compacted");
if(compact.length!==1)throw new Error("Requires exactly one recorded compaction");
const checkpointRecord=compact[0].payload;
const raw=readFileSync(join(captureRoot,"connection-03.client-to-upstream.bin"));
const boundary=raw.indexOf("\r\n\r\n"),header=raw.subarray(0,boundary).toString();
if(boundary<0||/transfer-encoding:/i.test(header)||Number(header.match(/content-length:\s*(\d+)/i)?.[1])!==raw.length-boundary-4)throw new Error("Invalid template");
const template=JSON.parse(raw.subarray(boundary+4).toString());
const model="lmstudio-community/Qwen3.5-4B-MLX-4bit";
if(template.model!==model||template.tools.length!==13)throw new Error("Unexpected template");
const baseline=readFileSync(".build/runtime/codex-source/codex-rs/prompts/templates/compact/prompt.md","utf8");
const prefix=readFileSync(".build/runtime/codex-source/codex-rs/prompts/templates/compact/summary_prefix.md","utf8");
// Replay only public message/tool fields, stripping internal metadata.
// Filtering reasoning items is an explicit experimental difference: the
// production external-provider projection does not itself remove reasoning.
function project(items:any[]) {return items.filter(i=>["message","function_call","function_call_output"].includes(i.type)).map(i=>{
  if(i.type==="message")return{type:i.type,role:i.role,content:i.content};
  if(i.type==="function_call")return{type:i.type,call_id:i.call_id,name:i.name,arguments:i.arguments};
  return{type:i.type,call_id:i.call_id,output:i.output};
});}
const guardian=checkpointRecord.guardian_history, replacement=checkpointRecord.replacement_history;
if(!Array.isArray(guardian)||!Array.isArray(replacement)||typeof checkpointRecord.message!=="string"
  ||!checkpointRecord.message.startsWith(prefix+"\n"))throw new Error("Invalid compaction checkpoint shape");
const oldSummary=checkpointRecord.message.slice((prefix+"\n").length);
if(!oldSummary.trim())throw new Error("Recorded summary is empty");
const textParts=(item:any):string[]=>item.type==="message"&&Array.isArray(item.content)
  ?item.content.filter((c:any)=>["input_text","output_text"].includes(c.type)&&typeof c.text==="string").map((c:any)=>c.text):[];
const hasOldSummary=(items:any[])=>items.some(i=>textParts(i).some(t=>t.includes(oldSummary)||t.includes(prefix)));
// Guardian history is a persisted reconstruction, NOT the original model wire.
// It also contains the summarizer's own final output. Remove only the unique,
// trailing assistant item with both exact summary bytes and summary provenance.
const summaryItems=guardian.map((item:any,index:number)=>({item,index})).filter(({item}:any)=>
  item.internal_chat_message_metadata_passthrough?.content_item_kinds?.includes("compaction.summary"));
if(summaryItems.length!==1)throw new Error("Ambiguous recorded summary provenance");
const recordedSummary=summaryItems[0];
if(recordedSummary.index!==guardian.length-1||recordedSummary.item.type!=="message"
  ||recordedSummary.item.role!=="assistant"||recordedSummary.item.content?.length!==1
  ||recordedSummary.item.content[0].type!=="output_text"||recordedSummary.item.content[0].text!==oldSummary
  ||JSON.stringify(recordedSummary.item.internal_chat_message_metadata_passthrough.content_item_kinds)!=='["compaction.summary"]')throw new Error("Recorded summary identity mismatch");
const prior=guardian.slice(0,recordedSummary.index);
if(hasOldSummary(prior))throw new Error("Old summary remains in replay history");
const next=project(replacement);
const summaryIndices=next.map((i,n)=>i.type==="message"&&i.role==="user"&&textParts(i).some(t=>t.startsWith(prefix+"\n"))?n:-1).filter(n=>n>=0);
if(summaryIndices.length!==1||next[summaryIndices[0]].content.length!==1
  ||next[summaryIndices[0]].content[0].text!==checkpointRecord.message)throw new Error("Replacement summary identity mismatch");
const policy=readFileSync("/Users/ahmedelamin/AGENTS.md","utf8");
if(!policy.length)throw new Error("Inherited policy missing");
const policyMessages=next.filter(i=>i.type==="message"&&i.role==="user"&&textParts(i).some(t=>t.includes(policy)));
if(policyMessages.length!==1||hasOldSummary(policyMessages))throw new Error("Inherited policy identity mismatch");
const priorProjected=project(prior);
if(priorProjected.some(i=>textParts(i).some(t=>t.includes(policy))))throw new Error("Unexpected duplicate inherited policy");
const originalQuestions=priorProjected.filter(i=>i.type==="message"&&i.role==="user");
const retainedQuestions=next.filter((i,n)=>i.type==="message"&&i.role==="user"&&n!==summaryIndices[0]&&!policyMessages.includes(i));
if(originalQuestions.length!==1||retainedQuestions.length!==1
  ||JSON.stringify(originalQuestions)!==JSON.stringify(retainedQuestions))throw new Error("Original user question changed");
const history=[policyMessages[0],...priorProjected];
const calls=(items:any[])=>items.filter(i=>i.type==="function_call");
const outputs=(items:any[])=>items.filter(i=>i.type==="function_call_output");
function validPairs(items:any[]){
  const pending=new Set<string>(),completed=new Set<string>();
  for(const i of items){if(i.type==="function_call"){
    if(typeof i.call_id!=="string"||!i.call_id||pending.has(i.call_id)||completed.has(i.call_id))return false;
    pending.add(i.call_id);
  }else if(i.type==="function_call_output"){
    if(!pending.delete(i.call_id)||completed.has(i.call_id))return false;completed.add(i.call_id);
  }}return pending.size===0&&completed.size===13;
}
const images=(items:any[])=>outputs(items).flatMap(i=>Array.isArray(i.output)?i.output:[])
  .filter(c=>c.type==="input_image").map(c=>c.image_url);
if(!validPairs(history)||!validPairs(next)||JSON.stringify(calls(history))!==JSON.stringify(calls(next))
  ||images(history).length!==1||JSON.stringify(images(history))!==JSON.stringify(images(next)))throw new Error("Recorded receipt identity mismatch");
const unchangedItems=next.filter((_,index)=>index!==summaryIndices[0]);
if(hasOldSummary(history)||hasOldSummary(unchangedItems))throw new Error("Old summary contamination");
const preflight={removedOriginalSummaryCount:1,oldSummaryAbsent:true,originalUserQuestionExact:true,inheritedPolicyExact:true,
  inheritedPolicySHA256:hash(policy),filteredReasoningCount:prior.filter(i=>i.type==="reasoning").length,
  retainedCallCount:calls(next).length,retainedOutputCount:outputs(next).length,retainedImageCount:images(next).length,
  retainedReceiptsSHA256:hash(JSON.stringify(next.filter(i=>i.type==="function_call"||i.type==="function_call_output")))};
if(process.env.HEYDASH_REGRESSION_VERIFY_ONLY==="1"){console.log(JSON.stringify(preflight));process.exit(0);}
if(readdirSync(root).length!==0)throw new Error("Fresh empty private output directory required");
const rows:any[]=[];let state="running",failure:string|null=null;
function save(){const temp=join(root,"summary.json.tmp");writeFileSync(temp,JSON.stringify({scope:"recorded-regression model replay; no tool execution; manual blinded claim audit required",state,failure,rolloutSHA256:hash(bytes),instructionSHA256:hash(template.instructions),toolsSHA256:hash(JSON.stringify(template.tools)),preflight,
  differencesFromProduction:["reconstructed guardian history, not original model wire","recorded summary removed by exact bytes and provenance","reasoning items omitted","exact retained policy message prepended for summary sampling","temperature=0.1","max_output_tokens=2048 per stage","stream=false","no tool execution"],rows},null,2),{mode:0o600});renameSync(temp,join(root,"summary.json"));}
async function infer(request:any,arm:string,stage:string){
  const p=Bun.spawn(["/Users/ahmedelamin/.lmstudio/bin/lms","ps","--json"],{stdout:"pipe",stderr:"pipe"});
  const list=JSON.parse(await new Response(p.stdout).text());
  if(await p.exited!==0||list.length!==1||list[0].identifier!==model||list[0].status!=="idle"||list[0].queued!==0||list[0].parallel!==1)throw new Error("Model not exclusively idle");
  const started=performance.now();
  const response=await fetch("http://127.0.0.1:1234/v1/responses",{method:"POST",redirect:"error",headers:{"content-type":"application/json"},body:JSON.stringify(request),signal:AbortSignal.timeout(60000)});
  if(!response.ok)throw new Error(`HTTP ${response.status}`);const result:any=await response.json();
  writeFileSync(join(root,`${arm}-${stage}.json`),JSON.stringify({request,response:result}),{mode:0o600});
  if(result.error||!Array.isArray(result.output)||result.model!==model)throw new Error("Malformed response");
  const text=result.output.filter((i:any)=>i.type==="message"&&i.role==="assistant").flatMap((i:any)=>i.content??[]).filter((i:any)=>i.type==="output_text").map((i:any)=>i.text).join("").trim();
  return {text,metrics:{status:result.status,elapsed_ms:performance.now()-started,usage:result.usage,incomplete_details:result.incomplete_details??null,toolRequests:result.output.filter((i:any)=>i.type==="function_call").map((i:any)=>i.name),finalTextBytes:Buffer.byteLength(text)}};
}
try{save();for(const arm of selected){
  const common={model,instructions:template.instructions+(arm==="association"?"\n"+association:""),stream:false,temperature:0.1,max_output_tokens:2048};
  const row:any={arm,state:"running"};rows.push(row);save();
  const summary=await infer({...common,tools:[],input:[...history,{type:"message",role:"user",content:[{type:"input_text",text:baseline}]}]},arm,"summary");
  row.summary=summary.metrics;save();
  if(summary.metrics.status!=="completed"||!summary.text||summary.metrics.toolRequests.length){row.state="summary_incomplete";row.elapsed_ms=summary.metrics.elapsed_ms;save();continue;}
  const continuation=structuredClone(next);continuation[summaryIndices[0]].content=[{type:"input_text",text:prefix+"\n"+summary.text}];
  if(JSON.stringify(continuation.filter((_,index)=>index!==summaryIndices[0]))!==JSON.stringify(unchangedItems))throw new Error("Continuation altered retained evidence");
  const final=await infer({...common,tools:template.tools,input:continuation},arm,"final");row.final=final.metrics;row.state=final.metrics.status!=="completed"?"incomplete":final.metrics.toolRequests.length?"tool_requested_not_executed":"answered";row.elapsed_ms=summary.metrics.elapsed_ms+final.metrics.elapsed_ms;save();console.log(JSON.stringify(row));
}state="completed";}catch(error){state="stopped";failure=String(error);throw error;}finally{save();}

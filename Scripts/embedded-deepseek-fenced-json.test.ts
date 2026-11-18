import {describe,expect,test} from 'bun:test';
import {fixture,raw,prompt,mode,fingerprint} from './embedded-deepseek-adapter-fixture';
function fence(f:ReturnType<typeof fixture>,source=raw){
 const n=(tag:string,attrs:Record<string,string>={},text='')=>new f.Node(tag,attrs,text);
 const block=n('DIV',{class:'md-code-block md-code-block-light'}),header=n('DIV',{class:'md-code-block-banner-wrap'});
 const language=n('SPAN',{class:'d813de27'},'json'),controls=['Copy','Download'].map(label=>{const control=n('DIV',{role:'button',tabindex:'0'});control.append(n('SPAN',{class:'code-info-button-text'},label));return control;});
 header.append(language,...controls);const pre=n('PRE'),literal=n('SPAN');
 literal.append(n('SPAN',{class:'token punctuation'},source[0]||''),n('SPAN',{class:'token string'},source.slice(1,-1)),n('SPAN',{class:'token punctuation'},source.length>1?source.slice(-1):''));pre.append(literal);
 const corners=['_33882ae','_28d7e84'].map(cls=>{const svg=n('SVG',{class:'_9bc997d '+cls});svg.append(n('PATH'));return svg;});
 block.append(header,pre,...corners);f.final.replaceChildren(block);return {block,header,language,controls,pre,literal,corners,n};
}
const observed=(f:ReturnType<typeof fixture>)=>f.read().rawAnswer(f.read().transcript().answer);
describe('DeepSeek one observed JSON fence',()=>{
 test('whole PRE bytes preserve syntax spans, escaped arguments and surrounding whitespace',()=>{
  const source='\n{\n  "type":"tool_calls",\n  "calls":[{"name":"exec_command","arguments":{"cmd":"printf \\\"quoted\\\"\\nnext\\tline","workdir":"/tmp/synthetic"}}]\n}\n';
  const f=fixture(),b=fence(f,source);const before=f.mutations();
  Object.defineProperty(b.pre,'childNodes',{get:()=>[{nodeType:3,textContent:' \t\n'},b.literal,{nodeType:3,textContent:'\r\n '}]});
  Object.defineProperty(b.pre,'textContent',{get:()=>' \t\n'+b.literal.textContent+'\r\n '});
  expect(observed(f)).toEqual({text:' \t\n'+source+'\r\n ',finalMarkup:true,formatIssue:false});expect(f.mutations()).toBe(before);
  expect(JSON.parse(observed(f).text).calls[0].arguments.cmd).toBe('printf "quoted"\nnext\tline');
 });
 test('all known JSON token classes preserve complete literal text, not token concatenation or repair',()=>{
  const f=fixture(),b=fence(f);b.literal.replaceChildren();
  const pieces=[['punctuation','{'],['property','"ok"'],['operator',':'],['boolean','true'],['punctuation',','],['property','"n"'],['operator',':'],['number','2'],['punctuation',','],['property','"nil"'],['operator',':'],['null','null'],['punctuation','}']];
  pieces.forEach(([cls,text])=>b.literal.append(b.n('SPAN',{class:'token '+cls},text)));const source=pieces.map(x=>x[1]).join('');expect(observed(f).text).toBe(source);
  b.literal.replaceChildren(b.n('SPAN',{},'{"type":"message","text":'));expect(observed(f)).toEqual({text:'{"type":"message","text":',finalMarkup:true,formatIssue:false});expect(()=>JSON.parse(observed(f).text)).toThrow();
 });
 test('extra prose, duplicate blocks, hidden or interactive source and unknown syntax remain rejected',()=>{
  for(const kind of ['prose','root_text','multiple','language','hidden','anchor','role','tabindex','editable','ariahidden','syntax','script','prehidden','prerole','preeditable','pretabindex','nonwhitespace','wrongcorners','extra_control','blockrole','finaleditable','spanonclick','preonkeydown']){
   const f=fixture(),b=fence(f),first=b.literal.children[0];
   if(kind==='prose')f.final.append(b.n('P',{},'PRIVATE_PROSE'));
   if(kind==='root_text')f.final.text='PRIVATE_PROSE';
   if(kind==='multiple')f.final.append(b.block.cloneNode(true));
   if(kind==='language')b.language.text='javascript';
   if(kind==='hidden')first.values.hidden='';
   if(kind==='anchor')b.literal.append(b.n('A',{href:'#'},'PRIVATE'));
   if(kind==='role')first.values.role='button';if(kind==='tabindex')first.values.tabindex='0';
   if(kind==='editable')first.values.contenteditable='true';if(kind==='ariahidden')first.values['aria-hidden']='false';
   if(kind==='syntax')first.values.class='token keyword';if(kind==='script')b.literal.append(b.n('SCRIPT',{},'PRIVATE'));
   if(kind==='prehidden')b.pre.values.hidden='';if(kind==='prerole')b.pre.values.role='button';
   if(kind==='preeditable')b.pre.values.contenteditable='true';if(kind==='pretabindex')b.pre.values.tabindex='0';
   if(kind==='nonwhitespace')b.pre.text='PRIVATE_PROSE';
   if(kind==='wrongcorners')b.corners[0].values.class='_9bc997d _28d7e84';
   if(kind==='extra_control')b.header.append(b.n('DIV',{role:'button'}));
   if(kind==='blockrole')b.block.values.role='button';if(kind==='finaleditable')f.final.values.contenteditable='true';
   if(kind==='spanonclick')first.values.onclick='PRIVATE';if(kind==='preonkeydown')b.pre.values.onkeydown='PRIVATE';
   expect(observed(f).formatIssue,kind).toBe(true);expect(f.mutations()).toBe(0);
  }
 });
 test('both modes keep full first-body/model proof and one Send for the whole fence',async()=>{
  for(const key of ['chat','deepthink']){
   const f=fixture({fresh:true});fence(f);let selected=false;for(let i=0;i<6;i++){const result=await f.run('selectMode',{modeChoice:mode(key)});expect(result.error).toBeUndefined();if(result.selected){selected=true;break;}}expect(selected).toBe(true);
   expect((await f.run('prepare')).prepared).toBe(true);expect((await f.run('insert',{prompt})).inserted).toBe(true);
   expect((await f.run('sendReady',{prompt})).sendReady).toBe(true);const hash=await fingerprint(prompt);
   expect((await f.run('submit',{prompt,savedSubmissionFingerprint:hash})).submitted).toBe(true);const r=await f.run('inspect');
   expect(r.firstUserVerified).toBe(true);expect(r.firstUserFingerprint).toBe(hash);expect(r.modeEvidence.selected).toEqual(mode(key));expect(r.modeEvidence.search).toBe(false);expect(r.text).toBe(raw);expect(r.answerComplete).toBe(true);expect(f.send.clicks).toBe(1);
  }
 });
});

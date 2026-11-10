import { expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq-response-stream-metadata.js', import.meta.url), 'utf8');
const purpose = 'groq_120b_fixture_response_stream_metadata_v1';
const encoder = new TextEncoder();
function factory(environment: any = {}) {
  return new Function('setTimeout', 'clearTimeout', 'performance', 'return (' + source + ');')(
    environment.setTimeout ?? setTimeout, environment.clearTimeout ?? clearTimeout, environment.performance ?? performance);
}
function options(overrides: any = {}) { return {streamMetadata:true, purpose, profile:'gptoss120b', isCurrent:() => true, ...overrides}; }
function event(value: any) { return 'data: ' + JSON.stringify(value) + '\n\n'; }
function parseBytes(text: string, width = 1) {
  const parser = factory().createGroqSSEMetadataParser();
  const bytes = encoder.encode(text);
  for (let at = 0; at < bytes.length && !parser.isStopped(); at += width) parser.push(bytes.subarray(at, at + width));
  parser.end(); return parser.snapshot();
}
function finite(snapshot: any, canaries: string[] = []) {
  expect(Object.keys(snapshot).sort()).toEqual(['version','framing','bytes','chunks','events','jsonEvents','content','reasoning',
    'toolCalls','topLevelError','eventError','xGroqError','apiErrorCode','apiErrorType','finishReason','done','eof','unknownFrames','incompleteFrame','outcome'].sort());
  const serialized = JSON.stringify(snapshot);
  expect(encoder.encode(serialized).length).toBeLessThanOrEqual(2048);
  for (const canary of canaries) expect(serialized).not.toContain(canary);
  expect(snapshot.bytes).toBeGreaterThanOrEqual(0); expect(snapshot.bytes).toBeLessThanOrEqual(262144);
  expect(snapshot.events).toBeGreaterThanOrEqual(0); expect(snapshot.events).toBeLessThanOrEqual(4096);
}

test('SSE metadata preserves split UTF8 and CRLF framing while discarding content, reasoning and tool payloads', () => {
  const hidden = ['PRIVATE_CONTENT_e\u0301_🌍', 'PRIVATE_REASONING', 'PRIVATE_TOOL_ARGUMENTS'];
  const input = ': heartbeat\r\n\r\n' +
    'data: {\r\ndata: "choices":[{"delta":{"content":' + JSON.stringify(hidden[0]) + '}}]}\r\n\r\n' +
    event({choices:[{delta:{reasoning:hidden[1]}}]}) +
    event({choices:[{delta:{reasoning_content:hidden[1], tool_calls:[{function:{arguments:hidden[2]}}]}}]}) +
    event({choices:[{delta:{}, finish_reason:'tool_calls'}]}) + 'data: [DONE]\r\n\r\n';
  for (const width of [1,2,3,7,4096]) {
    const facts = parseBytes(input, width);
    expect(facts).toMatchObject({content:true, reasoning:true, toolCalls:true, finishReason:'tool_calls',
      done:true, eof:true, events:5, jsonEvents:4, unknownFrames:0, outcome:'eof'});
    finite(facts, hidden);
  }
  const cr = parseBytes('data: {"choices":[]}\r\rdata: [DONE]\r\r');
  expect(cr).toMatchObject({events:2, done:true, eof:true, outcome:'eof'});
});

test('only complete unambiguous JSON events expose closed errors and finish reasons', () => {
  for (const code of ['over_capacity','rate_limit_exceeded','service_unavailable']) {
    const facts = parseBytes(event({x_groq:{error:code}}));
    expect(facts).toMatchObject({xGroqError:code, eof:true, done:false, outcome:'eof'}); finite(facts);
  }
  const privateValue = 'PRIVATE_UNKNOWN_ERROR_AND_TYPE';
  const other = parseBytes('event: error\n' + event({x_groq:{error:privateValue}, error:{code:privateValue,type:privateValue,message:privateValue}}));
  expect(other).toMatchObject({eventError:true, topLevelError:true, xGroqError:'other', apiErrorCode:'other', apiErrorType:'other'}); finite(other, [privateValue]);
  let deep: any = {}; for (let i = 0; i < 40; i++) deep = {nested:deep};
  for (const text of [
    'data: {"choices":[{"delta":{"content":"PRIVATE_DUP"}}],"choices":[]}\n\n',
    'data: {"x_groq":{"error":"over_capacity","\\u0065rror":"PRIVATE_DUP"}}\n\n',
    'data: {"x_groq":{"error":"PRIVATE_DUP","error":"over_capacity"}}\n\n',
    'data: {bad JSON PRIVATE_DUP}\n\n', 'data: 42\n\n',
    event({choices:[{delta:{content:'PRIVATE_DUP'}}], nested:deep})
  ]) {
    const facts = parseBytes(text); expect(facts.content).toBe(false); expect(facts.xGroqError).toBe('none');
    expect(facts.unknownFrames).toBe(1); finite(facts, ['PRIVATE_DUP']);
  }
  const partial = parseBytes('data: {"choices":[{"delta":{"content":"PRIVATE_PARTIAL"}}]}');
  expect(partial).toMatchObject({content:false, events:0, incompleteFrame:true, eof:true}); finite(partial, ['PRIVATE_PARTIAL']);
  for (const reason of ['stop','length','tool_calls','function_call','content_filter'])
    expect(parseBytes(event({choices:[{finish_reason:reason}]})).finishReason).toBe(reason);
  const finish = parseBytes(event({choices:[{finish_reason:'PRIVATE_FINISH'}]}) + event({choices:[{finish_reason:'stop'}]}));
  expect(finish.finishReason).toBe('multiple'); finite(finish, ['PRIVATE_FINISH']);
});

test('byte, event, empty-chunk, line, frame and UTF8 limits stop without retaining an oversized payload', () => {
  let parser = factory().createGroqSSEMetadataParser();
  const comment = encoder.encode(':' + 'x'.repeat(4094) + '\n');
  for (let i = 0; i < 64; i++) parser.push(comment);
  expect(parser.snapshot()).toMatchObject({bytes:262144, outcome:'byte_limit', events:0}); finite(parser.snapshot(), ['xxxx']);
  parser = factory().createGroqSSEMetadataParser();
  const frame = encoder.encode('data: {}\n\n');
  for (let i = 0; i < 4096; i++) parser.push(frame);
  expect(parser.snapshot()).toMatchObject({events:4096, outcome:'event_limit'}); finite(parser.snapshot());
  parser = factory().createGroqSSEMetadataParser();
  for (let i = 0; i < 8192; i++) parser.push(new Uint8Array());
  expect(parser.snapshot()).toMatchObject({chunks:8192, bytes:0, outcome:'chunk_limit'});
  for (const body of ['data: ' + 'x'.repeat(16384), ('data: ' + 'x'.repeat(8192) + '\n').repeat(2)]) {
    const facts = parseBytes(body, 4096); expect(facts.outcome).toBe('frame_limit'); finite(facts, ['xxxx']);
  }
  parser = factory().createGroqSSEMetadataParser(); parser.push(new Uint8Array([0xc3])); parser.end();
  expect(parser.snapshot()).toMatchObject({outcome:'utf8_invalid', content:false, eof:false});
  const frozen = parser.snapshot(); parser.push(encoder.encode(event({choices:[{delta:{content:'late'}}]})));
  expect(parser.snapshot()).toEqual(frozen);
});

test('plain JSON 200 errors use captured Content-Type and closed code/type enums; null and unknown framing grant no error claim', async () => {
  const {startMatchedGroqResponseStreamProbe:start} = factory();
  for (const code of ['rate_limit_exceeded','context_length_exceeded','invalid_api_key','model_not_found']) {
    const raw = JSON.stringify({error:{code,type:'invalid_request_error',message:'PRIVATE_JSON_MESSAGE_🌍'}});
    const response = new Response(raw, {headers:{'Content-Type':'Application/JSON; charset=utf-8'}});
    let privateReads = 0;
    Object.defineProperty(response, 'headers', {get() { privateReads++; throw new Error('PRIVATE_HEADER_PROPERTY'); }});
    const handle = start(response, options()); const original = response.text(); await handle.settled;
    const facts = handle.finishFailure();
    expect(await original).toBe(raw); expect(privateReads).toBe(0);
    expect(facts).toMatchObject({framing:'json', topLevelError:true, apiErrorCode:code,
      apiErrorType:'invalid_request_error', eof:true, events:1, jsonEvents:1, outcome:'eof'});
    finite(facts, ['PRIVATE_JSON_MESSAGE', 'PRIVATE_HEADER_PROPERTY']);
  }
  for (const error of [null,false,0,'']) {
    const response = new Response(JSON.stringify({error}), {headers:{'Content-Type':'application/json'}});
    const handle = start(response, options()); await Promise.all([response.text(), handle.settled]);
    expect(handle.finishFailure()).toMatchObject({framing:'json', topLevelError:false, apiErrorCode:'none', apiErrorType:'none'});
  }
  for (const type of ['tokens','requests']) {
    // Observed literal only: neither word assigns a quota class or policy.
    const raw = JSON.stringify({error:{code:'rate_limit_exceeded',type,message:'PRIVATE_UNCONFIRMED_TYPE_SEMANTICS'}});
    const response = new Response(raw, {headers:{'Content-Type':'application/json'}});
    const handle = start(response, options()); const original = response.text(); await handle.settled;
    const facts = handle.finishFailure(); expect(await original).toBe(raw);
    expect(facts).toMatchObject({topLevelError:true, apiErrorCode:'rate_limit_exceeded', apiErrorType:type});
    finite(facts, ['PRIVATE_UNCONFIRMED_TYPE_SEMANTICS']);
  }
  for (const body of [JSON.stringify({error:{code:'PRIVATE_CODE', type:'PRIVATE_TYPE'}}),
    '{"error":{"code":"rate_limit_exceeded"},"error":null}']) {
    const response = new Response(body, {headers:{'Content-Type':'application/json'}});
    const handle = start(response, options()); await Promise.all([response.text(), handle.settled]);
    const facts = handle.finishFailure(); finite(facts, ['PRIVATE_CODE','PRIVATE_TYPE']);
    if (body.includes('PRIVATE_CODE')) expect(facts).toMatchObject({topLevelError:true, apiErrorCode:'other', apiErrorType:'other'});
    else expect(facts).toMatchObject({topLevelError:false, apiErrorCode:'none', unknownFrames:1});
  }
  for (const headers of [{}, {'Content-Type':'text/x-PRIVATE_HEADER'}]) {
    const response = new Response(encoder.encode('{"error":{"code":"rate_limit_exceeded"}}'), {headers});
    const handle = start(response, options()); await Promise.all([response.text(), handle.settled]);
    const facts = handle.finishFailure(); expect(facts).toMatchObject({topLevelError:false, apiErrorCode:'none', unknownFrames:1, eof:true});
    expect(['missing','other']).toContain(facts.framing); finite(facts, ['PRIVATE_HEADER']);
  }
  const capped = factory().createGroqSSEMetadataParser('json'); capped.push(encoder.encode(' '.repeat(16385)));
  expect(capped.snapshot()).toMatchObject({framing:'json', outcome:'frame_limit', jsonEvents:0, topLevelError:false});
});

test('default, inherited/accessor, foreign-purpose/profile, stale and non2xx controls cannot clone or consume a Response', async () => {
  const {startMatchedGroqResponseStreamProbe:start} = factory();
  let privateReads = 0;
  const neverRead = new Proxy({}, {get() { privateReads++; throw new Error('PRIVATE_RESPONSE'); }});
  for (const config of [{}, options({streamMetadata:false}), options({purpose:'foreign'}), options({profile:'qwen27b'}),
    options({isCurrent:() => false}), Object.assign(Object.create({streamMetadata:true}), {purpose, profile:'gptoss120b', isCurrent:() => true}),
    Object.defineProperty(options({streamMetadata:false}), 'streamMetadata', {get() { privateReads++; return true; }})]) {
    expect(start(neverRead, config)).toBeNull();
  }
  expect(privateReads).toBe(0);
  for (const status of [204,400,401,403,413,429,500]) {
    const response = status === 204 ? new Response(null, {status}) : new Response('PRIVATE_NON2XX', {status});
    expect(start(response, options())).toBeNull(); expect(response.bodyUsed).toBe(false);
    if (status !== 204) expect(await response.text()).toBe('PRIVATE_NON2XX');
  }
});

test('matched clone keeps original fetch Promise, receiver, arguments and Response identity, and original bytes remain readable', async () => {
  const {startMatchedGroqResponseStreamProbe:start} = factory();
  const raw = event({choices:[{delta:{content:'PRIVATE_ORIGINAL_BYTES_🌍'}}]}) + 'data: [DONE]\n\n';
  const response = new Response(raw, {status:200, headers:{'Content-Type':'text/event-stream'}}), originalPromise = Promise.resolve(response);
  let reads = 0, handle: any, actualThis: any, actualArgs: any;
  Object.defineProperty(response, 'clone', {get() { reads++; throw new Error('PRIVATE_CLONE_PROPERTY'); }});
  const owner = {}, input = 'https://api.groq.com/openai/v1/chat/completions', init = {method:'POST', body:'PRIVATE_NATIVE_MATCHED_BODY'};
  function original(this: any, ...args: any[]) { actualThis = this; actualArgs = args; return originalPromise; }
  function wrapper(this: any, ...args: any[]) {
    const result = Reflect.apply(original, this, args); result.then(value => { handle = start(value, options()); }); return result;
  }
  const result = wrapper.call(owner, input, init);
  expect(result).toBe(originalPromise); expect(actualThis).toBe(owner); expect(actualArgs[0]).toBe(input); expect(actualArgs[1]).toBe(init);
  expect(await result).toBe(response); expect(handle).not.toBeNull(); expect(reads).toBe(0);
  expect(await response.text()).toBe(raw); await handle.settled;
  const facts = handle.finishFailure(); expect(facts).toMatchObject({content:true, done:true, eof:true, outcome:'eof'});
  finite(facts, ['PRIVATE_ORIGINAL_BYTES', 'PRIVATE_NATIVE_MATCHED_BODY', 'PRIVATE_CLONE_PROPERTY']);
  expect(handle.finishFailure()).toBeNull();
});

test('clone cancellation is unawaited, absolute expiry freezes a partial packet and the original branch still completes', async () => {
  let timer: any, scheduled = 0, cleared = 0, clock = 0, controller: any, sourceCancels = 0;
  const {startMatchedGroqResponseStreamProbe:start} = factory({
    setTimeout:(callback: any, ms: number) => { timer = callback; scheduled = ms; return 7; },
    clearTimeout:(id: number) => { expect(id).toBe(7); cleared++; }, performance:{now:() => clock}
  });
  const response = new Response(new ReadableStream({start(c) { controller = c; }, cancel() { sourceCancels++; }}), {headers:{'Content-Type':'text/event-stream'}});
  const handle = start(response, options()); expect(scheduled).toBe(60000);
  const original = response.text(); clock = 60001;
  // Timer has not fired: failure freezing still checks the absolute clock.
  const facts = handle.finishFailure(); expect(facts).toMatchObject({outcome:'deadline', bytes:0, eof:false, done:false});
  await handle.settled; expect(sourceCancels).toBe(0); expect(cleared).toBe(1);
  controller.enqueue(encoder.encode('ORIGINAL_AFTER_CLONE_CANCEL')); controller.close();
  expect(await original).toBe('ORIGINAL_AFTER_CLONE_CANCEL');
  timer(); expect(handle.finishFailure()).toBeNull(); finite(facts, ['ORIGINAL_AFTER_CLONE_CANCEL']);
});

test('DONE followed by an open stream is distinct from DONE plus natural EOF and cannot become completion authority', () => {
  const parser = factory().createGroqSSEMetadataParser();
  expect(parser.push(encoder.encode('data: [DONE]\n\n'))).toBe(true);
  expect(parser.isStopped()).toBe(false);
  expect(parser.snapshot()).toMatchObject({done:true, eof:false, outcome:'reading'});
  parser.stop('deadline'); const facts = parser.snapshot();
  expect(facts).toMatchObject({done:true, eof:false, outcome:'deadline'}); finite(facts);
  const natural = parseBytes('data: [DONE]\n\n'); expect(natural).toMatchObject({done:true, eof:true, outcome:'eof'});
  const after = parseBytes('data: [DONE]\n\nevent: error\n' + event({error:{code:'rate_limit_exceeded', type:'invalid_request_error'},
    x_groq:{error:'over_capacity'}, choices:[{delta:{content:'PRIVATE_AFTER_DONE', reasoning:'PRIVATE_AFTER_DONE', tool_calls:[{}]}, finish_reason:'length'}]}));
  expect(after).toMatchObject({done:true, eof:true, content:false, reasoning:false, toolCalls:false, eventError:false,
    topLevelError:false, xGroqError:'none', apiErrorCode:'none', apiErrorType:'none', finishReason:'none', unknownFrames:1});
  finite(after, ['PRIVATE_AFTER_DONE']);
  const before = parseBytes('event: error\n' + event({error:{code:'rate_limit_exceeded'}}) + 'data: [DONE]\n\n');
  expect(before).toMatchObject({done:true, eof:true, eventError:true, topLevelError:true, apiErrorCode:'rate_limit_exceeded'});
});

test('read rejection retains no exception text and revoked ownership cannot publish or accept late stream callbacks', async () => {
  const {startMatchedGroqResponseStreamProbe:start} = factory();
  let controller: any;
  const response = new Response(new ReadableStream({start(c) { controller = c; }}), {headers:{'Content-Type':'text/event-stream'}});
  const handle = start(response, options()); const original = response.text().catch(error => error);
  const error = new Error('PRIVATE_READER_EXCEPTION'); controller.error(error); await handle.settled;
  expect(await original).toBe(error); const facts = handle.finishFailure();
  expect(facts.outcome).toBe('read_rejected'); finite(facts, [error.message]);
  let current = true, late: any;
  const second = new Response(new ReadableStream({start(c) { late = c; }}), {headers:{'Content-Type':'text/event-stream'}});
  const stale = start(second, options({isCurrent:() => current})); const originalSecond = second.text();
  current = false; expect(stale.finishFailure()).toBeNull(); await stale.settled;
  late.enqueue(encoder.encode(event({choices:[{delta:{content:'PRIVATE_LATE'}}]}))); late.close();
  expect(await originalSecond).toContain('PRIVATE_LATE'); expect(stale.finishFailure()).toBeNull();
});

// Private prototype. Only a fresh owned tab with a native synthetic lease receives this main-world, main-frame script.
((config) => {
  'use strict';
  const origin = 'https://chat.groq.com', endpoint = 'https://api.groq.com/openai/v1/chat/completions';
  if (window !== top || location.origin !== origin || !config || !/^[a-f0-9]{32}$/.test(config.key)
    || !/^[a-f0-9]{32}$/.test(config.secret) || config.key === config.secret
    || !Number.isInteger(config.durationMs) || config.durationMs < 1 || config.durationMs > 390000) return;
  // Fixed first-party request profiles; the page cannot broaden native admission.
  const profiles = {
    gptoss20b: {model:'openai/gpt-oss-20b',label:'GPT OSS 20B',temperature:1,maximum:16384,topP:1},
    qwen27b: {model:'qwen/qwen3.8-27b',label:'Qwen/Qwen3.8-27B',temperature:0.6,maximum:8192,topP:0.95},
    gptoss120b: {model:'openai/gpt-oss-120b',label:'GPT OSS 120B',temperature:1,maximum:16384,topP:1}
  };
  if (!Object.prototype.hasOwnProperty.call(profiles, config.profile)) return;
  const profile = profiles[config.profile];
  const ownerDocument = document, original = window.fetch, key = '__computaGroqStatus_' + config.key;
  const apply = Reflect.apply, desc = Object.getOwnPropertyDescriptor, then = Promise.prototype.then;
  const stringify = JSON.stringify, proto = Object.getPrototypeOf;
  const response = Object.fromEntries(['url', 'redirected', 'status', 'type'].map(p => [p, desc(Response.prototype, p)?.get]));
  const time = performance.now.bind(performance), deadline = time() + config.durationMs;
  const fetchSlot = desc(window, 'fetch');
  if (!fetchSlot || fetchSlot.value !== original || !fetchSlot.writable || typeof original !== 'function'
    || key in window || Object.values(response).some(get => typeof get !== 'function')) return;
  let phase = 'idle', outcome = 'ambiguous', seen = false, prompt = null, model = null, label = null, pin = null, route = null;
  const style = node => !!node?.isConnected && node.getClientRects().length > 0 && getComputedStyle(node).visibility === 'visible';
  const unauthored = node => !node.closest('[class*="group/input"],.font-inter,pre,code');
  // Small side-band check of the same physical closed picker that the existing native adapter independently qualified.
  function rendered() {
    const url = new URL(location.href), triggers = document.querySelectorAll('button[aria-haspopup="dialog"][aria-controls]');
    if (ownerDocument !== document || window !== top || location.origin !== origin || location.href !== route
      || url.pathname !== '/' || url.hash || url.username || url.password || url.searchParams.size !== 1
      || url.searchParams.get('model') !== model || triggers.length > 64) return null;
    const candidates = [...triggers].filter(n => style(n) && unauthored(n) && n.querySelectorAll('svg.lucide-chevrons-up-down').length === 1);
    const node = candidates[0], dialogs = document.querySelectorAll('[role="dialog"]');
    if (candidates.length !== 1 || !node.getAttribute('aria-controls')?.match(/^\S{1,256}$/) || dialogs.length > 16
      || [...dialogs].some(n => style(n) && unauthored(n)) || node.closest('[hidden],[inert],[aria-hidden="true"]')
      || node.getAttribute('aria-expanded') !== 'false' || node.getAttribute('data-state') !== 'closed'
      || (node.innerText || node.textContent).normalize('NFC').replace(/\s+/g, ' ').trim() !== label) return null;
    return node;
  }
  function current() { return phase === 'armed' && time() < deadline && window.fetch === wrapped && rendered() === pin; }
  function invalidate() { outcome = 'ambiguous'; phase = 'invalid'; prompt = model = label = pin = route = null; }
  function dispose() {
    invalidate(); clearTimeout(timer);
    if (window.fetch === wrapped) window.fetch = original;
    delete window[key];
  }
  function matches(init) {
    if (!init || ![Object.prototype, null].includes(proto(init))) return false;
    const method = desc(init, 'method')?.value, body = desc(init, 'body')?.value;
    if (typeof method !== 'string' || !/^[Pp][Oo][Ss][Tt]$/.test(method) || typeof body !== 'string' || body.length > 262144) return false;
    // Match the exact two first-party fresh request serializations. Consume an optional
    // system string lexically, never materializing a foreign message or its fields.
    // Embedded quotes in an escaped system value cannot terminate that value.
    function skipString(at) {
      if (body[at++] !== '"') return -1;
      while (at < body.length) {
        const value=body[at++];
        if (value==='"') return at;
        if (value==='\\') {
          if (body[at]==='u') {
            if (!/^[0-9a-fA-F]{4}$/.test(body.slice(at+1,at+5))) return -1;
            at+=5;
          } else if (!'"\\/bfnrt'.includes(body[at++])) return -1;
        } else if (value.charCodeAt(0)<32) return -1;
      }
      return -1;
    }
    for (const indent of [undefined,2]) {
      const sample = 'groq_dummy_prompt', system = 'groq_dummy_system';
      const fresh = [{content:sample,role:'user'}];
      // The public Qwen branch drops system messages; GPT OSS may retain one.
      const messageSets = config.profile === 'qwen27b' ? [fresh] : [fresh,[{content:system,role:'system'},...fresh]];
      for (const messages of messageSets) {
        const template=stringify({model,messages,temperature:profile.temperature,max_completion_tokens:profile.maximum,top_p:profile.topP,stream:true},null,indent);
        const split=template.indexOf(stringify(sample));
        const prefix=template.slice(0,split),suffix=template.slice(split+stringify(sample).length);
        let pos=0;
        if (messages.length===2) {
          const at=prefix.indexOf(stringify(system));
          if (!body.startsWith(prefix.slice(0,at))) continue;
          pos=skipString(at); if (pos<0) continue;
          const rest=prefix.slice(at+stringify(system).length);
          if (!body.startsWith(rest,pos)) continue;
          pos+=rest.length;
        } else {
          if (!body.startsWith(prefix)) continue;
          pos=prefix.length;
        }
        const content=stringify(prompt);
        if (body.startsWith(content,pos) && body.length===pos+content.length+suffix.length && body.endsWith(suffix)) return true;
      }
    }
    return false;
  }
  function wrapped(input, init) {
    let track = false;
    try {
      const url = phase !== 'invalid' && typeof input === 'string' ? new URL(input, document.baseURI) : null;
      if (phase !== 'invalid' && (!url || url.origin + url.pathname === endpoint)) {
        if (input !== endpoint || arguments.length !== 2 || seen || !current() || !matches(init)) invalidate();
        else { seen = true; prompt = null; outcome='matched_fetch_unsettled'; track = true; }
      }
    } catch { invalidate(); }
    let result;
    try { result = apply(original, this, arguments); }
    catch (error) { if (track) invalidate(); throw error; }
    if (track) {
      try {
        apply(then, result, [
          value => {
            try {
              if (!current() || apply(response.url, value, []) !== endpoint || apply(response.redirected, value, [])
                || !['basic', 'cors'].includes(apply(response.type, value, []))) return invalidate();
              const status = apply(response.status, value, []);
              outcome = status >= 200 && status < 300 ? 'http_2xx_opened'
                : [400, 401, 403, 413, 429].includes(status) ? 'http_' + status
                : status >= 400 && status < 600 ? 'http_other_non_2xx' : 'ambiguous';
            } catch { invalidate(); }
          },
          () => { try { if (current()) outcome = 'transport_rejected'; else invalidate(); } catch { invalidate(); } }
        ]);
      } catch { invalidate(); }
    }
    return result;
  }
  window.fetch = wrapped;
  const timer = setTimeout(dispose, config.durationMs);
  Object.defineProperty(window, key, {configurable: true, value: (secret, command, args) => {
    if (secret !== config.secret) return false;
    if (command === 'dispose') { dispose(); return true; }
    if (command === 'arm' && phase === 'idle' && !seen && time() < deadline && window.fetch === wrapped) {
      if (!args || args.model !== profile.model || args.label !== profile.label
        || typeof args.label !== 'string' || !args.label.length || args.label.length > 128
        || typeof args.prompt !== 'string' || !args.prompt.length || args.prompt.length > 180200) { invalidate(); return false; }
      model = args.model; label = args.label; route = location.href; pin = rendered();
      if (!pin) { invalidate(); return false; }
      prompt = args.prompt; phase = 'armed'; return true;
    }
    // Native may call finish only after its separately proven single Send plus exact optimistic rollback.
    if (command === 'finish' && phase !== 'idle') {
      let finite = 'ambiguous';
      try { if (current()) finite = seen ? outcome : 'no_matching_fetch_observed'; } catch { finite = 'ambiguous'; } finally { dispose(); }
      return finite;
    }
    return false;
  }});
})(__GROQ_OWNED_SYNTHETIC_CONFIG__)

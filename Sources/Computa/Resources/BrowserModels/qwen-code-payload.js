(() => {
  const config = __COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__;
  if (window !== window.top || location.origin !== 'https://chat.qwen.ai') return;
  const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
  if (!config || Object.keys(config).sort().join(',') !== 'dispatch,result,secret'
    || ![config.dispatch,config.result,config.secret].every(uuid)) return;
  const click = HTMLElement.prototype.click, exec = Document.prototype.execCommand;
  let active = null, spent = false;
  const writeText = value => {
    if (active) {
      active.count++;
      if (typeof value !== 'string' || value.length > 220000) active.invalid = true;
      else if (active.count === 1) active.text = value;
    }
    // The owned view never delegates clipboard writes, including late callbacks.
    return Promise.resolve();
  };
  const write = () => { if (active) active.invalid = true; return Promise.resolve(); };
  const command = function(name, ...args) {
    if (typeof name !== 'string' || ['copy','cut','paste'].includes(name.trim().toLowerCase())) {
      if (active) active.invalid = true;
      return false;
    }
    // Ordinary composer editing remains available; no clipboard command passes.
    return Reflect.apply(exec,this,[name,...args]);
  };
  try {
    if (!navigator.clipboard || typeof Clipboard !== 'function') return;
    Object.defineProperty(Clipboard.prototype,'writeText',{value:writeText,writable:false,configurable:false});
    Object.defineProperty(Clipboard.prototype,'write',{value:write,writable:false,configurable:false});
    Object.defineProperty(Document.prototype,'execCommand',{value:command,writable:false,configurable:false});
  } catch { return; }
  const intact = () => navigator.clipboard.writeText === writeText && navigator.clipboard.write === write && document.execCommand === command;
  document.addEventListener('copy', event => event.preventDefault(), true);
  document.addEventListener(config.dispatch,event => {
    const request = event.detail, target = event.target;
    if (spent || !intact() || location.origin !== 'https://chat.qwen.ai' || !(target instanceof HTMLButtonElement)
      || !request || Object.keys(request).sort().join(',') !== 'grant,secret'
      || request.secret !== config.secret || !uuid(request.grant)) return;
    spent = true;
    active = {count:0,invalid:false,text:null};
    let result;
    try { Reflect.apply(click,target,[]); }
    catch { active.invalid = true; }
    finally {
      result = active; active = null;
      result.invalid ||= !intact();
      try {
        target.dispatchEvent(new CustomEvent(config.result,{bubbles:true,
          detail:{grant:request.grant,count:result.count,invalid:result.invalid,text:result.text}}));
      } finally { result.text = null; result = null; }
    }
  },true);
})();

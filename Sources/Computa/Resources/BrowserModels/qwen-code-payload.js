(() => {
  const config = __COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__;
  if (window !== window.top || location.origin !== 'https://chat.qwen.ai') return;
  const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
  if (!config || Object.keys(config).sort().join(',') !== 'dispatch,result,secret'
    || ![config.dispatch,config.result,config.secret].every(uuid)) return;
  const click = HTMLElement.prototype.click, exec = Document.prototype.execCommand;
  let active = null, spent = false;
  const invalidate = (record, cause) => {
    if (!record) return;
    record.invalid = true;
    if (record.invalidCause === null) record.invalidCause = cause;
  };
  const writeText = value => {
    if (active) {
      active.count++;
      if (typeof value !== 'string') invalidate(active, 'value_type');
      else if (value.length > 220000) invalidate(active, 'value_size');
      else if (active.count === 1) active.text = value;
    }
    // The owned view never delegates clipboard writes, including late callbacks.
    return Promise.resolve();
  };
  const write = () => { invalidate(active, 'write_api'); return Promise.resolve(); };
  const command = function(name, ...args) {
    if (typeof name !== 'string' || ['copy','cut','paste'].includes(name.trim().toLowerCase())) {
      invalidate(active, 'exec_command');
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
    active = {count:0,invalid:false,invalidCause:null,text:null};
    let result;
    try { Reflect.apply(click,target,[]); }
    catch { invalidate(active, 'click_exception'); }
    finally {
      result = active; active = null;
      if (!result.invalid && !intact()) invalidate(result, 'hooks_changed');
      try {
        target.dispatchEvent(new CustomEvent(config.result,{bubbles:true,
          detail:{grant:request.grant,count:result.count,invalid:result.invalid,invalidCause:result.invalidCause,text:result.text}}));
      } finally { result.text = null; result = null; }
    }
  },true);
})();

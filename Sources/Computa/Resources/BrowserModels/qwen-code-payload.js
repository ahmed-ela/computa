(() => {
  const config = __COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__;
  if (window !== window.top || location.origin !== 'https://chat.qwen.ai') return;
  const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
  if (!config || Object.keys(config).sort().join(',') !== 'dispatch,result,secret'
    || ![config.dispatch,config.result,config.secret].every(uuid)) return;
  const click = HTMLElement.prototype.click, exec = Document.prototype.execCommand;
  const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener;
  const stop = Event.prototype.stopPropagation, query = Document.prototype.querySelectorAll, contains = Node.prototype.contains;
  const appRoot = target => {
    const roots = Reflect.apply(query, document, ['[id="root"]']);
    const root = roots.length === 1 ? roots[0] : null;
    return root && root.tagName === 'DIV' && root.namespaceURI === 'http://www.w3.org/1999/xhtml'
      && root.isConnected && root.parentElement === document.body && Reflect.apply(contains, root, [target]) ? root : null;
  };
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
    try { return Promise.resolve(); }
    catch (error) { invalidate(active, 'resolve_failure'); throw error; }
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
    let result, root = null, seen = 0, listening = false;
    // React already delegates the header Copy at #root. This temporary listener
    // stops only that Copy click after the delegate, before Monaco primes a
    // BODY clipboard write. Same-root and lower writes still invalidate it.
    const boundary = event => {
      if (active && event.target === target && event.currentTarget === root && event.type === 'click') {
        seen++;
        Reflect.apply(stop, event, []);
      }
    };
    try {
      root = appRoot(target);
      if (!root) invalidate(active, 'root_boundary');
      else {
        Reflect.apply(add, root, ['click', boundary, false]); listening = true;
        Reflect.apply(click, target, []);
        if (seen !== 1 || appRoot(target) !== root) invalidate(active, 'root_boundary');
      }
    }
    catch { invalidate(active, 'click_exception'); }
    finally {
      if (listening) Reflect.apply(remove, root, ['click', boundary, false]);
      result = active; active = null;
      if (!result.invalid && !intact()) invalidate(result, 'hooks_changed');
      try {
        target.dispatchEvent(new CustomEvent(config.result,{bubbles:true,
          detail:{grant:request.grant,count:result.count,invalid:result.invalid,invalidCause:result.invalidCause,text:result.text}}));
      } finally { result.text = null; result = null; }
    }
  },true);
})();

// Fixed general-purpose DOM backend. Executed only in a named isolated world;
// the page cannot forge host snapshots, node identities, or mutation permits.
const key = '__computaBrowserControlV1';
let state = globalThis[key];
// A native stop can retire the generation while retaining the old DOM. Fresh
// read-only observation may install a new capability map; mutations cannot.
if (!state || (state.documentToken !== input.documentToken && ['observe','wait'].includes(input.operation))) {
  state = globalThis[key] = {ids:new WeakMap(), nodes:new Map(), nextID:1, documentToken:input.documentToken};
}
if (state.documentToken !== input.documentToken) throw new Error('stale_document');
const trim = value => String(value ?? '').replace(/\s+/g, ' ').trim();
const roleEncoder = new TextEncoder();
// Limit character count before encoding, then enforce the same UTF-8 byte
// ceiling as the native decoder without allocating an unbounded byte array.
const oversizedRole = raw => {
  if (raw.length > 100) return true;
  // Lowercasing can expand bytes (for example U+0130 -> i + combining dot).
  // Both strings stay allocation-bounded before the native 100-byte decoder.
  const normalized = trim(raw).split(' ')[0].toLowerCase();
  return roleEncoder.encode(raw).length > 100 || roleEncoder.encode(normalized).length > 100;
};
const idFor = node => {
  let id = state.ids.get(node);
  if (!id) { id = state.nextID++; state.ids.set(node, id); }
  return id;
};
const allowedByAncestors = element => {
  for (let node = element; node; node = node.parentElement) {
    if (node.hidden || node.getAttribute('aria-hidden') === 'true' || node.hasAttribute('inert')) return false;
    const style = getComputedStyle(node);
    if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
  }
  return true;
};
// Input targets still need their own rendered box. A display:contents wrapper
// may be traversed below, but that does not make it an input target.
const visible = element => allowedByAncestors(element) && element.getClientRects().length > 0;
const visibleText = node => {
  const parent = node.parentElement;
  if (!parent || !allowedByAncestors(parent)) return false;
  if (parent.getClientRects().length > 0) return true;
  if (getComputedStyle(parent).display !== 'contents') return false;
  const range = document.createRange();
  range.selectNodeContents(node);
  return range.getClientRects().length > 0;
};
const roleFor = element => {
  // Page-provided ARIA cannot turn a native secure field into a control whose
  // accessible-name fallback would reveal its value attribute.
  if (element.tagName === 'INPUT' && element.type === 'password') return 'textbox';
  const rawRole = element.getAttribute('role') || '';
  if (oversizedRole(rawRole)) return 'generic';
  const explicit = trim(rawRole).split(' ')[0];
  if (explicit && !['none', 'presentation'].includes(explicit)) return explicit.toLowerCase();
  const tag = element.tagName.toLowerCase();
  if (/^h[1-6]$/.test(tag)) return 'heading';
  if (tag === 'input') {
    const type = (element.type || 'text').toLowerCase();
    if (['submit', 'button', 'reset', 'image'].includes(type)) return 'button';
    if (['checkbox', 'radio', 'range'].includes(type)) return type === 'range' ? 'slider' : type;
    return type === 'search' ? 'searchbox' : type === 'hidden' ? null : 'textbox';
  }
  if (element.isContentEditable) return 'textbox';
  return ({a: element.hasAttribute('href') ? 'link' : null, button:'button', textarea:'textbox', select:'combobox',
    main:'main', article:'article', nav:'navigation', aside:'complementary', header:'banner', footer:'contentinfo',
    ul:'list', ol:'list', li:'listitem', p:'statictext', pre:'statictext', blockquote:'statictext', img:'image',
    section: element.getAttribute('aria-label') ? 'region' : null, output:'status'})[tag] || null;
};
const nameFor = (element, role, boxlessContents = false) => {
  const labelled = trim(element.getAttribute('aria-labelledby'));
  if (labelled) {
    const text = trim(labelled.split(' ').map(id => document.getElementById(id)?.textContent || '').join(' '));
    if (text) return text;
  }
  const aria = trim(element.getAttribute('aria-label'));
  if (aria) return aria;
  if (['textbox','searchbox','combobox'].includes(role)) {
    const label = trim(Array.from(element.labels || []).map(node => node.innerText || node.textContent || '').join(' '));
    return label || trim(element.getAttribute('placeholder')) || trim(element.getAttribute('title'));
  }
  if (['application','main','article','navigation','complementary','banner','contentinfo','list','listitem','region'].includes(role)) return '';
  if (role === 'image') return trim(element.getAttribute('alt'));
  // WebKit's innerText on a boxless wrapper can include hidden descendants.
  // Keep explicit accessible labels above; visible child text is captured with
  // its own layout/ancestor checks instead of aggregating the wrapper subtree.
  if (boxlessContents) return '';
  const rendered = typeof element.innerText === 'string' ? element.innerText : element.textContent;
  return trim(rendered || element.getAttribute('value') || element.getAttribute('title'));
};
// Passive native field state, not submission/outcome evidence. Never invoke
// checkValidity/reportValidity: those can dispatch events or present UI.
// Only the already captured visible field is inspected; no form traversal,
// validationMessage, hidden fields, or secure-field validity is exposed.
const constraintsFor = (element, boxlessContents) => {
  if (boxlessContents || !['INPUT','TEXTAREA','SELECT'].includes(element.tagName)
      || (element.tagName === 'INPUT' && ['password','hidden','submit','button','reset','image'].includes(element.type))) return null;
  const validity = element.validity;
  if (typeof element.required !== 'boolean' || typeof element.willValidate !== 'boolean'
      || !validity || typeof validity.valid !== 'boolean') return null;
  const flags = [['valueMissing','value_missing'],['typeMismatch','type_mismatch'],
    ['patternMismatch','pattern_mismatch'],['tooLong','too_long'],['tooShort','too_short'],
    ['rangeUnderflow','range_underflow'],['rangeOverflow','range_overflow'],
    ['stepMismatch','step_mismatch'],['badInput','bad_input'],['customError','custom_error']];
  return {required:element.required, candidate:element.willValidate, valid:validity.valid,
    issues:flags.filter(([property]) => validity[property] === true).map(([,name]) => name)};
};
const metaFor = (element, role, boxlessContents = false) => {
  const name = nameFor(element, role, boxlessContents);
  const editableRole = ['textbox','searchbox','combobox'].includes(role);
  const nativeEditable = element.isContentEditable || ['TEXTAREA','SELECT'].includes(element.tagName)
    || (element.tagName === 'INPUT' && ['text','search','email','url','tel','number','date','datetime-local','month','week','time','color'].includes(element.type));
  const editable = editableRole && nativeEditable;
  const password = element.tagName === 'INPUT' && element.type === 'password';
  const value = editable && !password && !boxlessContents ? String(element.isContentEditable ? element.innerText : element.value ?? '') : null;
  const link = role === 'link' ? String(element.href || '') : null;
  // Keep the destination observable without offering an action this backend
  // must reject. Task input never creates or adopts an unowned popup.
  const popupOnlyLink = element.tagName === 'A' && !!element.target
    && !['_self','_top','_parent'].includes(element.target.toLowerCase());
  // Explicit ARIA selection/check-menu items activate through the same exact
  // DOM click path as other controls. Native OPTION selection is separate.
  const interactiveItem = element.tagName !== 'OPTION' && typeof element.click === 'function'
    && ['option','treeitem','menuitemcheckbox','menuitemradio'].includes(role)
    && trim(element.getAttribute('role')).toLowerCase() === role;
  const tooLarge = name.length > 4096 || (value?.length || 0) > 4096 || (link?.length || 0) > 2048;
  const disabled = !!element.disabled || !!element.closest('[disabled], [aria-disabled="true"]') || password || tooLarge;
  const readOnly = !!element.readOnly || element.getAttribute('aria-readonly') === 'true' || password || tooLarge || (editableRole && !nativeEditable);
  return {role, name:name.slice(0,4096), value:password ? null : value?.slice(0,4096) ?? null,
    linkURL:link?.slice(0,2048) ?? null, isDisabled:disabled, isReadOnly:readOnly, isEditable:editable && !readOnly,
    isIgnored:false, isDOMClickable:!popupOnlyLink && (interactiveItem || ['button','link','checkbox','radio','switch','tab','menuitem'].includes(role)),
    isPressUnsupported:popupOnlyLink,
    isFocusablePointer:false, constraintValidation:constraintsFor(element, boxlessContents), fieldTruncated:tooLarge};
};
const capture = () => {
  const nodes = [], next = [{node:document.body || document.documentElement, parent:null, suppressText:false}];
  let visited = 0, budget = 0, truncated = false;
  const diagnostics = {stopReason:'none',visited:0,emitted:0,estimatedBytes:0,
    visibilityState:['visible','hidden','prerender'].includes(document.visibilityState) ? document.visibilityState : 'unknown',
    viewportWidth:Number.isInteger(innerWidth) && innerWidth >= 0 && innerWidth <= 1000000 ? innerWidth : 0,
    viewportHeight:Number.isInteger(innerHeight) && innerHeight >= 0 && innerHeight <= 1000000 ? innerHeight : 0,
    frames:0,shadowRoots:0,oversizedRoles:0,clippedFields:0,boxlessContents:0};
  state.nodes.clear();
  while (next.length) {
    const item = next.pop(), node = item.node;
    if (++visited > 20000 || nodes.length >= 3000 || budget > 220000) {
      diagnostics.stopReason = visited > 20000 ? 'visited_limit' : nodes.length >= 3000 ? 'node_limit' : 'byte_budget';
      truncated = true; break;
    }
    if (node.nodeType === Node.TEXT_NODE) {
      const text = trim(node.textContent);
      if (item.suppressText || !text || !visibleText(node)) continue;
      const id = idFor(node), name = text.slice(0,4096);
      truncated ||= text.length > 4096;
      if (text.length > 4096) diagnostics.clippedFields++;
      nodes.push({backendNodeID:id,nodeID:String(id),parentNodeID:item.parent,childNodeIDs:[],role:'statictext',name,
        value:null,isDisabled:true,isReadOnly:true,isIgnored:false,isDOMClickable:false,isPressUnsupported:false,isFocusablePointer:false,isEditable:false,linkURL:null});
      budget += name.length * 3 + 200;
      continue;
    }
    if (node.nodeType !== Node.ELEMENT_NODE || ['SCRIPT','STYLE','NOSCRIPT','TEMPLATE'].includes(node.tagName)
        || !allowedByAncestors(node)) continue;
    const boxlessContents = node.getClientRects().length === 0 && getComputedStyle(node).display === 'contents';
    if (!boxlessContents && node.getClientRects().length === 0) continue;
    if (boxlessContents) diagnostics.boxlessContents++;
    // This backend covers the main light DOM only. Never imply exhaustive
    // document coverage when a frame or shadow tree is not traversed.
    if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') { diagnostics.frames++; truncated = true; }
    if (node.shadowRoot) { diagnostics.shadowRoots++; truncated = true; }
    if (oversizedRole(node.getAttribute('role') || '')) { diagnostics.oversizedRoles++; truncated = true; }
    const role = roleFor(node);
    let parent = item.parent, suppressText = item.suppressText;
    if (role) {
      const id = idFor(node), meta = metaFor(node, role, boxlessContents);
      truncated ||= meta.fieldTruncated;
      if (meta.fieldTruncated) diagnostics.clippedFields++;
      delete meta.fieldTruncated;
      if (boxlessContents) {
        // Retain landmarks/control ancestry so descendants are not reclassified
        // as body text, while withholding every no-box wrapper input capability.
        meta.isDisabled = true; meta.isReadOnly = true; meta.isEditable = false;
        meta.isDOMClickable = false; meta.isFocusablePointer = false; meta.isPressUnsupported = true;
      }
      nodes.push({backendNodeID:id,nodeID:String(id),parentNodeID:parent,childNodeIDs:[],...meta});
      state.nodes.set(id,node);
      budget += JSON.stringify(meta).length * 3 + 200;
      parent = String(id);
      suppressText = !boxlessContents && ['button','link','heading','statictext','textbox','searchbox','combobox','image'].includes(role);
    }
    const children = Array.from(node.childNodes);
    for (let index = children.length - 1; index >= 0; index--) next.push({node:children[index],parent,suppressText});
  }
  const byID = new Map(nodes.map(node => [node.nodeID,node]));
  for (const node of nodes) if (node.parentNodeID && byID.has(node.parentNodeID)) byID.get(node.parentNodeID).childNodeIDs.push(node.nodeID);
  diagnostics.visited = visited; diagnostics.emitted = nodes.length; diagnostics.estimatedBytes = budget;
  return {loaderID:input.documentToken, title:String(document.title).slice(0,512), url:location.href, nodes,
    sourceTruncated:truncated,captureDiagnostics:diagnostics};
};
const isSemanticNode = node =>
  ['button','link','checkbox','combobox','searchbox','textbox','menu','menubar','menuitem',
    'menuitemcheckbox','menuitemradio','radio','radiogroup','switch','tab','tablist',
    'toolbar','slider','spinbutton','listbox','option','treeitem'].includes(node.role)
  || (['statictext','inlinetextbox','text','heading','paragraph','listitem','term','definition',
    'code','blockquote','cell','gridcell','rowheader','columnheader','caption','label'].includes(node.role)
    && !!trim(node.name || node.value));
const hasSemanticContent = snapshot => {
  // Footer text/links remain observable and actionable, but cannot by
  // themselves establish readiness of the page outside that footer.
  const children = new Map(), footerScope = new Set();
  for (const node of snapshot.nodes) {
    if (!node.parentNodeID) continue;
    if (!children.has(node.parentNodeID)) children.set(node.parentNodeID, []);
    children.get(node.parentNodeID).push(node.nodeID);
  }
  const pending = snapshot.nodes.filter(node => node.role === 'contentinfo').map(node => node.nodeID);
  while (pending.length) {
    const id = pending.pop();
    if (footerScope.has(id)) continue;
    footerScope.add(id);
    pending.push(...(children.get(id) || []));
  }
  return snapshot.nodes.some(node => isSemanticNode(node) && !footerScope.has(node.nodeID));
};
// Keep this predicate aligned with BrowserTabSessionBroker's content view:
// readable fields outside controls/navigation, plus observed listbox options
// and their text. A toolbar, input echo, or region label cannot release an
// explicit content read while an application is still rendering its body.
// No query text enters this readiness decision and no new DOM is traversed.
const hasReadableContent = snapshot => {
  const byID = new Map(snapshot.nodes.map(node => [node.nodeID, node]));
  const textRoles = new Set(['statictext','inlinetextbox','text','heading','paragraph','listitem','term',
    'definition','code','blockquote','cell','gridcell','rowheader','columnheader','caption','label']);
  const controls = new Set(['button','checkbox','combobox','searchbox','textbox','menu','menubar','menuitem',
    'menuitemcheckbox','menuitemradio','radio','radiogroup','switch','tab','tablist','toolbar','slider',
    'spinbutton','listbox','option','treeitem']);
  const navigation = new Set(['link','navigation','complementary','banner','contentinfo']);
  const optionExcluded = new Set([...controls].filter(role => !['listbox','option'].includes(role))
    .concat(['link','navigation','banner','contentinfo']));
  return snapshot.nodes.some(node => {
    if (!(trim(node.name) || String(node.value ?? '')) || !(textRoles.has(node.role) || node.role === 'option')) return false;
    const seen = new Set();
    let current = node, readable = textRoles.has(node.role), option = true;
    let optionSeen = false, listboxSeen = false;
    for (let depth = 0; depth < 128; depth++) {
      if (!current.nodeID || byID.get(current.nodeID) !== current || seen.has(current.nodeID)) return false;
      seen.add(current.nodeID);
      const role = current.role;
      if (controls.has(role) || navigation.has(role)) readable = false;
      if (optionExcluded.has(role)) option = false;
      if (role === 'option') {
        if (optionSeen) option = false;
        optionSeen = true;
      } else if (role === 'listbox') {
        if (!optionSeen || listboxSeen) option = false;
        listboxSeen = true;
      }
      if (!current.parentNodeID) return readable || (option && optionSeen && listboxSeen);
      current = byID.get(current.parentNodeID);
      if (!current) return false;
    }
    // The native readable classifier remains permissive for unknown ancestry;
    // listbox-option selection requires its complete observed ancestor chain.
    return readable;
  });
};
// Empty and footer-only shells wait. A meaningful page returns immediately;
// expiration is a bounded observation, never proof that requested content is absent.
const waitForCapture = async matches => {
  const initial = capture();
  if (matches(initial)) return {snapshot:initial, matched:true};
  if (!Number.isInteger(input.timeoutMS) || input.timeoutMS < 1 || input.timeoutMS > 10000)
    throw new Error('invalid_readiness_timeout');
  return await new Promise(resolve => {
    let finished = false;
    const events = ['DOMContentLoaded','readystatechange','input','change'];
    const done = (snapshot, matched) => {
      if (finished) return;
      finished = true; observer.disconnect(); clearTimeout(timer);
      for (const event of events) document.removeEventListener(event, changed, true);
      resolve({snapshot, matched});
    };
    const changed = () => { const snapshot = capture(); if (matches(snapshot)) done(snapshot, true); };
    const observer = new MutationObserver(changed);
    observer.observe(document, {subtree:true,childList:true,characterData:true,attributes:true});
    const timer = setTimeout(() => { const snapshot = capture(); done(snapshot, matches(snapshot)); }, input.timeoutMS);
    for (const event of events) document.addEventListener(event, changed, true);
    changed(); // Registration race is closed without polling.
  });
};
if (input.operation === 'observe') {
  if (input.awaitSemanticReadiness !== true) return capture();
  const result = await waitForCapture(input.readinessView === 'content' ? hasReadableContent : hasSemanticContent);
  return {...result.snapshot, semanticReadiness:result.matched ? 'ready' : 'empty_at_deadline'};
}
if (input.operation === 'wait') {
  const text = String(input.text || '');
  const result = await waitForCapture(snapshot => document.readyState !== 'loading'
    && (text ? snapshot.nodes.some(node => isSemanticNode(node)
        && (node.name.includes(text) || (node.value || '').includes(text)))
      : hasSemanticContent(snapshot)));
  return {matched:result.matched};
}
if (!['press','fill'].includes(input.operation)) throw new Error('unsupported_operation');
const element = state.nodes.get(input.nodeID);
const revalidateElement = () => {
  if (globalThis[key] !== state || state.documentToken !== input.documentToken) throw new Error('stale_document');
  if (state.nodes.get(input.nodeID) !== element || !element?.isConnected || !visible(element)) throw new Error('element_changed');
  const current = metaFor(element, roleFor(element));
  delete current.fieldTruncated;
  let semanticParent = element.parentElement;
  while (semanticParent && !roleFor(semanticParent)) semanticParent = semanticParent.parentElement;
  const parentID = semanticParent ? String(idFor(semanticParent)) : null;
  if (parentID !== input.expected.parentNodeID) throw new Error('element_changed');
  for (const key of ['role','name','value','linkURL','isDisabled','isReadOnly','isEditable','isDOMClickable','isPressUnsupported'])
    if (current[key] !== input.expected[key]) throw new Error('element_changed');
  if (current.isDisabled || input.expectedURL !== location.href) throw new Error('stale_document');
  return current;
};
const requireUnobstructed = () => {
  const rect = element.getBoundingClientRect();
  const hit = document.elementFromPoint(rect.left + rect.width/2, rect.top + rect.height/2);
  if (rect.width <= 0 || rect.height <= 0 || !hit || (hit !== element && !element.contains(hit))) throw new Error('element_obstructed');
};
const current = revalidateElement();
element.scrollIntoView({block:'center',inline:'center'});
requireUnobstructed();
if (input.operation === 'press') {
  if (!current.isDOMClickable || typeof element.click !== 'function') throw new Error('unsupported_action');
  if (element.tagName === 'A' && element.target && !['_self','_top','_parent'].includes(element.target.toLowerCase())) throw new Error('popup_unsupported');
  element.click();
} else {
  if (!current.isEditable || current.isReadOnly) throw new Error('unsupported_action');
  if (typeof element.focus !== 'function') throw new Error('unsupported_action');
  // Focus belongs to this admitted page field only; it never activates a native
  // window. Synchronous focus handlers may replace the field or change its scope.
  element.focus({preventScroll:true});
  revalidateElement();
  if (document.activeElement !== element) throw new Error('element_changed');
  requireUnobstructed();
  if (element.isContentEditable) element.textContent = input.text;
  else {
    const prototype = element.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : element.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype,'value')?.set;
    if (!setter) throw new Error('unsupported_action');
    setter.call(element,input.text);
  }
  element.dispatchEvent(new Event('input',{bubbles:true}));
  element.dispatchEvent(new Event('change',{bubbles:true}));
}
return {dispatched:true, noReplay:true};

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
const visible = element => {
  for (let node = element; node; node = node.parentElement) {
    if (node.hidden || node.getAttribute('aria-hidden') === 'true' || node.hasAttribute('inert')) return false;
    const style = getComputedStyle(node);
    if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
  }
  return element.getClientRects().length > 0;
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
const nameFor = (element, role) => {
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
  if (['main','article','navigation','complementary','banner','contentinfo','list','listitem','region'].includes(role)) return '';
  if (role === 'image') return trim(element.getAttribute('alt'));
  const rendered = typeof element.innerText === 'string' ? element.innerText : element.textContent;
  return trim(rendered || element.getAttribute('value') || element.getAttribute('title'));
};
const metaFor = (element, role) => {
  const name = nameFor(element, role);
  const editableRole = ['textbox','searchbox','combobox'].includes(role);
  const nativeEditable = element.isContentEditable || ['TEXTAREA','SELECT'].includes(element.tagName)
    || (element.tagName === 'INPUT' && ['text','search','email','url','tel','number','date','datetime-local','month','week','time','color'].includes(element.type));
  const editable = editableRole && nativeEditable;
  const password = element.tagName === 'INPUT' && element.type === 'password';
  const value = editable && !password ? String(element.isContentEditable ? element.innerText : element.value ?? '') : null;
  const link = role === 'link' ? String(element.href || '') : null;
  // Keep the destination observable without offering an action this backend
  // must reject. Task input never creates or adopts an unowned popup.
  const popupOnlyLink = element.tagName === 'A' && !!element.target
    && !['_self','_top','_parent'].includes(element.target.toLowerCase());
  const tooLarge = name.length > 4096 || (value?.length || 0) > 4096 || (link?.length || 0) > 2048;
  const disabled = !!element.disabled || !!element.closest('[disabled], [aria-disabled="true"]') || password || tooLarge;
  const readOnly = !!element.readOnly || element.getAttribute('aria-readonly') === 'true' || password || tooLarge || (editableRole && !nativeEditable);
  return {role, name:name.slice(0,4096), value:password ? null : value?.slice(0,4096) ?? null,
    linkURL:link?.slice(0,2048) ?? null, isDisabled:disabled, isReadOnly:readOnly, isEditable:editable && !readOnly,
    isIgnored:false, isDOMClickable:!popupOnlyLink && ['button','link','checkbox','radio','switch','tab','menuitem'].includes(role),
    isPressUnsupported:popupOnlyLink,
    isFocusablePointer:false, fieldTruncated:tooLarge};
};
const capture = () => {
  const nodes = [], next = [{node:document.body || document.documentElement, parent:null, suppressText:false}];
  let visited = 0, budget = 0, truncated = false;
  state.nodes.clear();
  while (next.length) {
    const item = next.pop(), node = item.node;
    if (++visited > 20000 || nodes.length >= 3000 || budget > 220000) { truncated = true; break; }
    if (node.nodeType === Node.TEXT_NODE) {
      const text = trim(node.textContent);
      if (item.suppressText || !text || !node.parentElement || !visible(node.parentElement)) continue;
      const id = idFor(node), name = text.slice(0,4096);
      truncated ||= text.length > 4096;
      nodes.push({backendNodeID:id,nodeID:String(id),parentNodeID:item.parent,childNodeIDs:[],role:'statictext',name,
        value:null,isDisabled:true,isReadOnly:true,isIgnored:false,isDOMClickable:false,isPressUnsupported:false,isFocusablePointer:false,isEditable:false,linkURL:null});
      budget += name.length * 3 + 200;
      continue;
    }
    if (node.nodeType !== Node.ELEMENT_NODE || !visible(node) || ['SCRIPT','STYLE','NOSCRIPT','TEMPLATE'].includes(node.tagName)) continue;
    // This backend covers the main light DOM only. Never imply exhaustive
    // document coverage when a frame or shadow tree is not traversed.
    if (node.tagName === 'IFRAME' || node.tagName === 'FRAME' || node.shadowRoot || oversizedRole(node.getAttribute('role') || '')) truncated = true;
    const role = roleFor(node);
    let parent = item.parent, suppressText = item.suppressText;
    if (role) {
      const id = idFor(node), meta = metaFor(node, role);
      truncated ||= meta.fieldTruncated;
      delete meta.fieldTruncated;
      nodes.push({backendNodeID:id,nodeID:String(id),parentNodeID:parent,childNodeIDs:[],...meta});
      state.nodes.set(id,node);
      budget += JSON.stringify(meta).length * 3 + 200;
      parent = String(id);
      suppressText = ['button','link','heading','statictext','textbox','searchbox','combobox','image'].includes(role);
    }
    const children = Array.from(node.childNodes);
    for (let index = children.length - 1; index >= 0; index--) next.push({node:children[index],parent,suppressText});
  }
  const byID = new Map(nodes.map(node => [node.nodeID,node]));
  for (const node of nodes) if (node.parentNodeID && byID.has(node.parentNodeID)) byID.get(node.parentNodeID).childNodeIDs.push(node.nodeID);
  return {loaderID:input.documentToken, title:String(document.title).slice(0,512), url:location.href, nodes, sourceTruncated:truncated};
};
const isSemanticNode = node =>
  ['button','link','checkbox','combobox','searchbox','textbox','menu','menubar','menuitem',
    'menuitemcheckbox','menuitemradio','radio','radiogroup','switch','tab','tablist',
    'toolbar','slider','spinbutton','listbox','option','treeitem'].includes(node.role)
  || (['statictext','inlinetextbox','text','heading','paragraph','listitem','term','definition',
    'code','blockquote','cell','gridcell','rowheader','columnheader','caption','label'].includes(node.role)
    && !!trim(node.name || node.value));
const hasSemanticContent = snapshot => snapshot.nodes.some(isSemanticNode);
// Only empty semantic shells wait. A meaningful page returns immediately;
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
  const result = await waitForCapture(hasSemanticContent);
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
if (!element?.isConnected || !visible(element)) throw new Error('element_changed');
const current = metaFor(element, roleFor(element));
delete current.fieldTruncated;
let semanticParent = element.parentElement;
while (semanticParent && !roleFor(semanticParent)) semanticParent = semanticParent.parentElement;
const parentID = semanticParent ? String(idFor(semanticParent)) : null;
if (parentID !== input.expected.parentNodeID) throw new Error('element_changed');
for (const key of ['role','name','value','linkURL','isDisabled','isReadOnly','isEditable','isDOMClickable','isPressUnsupported'])
  if (current[key] !== input.expected[key]) throw new Error('element_changed');
if (current.isDisabled || input.expectedURL !== location.href) throw new Error('stale_document');
element.scrollIntoView({block:'center',inline:'center'});
const rect = element.getBoundingClientRect();
const hit = document.elementFromPoint(rect.left + rect.width/2, rect.top + rect.height/2);
if (rect.width <= 0 || rect.height <= 0 || !hit || (hit !== element && !element.contains(hit))) throw new Error('element_obstructed');
if (input.operation === 'press') {
  if (!current.isDOMClickable || typeof element.click !== 'function') throw new Error('unsupported_action');
  if (element.tagName === 'A' && element.target && !['_self','_top','_parent'].includes(element.target.toLowerCase())) throw new Error('popup_unsupported');
  element.click();
} else {
  if (!current.isEditable || current.isReadOnly) throw new Error('unsupported_action');
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

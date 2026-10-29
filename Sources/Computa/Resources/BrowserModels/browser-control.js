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
const subtreeExclusion = element => {
  for (let node = element; node; node = node.parentElement) {
    // Form named properties can shadow HTMLElement.hidden with a child input.
    // Only the actual attribute hides this ancestor.
    if (Element.prototype.hasAttribute.call(node, 'hidden')
        || node.getAttribute('aria-hidden') === 'true' || node.hasAttribute('inert')) return 'hard_hidden';
    if (getComputedStyle(node).display === 'none') return 'display_none';
  }
  return null;
};
const allowedByAncestors = element => subtreeExclusion(element) === null;
// Visibility is inherited but a descendant can explicitly restore it. It
// suppresses this node's rendered content, not traversal of its whole subtree.
// Hard exclusions above still apply to every descendant without exception.
const renderedVisibility = element => !['hidden','collapse'].includes(getComputedStyle(element).visibility);
// Input targets still need their own rendered box. A display:contents wrapper
// may be traversed below, but that does not make it an input target.
const visible = element => allowedByAncestors(element) && renderedVisibility(element) && element.getClientRects().length > 0;
const visibleText = node => {
  const parent = node.parentElement;
  if (!parent || !allowedByAncestors(parent) || !renderedVisibility(parent)) return false;
  if (parent.getClientRects().length > 0) return true;
  if (getComputedStyle(parent).display !== 'contents') return false;
  const range = document.createRange();
  range.selectNodeContents(node);
  return range.getClientRects().length > 0;
};
const semanticRoleFor = element => {
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
  // Native fields keep their own semantics even when WebKit reports inherited
  // contenteditable=true from an enclosing editing host.
  if (tag === 'textarea' || tag === 'select') return tag === 'select' ? 'combobox' : 'textbox';
  if (element.isContentEditable) return 'textbox';
  return ({a: element.hasAttribute('href') ? 'link' : null, button:'button',
    main:'main', article:'article', nav:'navigation', aside:'complementary', header:'banner', footer:'contentinfo', dialog:'dialog', form:'form',
    ul:'list', ol:'list', li:'listitem', p:'statictext', pre:'statictext', blockquote:'statictext', img:'image',
    section: element.getAttribute('aria-label') ? 'region' : null, output:'status'})[tag] || null;
};
// Only explicit, rendered naming establishes passive container ancestry. Do
// not manufacture a group name from all of its descendants or field values.
const explicitContainerName = element => {
  const labelled = trim(element.getAttribute('aria-labelledby'));
  if (labelled) {
    if (labelled.length > 4096) return '';
    const ids = labelled.split(' ');
    if (ids.length > 32 || new Set(ids).size !== ids.length) return '';
    const names = [];
    for (const id of ids) {
      const label = document.getElementById(id);
      if (!label || !visible(label) || label.matches('input,textarea,select,[contenteditable]')
          || label.querySelector('input,textarea,select,[contenteditable],[hidden],[aria-hidden="true"],[inert]')) return '';
      const name = trim(label.innerText);
      if (!name) return '';
      names.push(name);
    }
    return trim(names.join(' '));
  }
  return trim(element.getAttribute('aria-label'));
};
const isPassiveContainer = element => ['DIV','SECTION'].includes(element.tagName)
  && !trim(element.getAttribute('role')) && !semanticRoleFor(element) && !!explicitContainerName(element);
const roleFor = element => semanticRoleFor(element) || (isPassiveContainer(element) ? 'group' : null);
const nameFor = (element, role, boxlessContents = false) => {
  if (role === 'group' && isPassiveContainer(element)) return explicitContainerName(element);
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
  // Structural containers do not need a second copy of every descendant's
  // text as their fallback name. On a large inbox/table that duplication can
  // consume the entire capture budget before a later form is reached. Keep
  // explicit accessible labels above, and capture visible child text below.
  if (['application','main','article','navigation','complementary','banner','contentinfo','list','listitem','region',
    'group','generic','dialog','alertdialog','form','table','grid','treegrid','rowgroup','row','cell','gridcell',
    'toolbar','menu','menubar','listbox','radiogroup','tablist','tree'].includes(role)) return '';
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
const nativeValueField = element => ['INPUT','TEXTAREA','SELECT'].includes(element.tagName);
const nativeEditable = element => element.tagName === 'INPUT'
  ? ['text','search','email','url','tel','number','date','datetime-local','month','week','time','color'].includes(element.type)
  : ['TEXTAREA','SELECT'].includes(element.tagName) || element.isContentEditable;
const metaFor = (element, role, boxlessContents = false) => {
  const name = nameFor(element, role, boxlessContents);
  const passiveContainer = role === 'group' && isPassiveContainer(element);
  const editableRole = ['textbox','searchbox','combobox'].includes(role);
  const editable = editableRole && nativeEditable(element);
  const password = element.tagName === 'INPUT' && element.type === 'password';
  const value = editable && !password && !boxlessContents ? String(nativeValueField(element) ? element.value ?? '' : element.innerText) : null;
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
  const disabled = !!element.disabled || !!element.closest('[disabled], [aria-disabled="true"]') || password || tooLarge || passiveContainer;
  const readOnly = !!element.readOnly || element.getAttribute('aria-readonly') === 'true' || password || tooLarge || passiveContainer || (editableRole && !editable);
  return {role, name:name.slice(0,4096), value:password ? null : value?.slice(0,4096) ?? null,
    linkURL:link?.slice(0,2048) ?? null, isDisabled:disabled, isReadOnly:readOnly, isEditable:editable && !readOnly,
    isIgnored:false, isDOMClickable:!popupOnlyLink && (interactiveItem || ['button','link','checkbox','radio','switch','tab','menuitem'].includes(role)),
    isPressUnsupported:popupOnlyLink || passiveContainer,
    isFocusablePointer:false, constraintValidation:constraintsFor(element, boxlessContents), fieldTruncated:tooLarge,
    ...(['group','region'].includes(role) ? {isExplicitlyNamedContainer:!!explicitContainerName(element)} : {})};
};
const capture = () => {
  const root = document.body || document.documentElement;
  // The source budget is independent of native result pagination. Traversing
  // a long inbox first can permanently omit its appended compose dialog from
  // every cursor page. Prefer the live focus branch, visible form/dialog
  // branches and observed controls in named panels, keeping their real ancestors.
  // Discovery reads only bounded structure/attributes, never field values or
  // innerText. It grants no action capability and does not claim completeness.
  const priorities = new Map();
  const prioritize = (element, priority) => {
    if (!element || element === root || !visible(element)) return;
    const path = [];
    for (let node = element; node && node !== root && path.length < 128; node = node.parentElement) path.push(node);
    if (!path.length || path[path.length - 1].parentElement !== root) return;
    for (const node of path) priorities.set(node, Math.min(priorities.get(node) ?? 3, priority));
  };
  prioritize(document.activeElement, 0);
  let examinedChildren = 0, panelProbes = 0, partialPanels = 0, discoveryLimitReached = false;
  // Finite positive evidence from the existing structural discovery pass.
  // Counts describe encountered panels only, never the whole DOM or a site.
  // Order: rendered, display:none, hard-hidden, visibility-hidden, no own box.
  const panelsByState = [0, 0, 0, 0, 0];
  let prunedSubtrees = 0;
  const controlsSeen = new Set(), controlsVisible = new Set(), controlsPrioritized = new Set();
  const prioritizePanelControls = (element, priority) => {
    const pending = [{node:element}], targets = [];
    let slots = 0, control = false, partial = false;
    panelProbes++;
    for (let index = 0; index < pending.length; index++) {
      const cursor = pending[index], node = cursor.node;
      if (!cursor.children) {
        if (['SCRIPT','STYLE','NOSCRIPT','TEMPLATE'].includes(node.tagName) || !allowedByAncestors(node)) continue;
        const semantic = semanticRoleFor(node);
        const isControl = ['button','link','textbox','searchbox','combobox','checkbox','radio','switch','tab','menuitem','slider']
          .includes(semantic);
        if (isControl) controlsSeen.add(node);
        if ((isControl || semantic === 'heading') && visible(node)) {
          if (isControl) controlsVisible.add(node);
          control ||= isControl; targets.push(node);
        }
        cursor.children = node.childNodes;
        cursor.first = 0; cursor.last = cursor.children.length - 1; cursor.tail = false;
      }
      if (cursor.first > cursor.last) continue;
      if (slots >= 64 || examinedChildren >= 4096) {
        partial = true; discoveryLimitReached ||= examinedChildren >= 4096; continue;
      }
      // Interleave both ends and deeper branches within the same per-panel and
      // shared caps, so a wide expanded panel cannot spend every slot before
      // reaching the observed controls nested inside its header or footer.
      const child = cursor.children[cursor.tail ? cursor.last-- : cursor.first++];
      cursor.tail = !cursor.tail; slots++; examinedChildren++;
      if (child.nodeType === Node.ELEMENT_NODE) pending.push({node:child});
      if (cursor.first <= cursor.last) pending.push(cursor);
    }
    if (partial) partialPanels++;
    // A discovered panel alone is insufficient: later prioritized branches
    // can bury its ordinary descendants. Keep observed controls, heading
    // context and their actual ancestors ahead of background text. Partial
    // discovery does not imply missing controls are absent or grant input rights.
    if (control) for (const target of targets) {
      prioritize(target, priority);
      if (controlsVisible.has(target) && priorities.has(target)) controlsPrioritized.add(target);
    }
    return control;
  };
  const discovery = root ? [{node:root}] : [];
  let discoveryIndex = 0;
  for (; discoveryIndex < discovery.length && examinedChildren < 4096; discoveryIndex++) {
    const cursor = discovery[discoveryIndex], node = cursor.node;
    if (!cursor.children) {
      if (node.nodeType !== Node.ELEMENT_NODE || ['SCRIPT','STYLE','NOSCRIPT','TEMPLATE'].includes(node.tagName)) continue;
      const exclusion = subtreeExclusion(node);
      const rawRole = node.getAttribute('role') || '';
      const role = oversizedRole(rawRole) ? '' : trim(rawRole).split(' ')[0].toLowerCase();
      if (['dialog','alertdialog','form'].includes(role) || ['DIALOG','FORM'].includes(node.tagName)) {
        const state = exclusion === 'display_none' ? 1 : exclusion === 'hard_hidden' ? 2
          : !renderedVisibility(node) ? 3 : node.getClientRects().length === 0 ? 4 : 0;
        panelsByState[state]++;
      }
      if (exclusion) { prunedSubtrees++; continue; }
      const semantic = semanticRoleFor(node);
      if (['dialog','alertdialog'].includes(role) || node.tagName === 'DIALOG') {
        prioritize(node, 1); prioritizePanelControls(node, 1);
      }
      else if (role === 'form' || node.tagName === 'FORM') {
        prioritize(node, 2); prioritizePanelControls(node, 2);
      }
      // Expanded panels need not use FORM or
      // dialog semantics. Preserve real text-entry branches without reading
      // their values or treating ARIA alone as editability.
      else if (['textbox','searchbox','combobox'].includes(semantic) && nativeEditable(node)) prioritize(node, 2);
      else if (['DIV','SECTION'].includes(node.tagName) && (!semantic || ['group','region','toolbar'].includes(semantic))
        && ['aria-label','aria-labelledby'].some(name => {
          const value = node.getAttribute(name) || '';
          return value.length <= 4096 && !!trim(value);
        }) && prioritizePanelControls(node, 2)) prioritize(node, 2);
      cursor.children = node.childNodes;
      cursor.first = 0; cursor.last = cursor.children.length - 1; cursor.tail = false;
    }
    if (cursor.first > cursor.last) continue;
    if (examinedChildren >= 4096) { discoveryLimitReached = true; continue; }
    // Interleave child cursors across branches instead of exhausting a wide
    // inbox before descending into a later panel. Sample both ends; normal
    // capture and its evidence graph still retain the actual DOM child order.
    const child = cursor.children[cursor.tail ? cursor.last-- : cursor.first++];
    cursor.tail = !cursor.tail; examinedChildren++;
    if (child.nodeType === Node.ELEMENT_NODE) discovery.push({node:child});
    if (cursor.first <= cursor.last) discovery.push(cursor);
  }
  discoveryLimitReached ||= examinedChildren >= 4096 && discoveryIndex < discovery.length;
  const nodes = [], next = [[{node:root, parent:null, suppressText:false, hiddenAncestor:null}], [], [], []];
  const capturedDOMNodes = new Map(), emittedByPriority = [0, 0, 0, 0];
  let visited = 0, budget = 0, truncated = false, omittedPriority = null;
  const diagnostics = {stopReason:'none',visited:0,emitted:0,estimatedBytes:0,
    visibilityState:['visible','hidden','prerender'].includes(document.visibilityState) ? document.visibilityState : 'unknown',
    viewportWidth:Number.isInteger(innerWidth) && innerWidth >= 0 && innerWidth <= 1000000 ? innerWidth : 0,
    viewportHeight:Number.isInteger(innerHeight) && innerHeight >= 0 && innerHeight <= 1000000 ? innerHeight : 0,
    frames:0,shadowRoots:0,oversizedRoles:0,clippedFields:0,boxlessContents:0};
  const appendCaptured = (row, node, bytes, hiddenAncestor, priority) => {
    const ancestors = [];
    for (let current = hiddenAncestor; current; current = current.previous) {
      if (capturedDOMNodes.has(current.row.nodeID)) break;
      ancestors.push(current);
    }
    ancestors.reverse();
    const additions = [...ancestors, {row,node,bytes}];
    const addedBytes = additions.reduce((sum, item) => sum + item.bytes, 0);
    if (nodes.length + additions.length > 3000 || budget + addedBytes > 220000) {
      diagnostics.stopReason = nodes.length + additions.length > 3000 ? 'node_limit' : 'byte_budget';
      omittedPriority = priority; truncated = true; return false;
    }
    // Flush the required chain atomically: no public child can outlive omitted
    // ancestry, and shared priority paths cannot emit the same ancestor twice.
    for (const item of additions) {
      nodes.push(item.row); capturedDOMNodes.set(item.row.nodeID, item.node);
      if (item.node.nodeType === Node.ELEMENT_NODE) state.nodes.set(item.row.backendNodeID, item.node);
      emittedByPriority[priority]++; budget += item.bytes;
    }
    return true;
  };
  state.nodes.clear();
  while (next.some(frontier => frontier.length)) {
    // A priority applies across the capture, not just between siblings. A
    // focused ancestor must not drain its ordinary inbox descendants before
    // another discovered dialog/form branch. Propagated ancestor priorities
    // retain parent-before-child capture; each frontier keeps DFS ordering.
    const selectedPriority = next.findIndex(frontier => frontier.length);
    const item = next[selectedPriority].pop(), node = item.node;
    if (++visited > 20000 || nodes.length >= 3000 || budget > 220000) {
      diagnostics.stopReason = visited > 20000 ? 'visited_limit' : nodes.length >= 3000 ? 'node_limit' : 'byte_budget';
      omittedPriority = selectedPriority; truncated = true; break;
    }
    if (node.nodeType === Node.TEXT_NODE) {
      const text = trim(node.textContent);
      if (item.suppressText || !text || !visibleText(node)) continue;
      const id = idFor(node), name = text.slice(0,4096);
      truncated ||= text.length > 4096;
      if (text.length > 4096) diagnostics.clippedFields++;
      const row = {backendNodeID:id,nodeID:String(id),parentNodeID:item.parent,childNodeIDs:[],role:'statictext',name,
        value:null,isDisabled:true,isReadOnly:true,isIgnored:false,isDOMClickable:false,isPressUnsupported:false,isFocusablePointer:false,isEditable:false,linkURL:null};
      if (!appendCaptured(row, node, name.length * 3 + 200, item.hiddenAncestor, selectedPriority)) break;
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
    const visibilitySuppressed = !renderedVisibility(node);
    let parent = item.parent, suppressText = item.suppressText, hiddenAncestor = item.hiddenAncestor;
    if (role) {
      // Keep only ignored structural ancestry for hidden nodes. In particular,
      // do not publish their names, field values or constraints. Visible children
      // retain their real semantic scope and exact parent identity, without
      // making the hidden wrapper an observed control or outcome witness.
      const id = idFor(node), meta = visibilitySuppressed
        ? {role,name:'',value:null,linkURL:null,isDisabled:true,isReadOnly:true,isEditable:false,
          isIgnored:true,isDOMClickable:false,isPressUnsupported:true,isFocusablePointer:false,
          constraintValidation:null,fieldTruncated:false}
        : metaFor(node, role, boxlessContents);
      truncated ||= meta.fieldTruncated;
      if (meta.fieldTruncated) diagnostics.clippedFields++;
      delete meta.fieldTruncated;
      if (boxlessContents) {
        // Retain landmarks/control ancestry so descendants are not reclassified
        // as body text, while withholding every no-box wrapper input capability.
        meta.isDisabled = true; meta.isReadOnly = true; meta.isEditable = false;
        meta.isDOMClickable = false; meta.isFocusablePointer = false; meta.isPressUnsupported = true;
      }
      const row = {backendNodeID:id,nodeID:String(id),parentNodeID:parent,childNodeIDs:[],...meta};
      const bytes = JSON.stringify(meta).length * 3 + 200;
      if (visibilitySuppressed) {
        // Hidden-only legacy trees spend traversal slots, not snapshot rows.
        // Retain this shared chain only if a rendered descendant is emitted.
        hiddenAncestor = {row,node,bytes,previous:hiddenAncestor};
      } else {
        if (!appendCaptured(row, node, bytes, hiddenAncestor, selectedPriority)) break;
        hiddenAncestor = null;
      }
      parent = String(id);
      suppressText = !visibilitySuppressed && !boxlessContents && ['button','link','heading','statictext','textbox','searchbox','combobox','image'].includes(role);
    }
    const children = [[], [], [], []];
    for (const child of Array.from(node.childNodes)) children[priorities.get(child) ?? 3].push(child);
    for (let priority = children.length - 1; priority >= 0; priority--)
      for (let index = children[priority].length - 1; index >= 0; index--)
        next[priority].push({node:children[priority][index],parent,suppressText,hiddenAncestor});
  }
  const byID = new Map(nodes.map(node => [node.nodeID,node]));
  for (const node of nodes) if (node.parentNodeID && byID.has(node.parentNodeID)) byID.get(node.parentNodeID).childNodeIDs.push(node.nodeID);
  // Selection order is only a read-priority choice. Preserve actual DOM sibling
  // order in the evidence graph so moving focus cannot manufacture a changed
  // region or child-position witness. This sorts only the bounded captured IDs.
  for (const node of nodes) node.childNodeIDs.sort((left, right) => {
    const position = capturedDOMNodes.get(left).compareDocumentPosition(capturedDOMNodes.get(right));
    return position & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : position & Node.DOCUMENT_POSITION_PRECEDING ? 1 : 0;
  });
  let controlsEmitted = 0;
  for (const node of capturedDOMNodes.values()) {
    if (controlsPrioritized.has(node)) controlsEmitted++;
  }
  const queued = next.map((frontier, priority) => frontier.length + (omittedPriority === priority ? 1 : 0));
  diagnostics.scheduling = {discoverySlots:examinedChildren,panelProbes,partialPanels,
    controlsSeen:controlsSeen.size,controlsVisible:controlsVisible.size,controlsPrioritized:controlsPrioritized.size,
    controlsEmitted,emittedByPriority,pendingByPriority:queued.map(count => Math.min(count,20001)),
    pendingClipped:queued.some(count => count > 20001)};
  diagnostics.discovery = {panelsByState,prunedSubtrees,limitReached:discoveryLimitReached};
  diagnostics.visited = visited; diagnostics.emitted = nodes.length; diagnostics.estimatedBytes = budget;
  return {loaderID:input.documentToken, title:String(document.title).slice(0,512), url:location.href, nodes,
    sourceTruncated:truncated,captureDiagnostics:diagnostics};
};
const isSemanticNode = node => !node.isIgnored && (
  ['button','link','checkbox','combobox','searchbox','textbox','menu','menubar','menuitem',
    'menuitemcheckbox','menuitemradio','radio','radiogroup','switch','tab','tablist',
    'toolbar','slider','spinbutton','listbox','option','treeitem'].includes(node.role)
  || (['statictext','inlinetextbox','text','heading','paragraph','listitem','term','definition',
    'code','blockquote','cell','gridcell','rowheader','columnheader','caption','label'].includes(node.role)
    && !!trim(node.name || node.value)));
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
    if (node.isIgnored || !(trim(node.name) || String(node.value ?? '')) || !(textRoles.has(node.role) || node.role === 'option')) return false;
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
// This private finite envelope diagnoses a failed action without claiming
// whether input was dispatched. Native preserves its generic no-replay error.
// Only rejection objects created here map to known codes; page/native throws
// cannot smuggle messages, labels or values into the diagnostic.
const actionRejections = new WeakMap();
const rejectAction = code => {
  const error = new Error('browser_action_rejected');
  actionRejections.set(error, code); throw error;
};
let actionStage = 'initial_revalidation';
let actionHitTest = null;
try {
const element = state.nodes.get(input.nodeID);
const revalidateElement = () => {
  if (globalThis[key] !== state || state.documentToken !== input.documentToken) rejectAction('stale_document');
  if (state.nodes.get(input.nodeID) !== element || !element?.isConnected || !visible(element)) rejectAction('element_changed');
  const current = metaFor(element, roleFor(element));
  delete current.fieldTruncated;
  let semanticParent = element.parentElement;
  while (semanticParent && !roleFor(semanticParent)) semanticParent = semanticParent.parentElement;
  const parentID = semanticParent ? String(idFor(semanticParent)) : null;
  if (parentID !== input.expected.parentNodeID) rejectAction('element_changed');
  for (const key of ['role','name','value','linkURL','isDisabled','isReadOnly','isEditable','isDOMClickable','isPressUnsupported'])
    if (current[key] !== input.expected[key]) rejectAction('element_changed');
  if (current.isDisabled || input.expectedURL !== location.href) rejectAction('stale_document');
  return current;
};
// Failure-only geometry classes. Preserve the existing hit-test call and
// rejection order; no added layout reads on successful input, raw coordinates,
// names, classes or arbitrary attributes leave this private world.
const hitTestFailureDiagnostic = (rect, hit) => {
  try {
    const x = rect.left + rect.width/2, y = rect.top + rect.height/2;
    const axis = (center, extent) => !Number.isFinite(center) || !Number.isFinite(extent) || extent <= 0
      ? 'unknown' : center < 0 ? 'before' : center >= extent ? 'after' : 'inside';
    const centerX = axis(x, innerWidth), centerY = axis(y, innerHeight);
    const nonfinite = ![rect.left, rect.top, rect.width, rect.height, x, y].every(Number.isFinite);
    const reason = nonfinite ? 'rect_nonfinite' : rect.width <= 0 || rect.height <= 0 ? 'rect_nonpositive'
      : [centerX,centerY].some(value => value === 'before' || value === 'after') ? 'outside_viewport'
        : !hit ? 'null_hit' : 'foreign_hit';
    const tags = ['input','textarea','select','button','div','span','iframe','body','html'];
    const tag = hit?.tagName;
    const hitTag = !hit ? 'none' : typeof tag === 'string' && tag.length <= 16 && tags.includes(tag.toLowerCase())
      ? tag.toLowerCase() : 'other';
    const roles = ['dialog','alertdialog','listbox','option','combobox','textbox','button','menu','menuitem','tooltip'];
    const rawRole = hit?.getAttribute?.('role');
    const role = typeof rawRole === 'string' && rawRole.length <= 100 ? trim(rawRole).split(' ')[0].toLowerCase() : null;
    const hitRole = !hit || rawRole == null || rawRole === '' ? 'none' : roles.includes(role) ? role : 'other';
    const relation = !hit ? 'none' : hit === element ? 'self' : element.contains(hit) ? 'descendant'
      : hit.contains?.(element) ? 'ancestor' : 'other';
    return {reason,centerX,centerY,hitTag,hitRole,relation};
  } catch { return null; } // Diagnostics cannot replace the original rejection.
};
const requireUnobstructed = () => {
  const rect = element.getBoundingClientRect();
  const hit = document.elementFromPoint(rect.left + rect.width/2, rect.top + rect.height/2);
  if (rect.width <= 0 || rect.height <= 0 || !hit || (hit !== element && !element.contains(hit))) {
    actionHitTest = hitTestFailureDiagnostic(rect, hit);
    rejectAction('element_obstructed');
  }
};
const current = revalidateElement();
actionStage = 'scroll';
element.scrollIntoView({block:'center',inline:'center'});
actionStage = 'initial_hit_test';
requireUnobstructed();
let constraintFeedback = null;
if (input.operation === 'press') {
  actionStage = 'press_precheck';
  if (!current.isDOMClickable || typeof element.click !== 'function') rejectAction('unsupported_action');
  if (element.tagName === 'A' && element.target && !['_self','_top','_parent'].includes(element.target.toLowerCase())) rejectAction('popup_unsupported');
  // Observe only native synchronous invalid events in this exact submit
  // control's form. This neither validates the form nor changes event delivery.
  // A click handler may still perform another action, including a request.
  const submit = (element.tagName === 'BUTTON' && element.type === 'submit')
    || (element.tagName === 'INPUT' && ['submit','image'].includes(element.type));
  const form = submit ? element.form : null;
  const fields = [], seen = new Set();
  let truncated = false;
  const invalid = event => {
    const field = event.target, id = state.ids.get(field);
    if (!event.isTrusted || !form || field.form !== form || !id
        || state.nodes.get(id) !== field || !visible(field) || seen.has(id)) return;
    const constraints = constraintsFor(field, false);
    if (!constraints?.candidate || constraints.valid || !constraints.issues.length) return;
    if (fields.length >= 3) { truncated = true; return; }
    seen.add(id);
    fields.push({backendNodeID:id, issues:constraints.issues});
  };
  if (form) window.addEventListener('invalid', invalid, true);
  actionStage = 'press_dispatch';
  try { element.click(); }
  finally { if (form) window.removeEventListener('invalid', invalid, true); }
  actionStage = 'constraint_feedback';
  if (fields.length) constraintFeedback = {fields, truncated};
} else {
  actionStage = 'focus';
  if (!current.isEditable || current.isReadOnly) rejectAction('unsupported_action');
  if (typeof element.focus !== 'function') rejectAction('unsupported_action');
  // Focus belongs to this admitted page field only; it never activates a native
  // window. Synchronous focus handlers may replace the field or change its scope.
  element.focus({preventScroll:true});
  actionStage = 'focused_revalidation';
  revalidateElement();
  actionStage = 'focus_confirmation';
  if (document.activeElement !== element) rejectAction('element_changed');
  actionStage = 'focused_hit_test';
  requireUnobstructed();
  actionStage = 'value_write';
  if (nativeValueField(element)) {
    const prototype = element.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : element.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype,'value')?.set;
    if (!setter) rejectAction('unsupported_action');
    setter.call(element,input.text);
  } else element.textContent = input.text;
  actionStage = 'input_event';
  element.dispatchEvent(new Event('input',{bubbles:true}));
  actionStage = 'change_event';
  element.dispatchEvent(new Event('change',{bubbles:true}));
}
return {dispatched:true, noReplay:true, constraintFeedback};

} catch (error) {
  const code = actionRejections.get(error) || 'unexpected';
  return {browserActionFailure:{version:1,operation:input.operation,stage:actionStage,code,
    ...(code === 'element_obstructed' && actionHitTest ? {hitTest:actionHitTest} : {})}};
}

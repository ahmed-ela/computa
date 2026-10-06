// Fixed ChatGPT DOM adapter derived from BrowserExtension/web-providers.js.
// Runs in a private WebKit content world; input arrives as structured arguments.
function chatGPTMessageRoots(role) {
  const selector = `[data-message-author-role="${role}"], [data-markdown-text-style="${role}-message"], article[data-turn="${role}"]`
    + (role === 'user' ? ', [data-user-message-bubble]' : '');
  const nodes = [...document.querySelectorAll(selector)];
  return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
}
function chatGPTUserBody(root) {
  return root.querySelector('[data-markdown-text-style="user-message"]')
    || root.querySelector('.whitespace-pre-wrap') || root.querySelector('[data-message-author-role="user"]') || root;
}
function chatGPTTemporaryVerified() {
  const visible = node => node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
  const buttons = [...document.querySelectorAll('button')].filter(visible);
  return buttons.some(node => node.getAttribute('aria-label') === 'Turn off temporary chat')
    || new URL(document.URL).searchParams.get('temporary-chat') === 'true'
      && buttons.some(node => node.getAttribute('aria-label') === 'Save chat' || (node.innerText || '').trim() === 'Save chat');
}
function chatGPTStructure(visible) {
  const buttons = [...document.querySelectorAll('button')].filter(visible).filter(button =>
    ['Copy', 'Copy message'].includes(button.getAttribute('aria-label') || (button.textContent || '').trim()))
    .sort((a, b) => Number(a.getAttribute('aria-label') === 'Copy message') - Number(b.getAttribute('aria-label') === 'Copy message')).slice(0, 3);
  // Preserve the one diagnostic receipt until the assistant footer exists.
  if (!buttons.some(button => !button.disabled && button.getAttribute('aria-disabled') !== 'true'
    && (button.getAttribute('aria-label') || (button.textContent || '').trim()) === 'Copy')) return '';
  const safeRoles = ['article', 'button', 'group', 'main', 'textbox', 'list', 'listitem', 'presentation', 'none'];
  const ancestorsOf = start => {
    const ancestors = [];
    for (let node = start, depth = 0; node && depth < 20; node = node.parentElement, depth++) {
      const role = node.getAttribute('role'), turn = node.getAttribute('data-turn');
      const author = node.getAttribute('data-message-author-role'), style = node.getAttribute('data-markdown-text-style');
      const testId = node.getAttribute('data-testid');
      const metadata = { tag: /^[a-zA-Z0-9-]{1,24}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'other',
        ...(safeRoles.includes(role) ? { role } : {}),
        ...(turn ? { turn: ['user', 'assistant'].includes(turn) ? turn : 'other' } : {}),
        ...(author ? { author: ['user', 'assistant'].includes(author) ? author : 'other' } : {}),
        ...(style ? { style: ['user-message', 'assistant-message'].includes(style) ? style : 'other' } : {}),
        ...(testId && /^[a-z0-9_-]{1,64}$/.test(testId) ? { testId } : {}),
        dataAttributes: [...node.attributes].map(attribute => attribute.name)
          .filter(name => /^data-[a-z0-9_-]{1,32}$/.test(name)).sort().slice(0, 8) };
      if (metadata.dataAttributes.length || role || turn || author || style || testId) ancestors.push(metadata);
    }
    return ancestors;
  };
  const replyBodies = [];
  if (typeof document.createTreeWalker === 'function') {
    const walker = document.createTreeWalker(document.body, 4);
    for (let textNode = walker.nextNode(); textNode; textNode = walker.nextNode()) {
      const text = (textNode.nodeValue || '').trim();
      const parent = textNode.parentElement;
      if (!parent || parent.closest('[data-user-message-bubble]') || text.length > 220_000 || !text.startsWith('{')) continue;
      let value; try { value = JSON.parse(text); } catch { continue; }
      if (!['tool_calls', 'message'].includes(value?.type)) continue;
      const ancestors = [];
      for (let node = parent, depth = 0; node && depth < 6; node = node.parentElement, depth++) {
        ancestors.push({ tag: node.tagName.toLowerCase(),
          classes: [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)).slice(0, 4),
          dataAttributes: [...node.attributes].map(attribute => attribute.name)
            .filter(name => /^data-[a-z0-9_-]{1,32}$/.test(name)).sort().slice(0, 8) });
      }
      replyBodies.push({ kind: value.type, ancestors });
      break;
    }
  }
  const structure = { bodies: replyBodies,
    copies: buttons.slice(0, 1).map(button => ({ kind: 'response_copy', ancestors: ancestorsOf(button) })),
    articleCount: document.querySelectorAll('article').length,
    articleUsers: document.querySelectorAll('article[data-turn="user"]').length,
    articleAssistants: document.querySelectorAll('article[data-turn="assistant"]').length,
    markdownBodies: document.querySelectorAll('.markdown').length,
    preservedUserBodies: document.querySelectorAll('.whitespace-pre-wrap').length };
  // Always emit complete JSON, reducing only diagnostic ancestry if necessary.
  let serialized = JSON.stringify(structure);
  while (serialized.length > 8192) {
    const longest = [...structure.copies, ...structure.bodies].sort((a, b) => b.ancestors.length - a.ancestors.length)[0];
    if (!longest?.ancestors.length) return '';
    longest.ancestors.pop();
    serialized = JSON.stringify(structure);
  }
  return serialized;
}
async function providerPageAction(input) {
  const { provider, action, expectedConversation, expectedConversationIdentity, expectedUserCounts, expectedFirstUserMarker,
    expectedFirstUserIdentity, expectedFirstUserFingerprint, expectedURL, prompt } = input;
  if (window !== window.top || document.URL !== expectedURL) return { error: "document_changed", detail: "document_url" };
  const origin = ({ chatgpt: "https://chatgpt.com", gemini: "https://gemini.google.com", claude: "https://claude.ai" })[provider];
  if (location.origin !== origin) return { error: "sign_in_required" };
  // Foundation's URL.path decodes the colon in ChatGPT's local-chatgpt%3A ID.
  // Compare that same canonical path while document.URL remains exact above.
  const cleanURL = location.origin + decodeURIComponent(location.pathname).replace(/\/$/, "");
  if (expectedConversation && cleanURL !== expectedConversation) return { error: "conversation_changed", detail: "conversation_route" };
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
  const conversationIdentities = provider === "chatgpt" ? [...new Set([...document.querySelectorAll("[data-chatgpt-selection-conversation-id]")]
    .filter(visible).map(node => node.getAttribute("data-chatgpt-selection-conversation-id")).filter(Boolean))] : [];
  const conversationIdentity = conversationIdentities.length === 1 ? conversationIdentities[0] : null;
  if (expectedConversationIdentity && conversationIdentity !== expectedConversationIdentity) return { error: "conversation_changed", detail: "conversation_identity" };
  const enabled = node => visible(node) && !node.disabled && node.getAttribute("aria-disabled") !== "true";
  const find = selectors => selectors.flatMap(selector => [...document.querySelectorAll(selector)]).find(visible);
  const labelled = (nodes, expression) => [...nodes].filter(visible).find(node => expression.test(
    [node.getAttribute("aria-label"), node.getAttribute("data-testid"), node.getAttribute("title"), node.innerText].filter(Boolean).join(" ").trim()));
  const composer = provider === "chatgpt" ? find(['#prompt-textarea[contenteditable="true"]', 'textarea#prompt-textarea', '#prompt-textarea [contenteditable="true"]', '[contenteditable="true"][aria-label="Ask ChatGPT"]', 'textarea[data-testid="prompt-textarea"]'])
    : provider === "claude" ? find(['[data-testid="chat-input"][contenteditable="true"][role="textbox"]'])
    : find(['rich-textarea [contenteditable="true"]', 'div.ql-editor[contenteditable="true"]']);
  const modernChatGPTAnswers = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')].filter(visible);
  const responseNodes = provider === "chatgpt"
    ? chatGPTMessageRoots('assistant').map(node => node.getAttribute('data-markdown-text-style') === 'assistant-message' ? node
      : node.querySelector('[data-markdown-text-style="assistant-message"]') || node.querySelector('.markdown')
        || node.querySelector('[data-message-author-role="assistant"]')
        || (node.getAttribute('data-message-author-role') === 'assistant' ? node : null)).filter(visible)
    : provider === "claude" ? [...document.querySelectorAll('[data-testid="assistant-message"] [data-perf-reply-text]')].filter(visible)
    : [...document.querySelectorAll(".model-response-text, model-response .markdown")].filter(visible);
  // Avoid duplicate Gemini descendants when the provider adds a wrapper class.
  const answers = responseNodes.filter(node => !responseNodes.some(other => other !== node && other.contains(node)));
  const claudeUsers = provider === "claude" ? [...document.querySelectorAll('[data-testid="user-message"]')] : [];
  const userCount = provider === "chatgpt" ? chatGPTMessageRoots('user').length
    : provider === "claude" ? claudeUsers.length
    : document.querySelectorAll("user-query").length;
  if (provider === "claude" && (!Array.isArray(expectedUserCounts) || !expectedUserCounts.includes(userCount)))
    return { error: "conversation_changed" };
  let firstUserIdentity = null, firstUserFingerprint = null, firstUserMarkerVerified = false;
  if (provider === "claude" && userCount > 0) {
    const firstUser = claudeUsers[0];
    const owner = firstUser.closest("[id]");
    const normalizedBody = (firstUser.innerText || firstUser.textContent || "").replace(/\r\n?/g, "\n").normalize("NFC").trim();
    firstUserIdentity = owner?.getAttribute("id");
    firstUserMarkerVerified = typeof expectedFirstUserMarker === "string" && expectedFirstUserMarker.length > 0
      && normalizedBody.split("\n").some(line => line.trim() === `Computa session marker: ${expectedFirstUserMarker}`);
    if (!firstUserMarkerVerified || typeof firstUserIdentity !== "string" || firstUserIdentity.length === 0
      || firstUserIdentity.length > 256 || normalizedBody.length > 180_200
      || expectedFirstUserIdentity && firstUserIdentity !== expectedFirstUserIdentity
      || !expectedFirstUserFingerprint && ["prepare", "submit"].includes(action)) return { error: "conversation_changed" };
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(normalizedBody));
    firstUserFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    // Digesting yields the event loop. Recheck the same first DOM message and
    // rendered body before reading an answer or performing any mutation.
    const currentUsers = [...document.querySelectorAll('[data-testid="user-message"]')];
    if (document.URL !== expectedURL || !firstUser.isConnected || currentUsers.length !== userCount || currentUsers[0] !== firstUser
      || firstUser.closest("[id]") !== owner || owner.getAttribute("id") !== firstUserIdentity
      || (firstUser.innerText || firstUser.textContent || "").replace(/\r\n?/g, "\n").normalize("NFC").trim() !== normalizedBody
      || expectedFirstUserFingerprint && firstUserFingerprint !== expectedFirstUserFingerprint) return { error: "conversation_changed" };
  }
  const stop = provider === "chatgpt" ? find(['button[data-testid="stop-button"]', 'button[aria-label="Stop streaming"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]'])
    : provider === "claude" ? find(['button[aria-label="Stop response"]'])
    : find(['button[aria-label="Stop response"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]', 'button.stop-button']);
  const claudeStatus = provider === "claude" ? find(['[data-testid="response-status-announcer"][role="status"]']) : null;
  const interrupted = !!claudeStatus && (claudeStatus.textContent || "").trim().replace(/’/g, "'") === "Claude's response was interrupted.";
  const claudeStreaming = provider === "claude" && [...document.querySelectorAll('[data-testid="assistant-message"][data-is-streaming="true"]')].some(visible);
  const answer = answers.at(-1);
  const answerText = answer ? (answer.innerText || answer.textContent || "").trim() : "";
  let answerComplete = false;
  const completionEvidence = { modernMarkers: modernChatGPTAnswers.length, logicalAnswers: answers.length,
    scopedCopies: 0, enabledCopies: 0, depth: -1 };
  if (provider === "chatgpt" && answer) {
    // The current Copy footer is a sibling of the selection wrapper. Keep the
    // search inside an ancestor containing only this one physical answer;
    // nested marker wrappers do not create another message.
    for (let node = answer, depth = 0; node && depth < 10; node = node.parentElement, depth++) {
      if (answers.filter(other => node === other || node.contains(other)).length > 1) break;
      const copies = [...node.querySelectorAll('.turn-action-controls button[aria-label="Copy"], button[data-testid="copy-turn-action-button"], button[aria-label="Copy"]')];
      completionEvidence.scopedCopies = copies.length;
      completionEvidence.enabledCopies = copies.filter(enabled).length;
      completionEvidence.depth = depth;
      if (completionEvidence.enabledCopies) { answerComplete = true; break; }
    }
  } else if (provider === "claude" && answer) {
    const message = answer.closest('[data-testid="assistant-message"]');
    const article = answer.closest('[role="article"]');
    const copy = article?.querySelector('[data-testid="message-actions"] button[data-testid="action-bar-copy"][aria-label="Copy"]');
    answerComplete = !interrupted && message?.getAttribute("data-is-streaming") === "false"
      && article?.querySelectorAll('[data-testid="assistant-message"]').length === 1 && enabled(copy);
  } else if (answer) {
    answerComplete = !!answer.closest("model-response")?.querySelector('button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]');
  }
  const claudeExit = provider === "claude" ? find(['button[aria-label="Exit incognito"]']) : null;
  const claudeIncognitoBadge = claudeExit && new URL(document.URL).searchParams.has("incognito")
    && [...document.querySelectorAll(".animate-incognito-header-in span")].find(node => visible(node)
      && (node.textContent || "").trim() === "Incognito chat");
  const temporary = provider === "claude" ? !!claudeIncognitoBadge : provider === "chatgpt"
    ? chatGPTTemporaryVerified()
    : !!find(['button[aria-label="Turn off temporary chat"]', 'button[aria-label="Exit temporary chat"]'])
      || [...document.querySelectorAll('h1, h2, span.info-text')].some(node => visible(node)
        && !node.closest('button, [role="menu"], [role="tooltip"], model-response, user-query')
        && ["Just stopping by?", "Temporary Chat"].includes((node.textContent || "").trim()));
  const state = { url: document.URL, temporary, conversationIdentity, composer: !!composer, responseCount: answers.length, userCount,
    firstUserIdentity, firstUserFingerprint, firstUserMarkerVerified,
    busy: !!stop || claudeStreaming, interrupted, text: answerText.slice(0, 220_001), answerComplete, completionEvidence };
  if (action === "inspect") {
    const signIn = !composer && !!labelled(document.querySelectorAll('a, button'), /^(?:Log in|Sign in)(?:\s|$)/i);
    return { ...state, signIn, debugStructure: chatGPTStructure(visible) };
  }
  if (action === "enableTemporary") {
    if (temporary) return { ...state, enabled: true };
    if (userCount || answers.length) return { error: "not_fresh" };
    const toggle = provider === "claude" ? find(['button[aria-label="Use incognito"]'])
      : find(['button[aria-label="Temporary chat"]']);
    if (!enabled(toggle)) return { error: "temporary_mode_unavailable" };
    toggle.click(); return { ...state, enabled: false };
  }
  if (["prepare", "insert", "sendReady", "submit", "stop"].includes(action) && !temporary)
    return { error: "temporary_mode_unverified" };
  if (action === "insert") {
    if (!enabled(composer) || stop) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if (value?.trim() || typeof prompt !== "string" || prompt.length > 180000)
      return { error: "composer_not_empty" };
    if (userCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || typeof expectedFirstUserMarker !== "string"
        || !/^[a-f0-9-]{36}$/i.test(expectedFirstUserMarker)
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return { error: "conversation_changed", detail: "first_user_message" };
      // This is insertion data, not ownership proof. The marker becomes
      // authoritative only at the exact-text check immediately before Send.
      globalThis.__computaModelFirstPrompt = prompt;
    }
    composer.focus();
    if (composer instanceof HTMLTextAreaElement) {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value").set.call(composer, prompt);
      composer.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: prompt }));
    } else {
      // A background WebKit editor can have focus without an editing caret.
      // Select only this empty, owned composer before the single insertion.
      const selection = window.getSelection();
      if (!selection) return { error: "caret_unavailable" };
      const range = document.createRange();
      range.selectNodeContents(composer);
      range.collapse(false);
      selection.removeAllRanges();
      selection.addRange(range);
      if (!composer.contains(selection.anchorNode) || !composer.contains(selection.focusNode))
        return { error: "caret_unavailable" };
      if (composer.classList.contains("ProseMirror")) {
        // Native editing commands can apply macOS text substitutions. Build one
        // literal paragraph with hard line breaks and let the editor observe it.
        const paragraph = document.createElement("p");
        prompt.split("\n").forEach((line, index) => {
          if (index) paragraph.appendChild(document.createElement("br"));
          paragraph.appendChild(document.createTextNode(line));
        });
        composer.replaceChildren(paragraph);
        range.selectNodeContents(paragraph);
        range.collapse(false);
        selection.removeAllRanges();
        selection.addRange(range);
        composer.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: prompt }));
      } else if (!document.execCommand("insertText", false, prompt))
          return { error: "insert_command_rejected" };
    }
    return { ...state, inserted: true };
  }
  if (action === "prepare") {
    if (!enabled(composer) || stop || claudeStreaming) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if (value?.trim()) return { error: "composer_not_empty" };
    composer.focus();
    return { ...state, prepared: document.activeElement === composer || composer.contains(document.activeElement) };
  }
  if (action === "submit" || action === "sendReady") {
    if (!enabled(composer) || stop || claudeStreaming) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    const actual = (value || "").replace(/\r\n/g, "\n").trim();
    const expected = prompt.trim();
    if (actual !== expected) {
      // Report shape only, never prompt or page text.
      const detail = !actual ? "editor_empty"
        : actual.replace(/\n+/g, "\n") === expected.replace(/\n+/g, "\n") ? "line_break_expansion"
        : actual.replace(/\u00a0/g, " ") === expected ? "nonbreaking_spaces" : "text_difference";
      return { error: "prompt_not_inserted", detail, actualLength: actual.length,
        expectedLength: expected.length, actualLines: actual.split("\n").length, expectedLines: expected.split("\n").length };
    }
    const send = provider === "chatgpt" ? find(['button[data-testid="send-button"]', 'button[aria-label="Send prompt"]', 'button[aria-label="Send message"]', 'button[aria-label="Send"]'])
      : provider === "claude" ? find(['button[data-testid="chat-input-send"][aria-label="Send message"]'])
      : find(['button[aria-label="Send message"]', 'button[aria-label="Send"]', 'button.send-button']);
    if (action === "sendReady") return { ...state, sendReady: enabled(send) };
    if (!enabled(send)) return { error: "send_unavailable" };
    if (userCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || globalThis.__computaModelFirstPrompt !== prompt
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return { error: "conversation_changed", detail: "first_user_message" };
      globalThis.__computaModelFirstMarker = expectedFirstUserMarker;
      globalThis.__computaModelFirstSubmitted = true;
    }
    send.click();
    return { submitted: true };
  }
  if (action === "stop") { if (enabled(stop)) stop.click(); return { stopped: !!stop }; }
  return { error: "unknown_action" };
}

if (window !== window.top || location.origin !== "https://chatgpt.com" || document.URL !== input.expectedURL)
  return { error: "document_changed", detail: "document_url" };
if (globalThis.__computaModelOwner !== input.ownerToken) {
  if (input.bindOwner && globalThis.__computaModelOwner === undefined)
    globalThis.__computaModelOwner = input.ownerToken;
  else return { error: "document_changed", detail: "owner_token" };
}
if (globalThis.__computaModelSignal?.ownerToken !== input.ownerToken) {
  const signal = { ownerToken: input.ownerToken, queued: false, observer: null };
  signal.observer = new MutationObserver(records => {
    if (!records.length || signal.queued) return;
    signal.queued = true;
    // Batch streaming mutations into one wake-up; this timer is scheduled
    // only by an actual change, never as a recurring website poll.
    setTimeout(() => {
      signal.queued = false;
      if (window !== window.top || location.origin !== "https://chatgpt.com"
        || globalThis.__computaModelOwner !== signal.ownerToken) return;
      // This notification carries no page content and grants no native action.
      // The native receiver validates this exact model view and ownership again.
      try {
        window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({
          ownerToken: signal.ownerToken, kind: "dom_changed"
        });
      } catch { }
    }, 100);
  });
  signal.observer.observe(document.documentElement || document, {
    subtree: true, childList: true, characterData: true, attributes: true,
    attributeFilter: ["disabled", "aria-disabled", "aria-hidden", "aria-busy", "aria-label", "class", "style",
      "title", "hidden", "inert", "contenteditable", "data-testid", "data-is-streaming",
      "data-message-author-role", "data-markdown-text-style", "data-chatgpt-selection-conversation-id", "data-turn",
      "data-user-message-bubble"]
  });
  globalThis.__computaModelSignal = signal;
}
const ownedMessages = chatGPTMessageRoots('user');
const ownedUserCount = ownedMessages.length;
if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.includes(ownedUserCount))
  return { error: "conversation_changed", detail: "user_count" };
let firstUserVerified = false;
let firstUserFingerprint = null;
let firstSnapshot = null;
const normalizedFirstBody = node => (node.innerText || node.textContent || "")
  .replace(/\r\n?/g, "\n").normalize("NFC").trim();
const snapshotUnchanged = (allowSubmittedUser = false) => {
  const current = chatGPTMessageRoots('user');
  return window === window.top && location.origin === "https://chatgpt.com" && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken
    && (current.length === ownedUserCount || allowSubmittedUser && current.length === ownedUserCount + 1)
    && current[0] === firstSnapshot.root && firstSnapshot.body.isConnected
    && chatGPTUserBody(current[0]) === firstSnapshot.body
    && normalizedFirstBody(firstSnapshot.body) === firstSnapshot.text;
};
if (ownedUserCount > 0) {
  const marker = input.expectedFirstUserMarker;
  const first = chatGPTUserBody(ownedMessages[0]);
  const rendered = normalizedFirstBody(first);
  const markerLine = `Computa session marker: ${marker}`;
  const renderedLines = rendered.split("\n");
  if (typeof marker !== "string" || !/^[a-f0-9-]{36}$/i.test(marker)
    || globalThis.__computaModelFirstSubmitted !== true || globalThis.__computaModelFirstMarker !== marker
    || rendered.length > 180_200
    || renderedLines.at(-1) !== markerLine || renderedLines.filter(line => line === markerLine).length !== 1
    || !renderedLines.slice(0, -1).join("\n").trim())
    return { error: "conversation_changed", detail: "first_user_message" };
  firstSnapshot = { root: ownedMessages[0], body: first, text: rendered };
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rendered));
  if (!snapshotUnchanged()) return { error: "conversation_changed", detail: "first_user_message" };
  if (!chatGPTTemporaryVerified()) return { error: "temporary_mode_unverified" };
  firstUserFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  const pinned = globalThis.__computaModelFirstProof;
  if (pinned) {
    if (pinned.marker !== marker || pinned.fingerprint !== firstUserFingerprint
      || input.expectedFirstUserFingerprint !== pinned.fingerprint
        && !(input.expectedFirstUserFingerprint == null && input.allowFirstUserBinding === true
          && input.action === "inspect" && ownedUserCount === 1))
      return { error: "conversation_changed", detail: "first_user_message" };
  } else {
    // Only the native pending first submission may bind rendered lineage.
    // Markdown is lossy; exact outbound bytes were checked before one Send.
    if (input.action !== "inspect" || input.allowFirstUserBinding !== true || ownedUserCount !== 1
      || input.expectedFirstUserFingerprint != null)
      return { error: "conversation_changed", detail: "first_user_message" };
  }
  // Pin only after this same document still confirms the owned temporary chat.
  const observed = await providerPageAction(input);
  if (!snapshotUnchanged(input.action === "submit"))
    return { error: "conversation_changed", detail: "first_user_message" };
  if (!chatGPTTemporaryVerified()) return { error: "temporary_mode_unverified" };
  if (observed.error) return observed;
  if (!pinned) {
    if (observed.temporary !== true) return { error: "temporary_mode_unverified" };
    globalThis.__computaModelFirstProof = { marker, fingerprint: firstUserFingerprint };
  }
  firstUserVerified = true;
  return { ...observed, firstUserVerified, firstUserFingerprint, firstUserMarkerVerified: true };
}
if (input.expectedFirstUserFingerprint != null)
  return { error: "conversation_changed", detail: "first_user_message" };
return { ...await providerPageAction(input), firstUserVerified, firstUserFingerprint };

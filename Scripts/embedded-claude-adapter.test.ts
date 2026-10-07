import { describe, expect, test } from "bun:test";
import { Element, fixture, firstMarker, markerLine } from "./embedded-provider-adapter-fixture";
import { defineWebsiteModelChoiceTests } from "./embedded-model-choice-tests";
const provider = "claude";
const prompt = 'Use `tool_calls` with C++ "quoted" text\n\n  two spaces and\u00a0NBSP';
const outbound = prompt + "\n\n" + markerLine;

defineWebsiteModelChoiceTests(provider, (owned = false) => fixture(provider, owned ? { userPrompt: 'Synthetic owned prompt' } : {}), Element);

function observedClaudeCodeBlock(f: ReturnType<typeof fixture>, raw: string) {
  f.answer.text = ""; f.answer.children = [];
  const wrapper = new Element("DIV", { class: "relative border-border-400" });
  const container = new Element("DIV", { class: "absolute right-0 h-8 px-2 items-center inline-flex" });
  const control = new Element("BUTTON", { class: "cds-reset relative isolate inline-flex shrink-0 items-center" });
  const content = new Element("SPAN", { class: "inline-flex min-w-0 items-center gap-1" });
  const icon = new Element("SPAN", {}, "\uE056"); content.append(icon); control.append(content); container.append(control);
  const label = new Element("DIV", { class: "text-text-500 font-small pb-0" }, "json");
  const pre = new Element("PRE"), code = new Element("CODE", {}, raw); pre.append(code);
  wrapper.append(container, label, pre); f.answer.append(wrapper);
  Object.defineProperty(f.answer, "innerText", { get: () => "\uE056\njson\n" + raw });
  return { wrapper, container, control, content, icon, label, pre, code };
}

function observedClaudeQuota(f: ReturnType<typeof fixture>, inert = true) {
  const background = new Element("DIV", inert ? { inert: "", "aria-hidden": "true" } : {});
  background.append(...f.body.children); f.body.children = []; f.body.append(background);
  const dialog = new Element("DIV");
  const heading = new Element("H2", {}, "Your free messages return at 11:40 PM");
  const upgrade = new Element("BUTTON", {}, "Upgrade to Pro for $20/month");
  const plans = new Element("BUTTON", {}, "See all plans");
  const dismiss = new Element("BUTTON", {}, "Not now");
  dialog.append(heading, upgrade, plans, dismiss); f.body.append(dialog);
  return { background, dialog, heading, upgrade, plans, dismiss };
}

function observedClaudeBanner(f: ReturnType<typeof fixture>, clock = "11:40 PM") {
  const container = new Element("DIV"), warning = new Element("SPAN");
  const support = new Element("A", { href: "https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits" }, "messages");
  warning.append(new Element("#text", {}, "You are out of free "), support, new Element("#text", {}, " until " + clock));
  const upgrade = new Element("A", { href: "https://claude.ai/upgrade?hide_free=true&from=ratelimit" }, "Upgrade");
  container.append(warning, upgrade); f.body.append(container);
  return { container, warning, support, upgrade };
}
const freshQuotaReceipt = (f: ReturnType<typeof fixture>) => ({ error: "website_usage_limit", freshQuotaAbort: true,
  url: f.document.URL, userCount: 0, responseCount: 0 });

describe("embedded Claude fixed adapter", () => {
  test("a sole fenced envelope preserves literal JSON escapes and code-block controls", async () => {
    for (const envelope of [
      { type: "message", text: 'Literal "quoted" text, C:\\tmp\\file\nnext line\\n stays literal' },
      { type: "tool_calls", calls: [{ name: "exec_command", arguments: { cmd: 'printf "quoted\\n"\npath="C:\\tmp\\file"' } }] },
    ]) {
      const f = fixture(provider, { userPrompt: prompt });
      const raw = "\n" + JSON.stringify(envelope) + "\n";
      f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, raw);
      pre.append(code, new Element("BUTTON", { "aria-label": "Copy code" }, "Copy code")); f.answer.append(pre);
      // Emulate the exact failure: the site's rendered Markdown loses JSON escapes.
      const rendered = raw.replace(/\\"/g, '"').replace(/\\\\/g, "\\").replace(/\\n/g, "\n");
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      const result = await f.run();
      expect(result.text).toBe(raw);
      expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.text).not.toContain("Copy code");
      expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 1, codeCount: 1,
        codeTextLength: raw.length, outsideTextLength: 0, outsideTruncated: false });
      expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain('quoted');
    }
  });

  test("observed Claude code chrome admits only its literal sole JSON envelope", async () => {
    for (const envelope of [
      { type: "message", text: 'It\'s "quoted" C:\\tmp\\path\nnext line' },
      { type: "tool_calls", calls: [{ name: "exec_command", arguments: { cmd: 'printf "literal\\n"\nprintf "It\'s quoted"' } }] },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }), raw = "\n" + JSON.stringify(envelope) + "\n";
      observedClaudeCodeBlock(f, raw);
      const result = await f.run();
      expect(result.text).toBe(raw); expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.text).not.toContain("\uE056"); expect(result.text).not.toContain("json\n");
    }
  });

  test("Claude code chrome does not excuse mismatched structure or authored content", async () => {
    for (const change of [
      (f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.wrapper.values.class = "relative border-other"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.class = "font-small pb-0"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.text = "JSON"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.append(new Element("EM", {}, "")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.container.values.class = "right-0 h-8 px-2 items-center inline-flex"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.control.values.class = "relative isolate inline-flex shrink-0 items-center"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.icon.text = "Author control text"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.control.values.hidden = ""; },
      (f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.wrapper.children = block.wrapper.children.filter(node => node !== block.container); f.answer.append(block.container); },
      (f: ReturnType<typeof fixture>, _block: ReturnType<typeof observedClaudeCodeBlock>) => { f.answer.append(new Element("P", {}, "Author prose")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.container.append(new Element("BUTTON", {}, "Other outside button")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.wrapper.append(new Element("DIV", { class: "text-text-500 font-small pb-0" }, "json")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, '{}')); block.wrapper.append(extra); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedClaudeCodeBlock>) => { block.code.text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }), raw = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"literal"}}]}';
      const block = observedClaudeCodeBlock(f, raw); change(f, block);
      expect((await f.run()).text).toBe("\uE056\njson\n" + raw);
      expect(f.send.clicks).toBe(0);
    }
  });

  test("outside code-header diagnostics expose only static categories and bounded ancestry", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    f.answer.text = ""; f.answer.children = [];
    const wrapper = new Element("DIV", { class: "provider-code-wrapper", id: "private-account-id" });
    wrapper.append(new Element("SPAN", {}, "\uE056"), new Element("SPAN", {}, "json"));
    const pre = new Element("PRE"), raw = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"private command"}}]}';
    pre.append(new Element("CODE", {}, raw)); wrapper.append(pre); f.answer.append(wrapper);
    const result = await f.run();
    // Header acceptance needs actual website evidence; diagnostics cannot grant it.
    expect(result.text).toBe("\uE056json" + raw);
    const diagnostic = result.completionEvidence.codeStructure;
    expect(diagnostic).toMatchObject({ preCount: 1, codeCount: 1, outsideTextLength: 5, outsideTruncated: false });
    expect(diagnostic.outsideNodes.map((node: any) => node.kind)).toEqual(["private_use", "json"]);
    expect(diagnostic.outsideNodes[1].ancestors).toContainEqual({ tag: "div", classes: ["provider-code-wrapper"], preDescendants: 1, copyControls: 0 });
    expect(JSON.stringify(diagnostic)).not.toContain("private command"); expect(JSON.stringify(diagnostic)).not.toContain("private-account-id");
    expect(JSON.stringify(diagnostic)).not.toContain(firstMarker); expect(JSON.stringify(diagnostic).length).toBeLessThanOrEqual(8192);
  });

  test("prose, extra blocks, multiple code bodies and non-envelopes keep rendered extraction", async () => {
    for (const change of [
      (answer: Element, _pre: Element) => { answer.text = "Author prose before the block"; },
      (answer: Element, _pre: Element) => { answer.append(new Element("P", {}, "Author prose after the block")); },
      (answer: Element, _pre: Element) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, '{"type":"message","text":"OTHER"}')); answer.append(extra); },
      (_answer: Element, pre: Element) => { pre.append(new Element("CODE", {}, '{"type":"message","text":"OTHER"}')); },
      (_answer: Element, pre: Element) => { pre.text = "Author text outside its code body"; },
      (_answer: Element, pre: Element) => { pre.children[0].text = '{"type":"example","text":"quoted"}'; },
      (_answer: Element, pre: Element) => { pre.children[0].text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture(provider, { userPrompt: prompt });
      f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, '{"type":"message","text":"quoted\\""}');
      pre.append(code); f.answer.append(pre); change(f.answer, pre);
      const rendered = "Rendered response still requires strict codec validation";
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      const result = await f.run();
      expect(result.text).toBe(rendered);
      expect(result.completionEvidence.codeStructure.preCount).toBeGreaterThanOrEqual(1);
      expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain('Author prose');
    }
  });

  test("an owned fresh page enables temporary mode once and verifies real UI evidence", async () => {
    const f = fixture(provider, { temporary: false });
    expect(await f.run()).toMatchObject({ temporary: false, userCount: 0, responseCount: 0 });
    expect(await f.run("enableTemporary")).toMatchObject({ enabled: false });
    expect(f.toggle.clicks).toBe(1);
    expect(await f.run()).toMatchObject({ temporary: true });
    expect(await f.run("enableTemporary")).toMatchObject({ enabled: true });
    expect(f.toggle.clicks).toBe(1);
  });

  test("composer readiness cannot authorize a delayed, disabled or vanished mode toggle", async () => {
    const f = fixture(provider, { temporary: false }); f.toggle.connected = false;
    expect(await f.run()).toMatchObject({ composer: true, temporary: false, temporaryActionAvailable: false });
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined(); expect(f.toggle.clicks).toBe(0);
    f.toggle.connected = true; f.toggle.disabled = true;
    expect(await f.run()).toMatchObject({ temporaryActionAvailable: false });
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined();
    f.toggle.disabled = false;
    expect(await f.run()).toMatchObject({ temporary: false, temporaryActionAvailable: true });
    f.toggle.connected = false;
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined(); expect(f.toggle.clicks).toBe(0);
    f.toggle.connected = true;
    expect(await f.run("enableTemporary")).toMatchObject({ enabled: false });
    expect(f.toggle.clicks).toBe(1); expect(f.world.__computaModelTemporaryRequested).toBe(true);
    expect(await f.run()).toMatchObject({ temporary: true });
  });

  test("a lost toggle result is never retried or allowed to send in normal mode", async () => {
    const f = fixture(provider, { temporary: false });
    f.toggle.onClick = () => { throw new Error("fixture lost click acknowledgment"); };
    await expect(f.run("enableTemporary")).rejects.toThrow("fixture lost");
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unverified" });
    expect(await f.run("insert", { prompt: outbound })).toMatchObject({ error: "temporary_mode_unverified" });
    expect(f.toggle.clicks).toBe(1); expect(f.send.clicks).toBe(0);
  });

  test("temporary text inside a model message cannot spoof the mode header", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    f.header.connected = false; f.exit.connected = false;
    const forged = new Element(provider === "claude" ? "DIV" : "SPAN", provider === "claude" ? { class: "animate-incognito-header-in" } : { class: "info-text" });
    if (provider === "claude") forged.append(new Element("SPAN", {}, "Incognito chat")); else forged.text = "Temporary Chat";
    f.answer.append(forged);
    expect(await f.run()).toMatchObject({ error: "temporary_mode_unverified" });
    expect(f.world.__computaModelFirstProof).toBeUndefined();
    expect(f.send.clicks).toBe(0);
  });

  test("hidden evidence and a disabled toggle never authorize temporary mode", async () => {
    const f = fixture(provider, { temporary: false });
    f.badge.connected = true; f.badge.values.visibility = "hidden";
    if (provider === "claude") f.exit.connected = true;
    expect(await f.run()).toMatchObject({ temporary: false });
    f.toggle.disabled = true;
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.toggle.clicks).toBe(0);
  });

  test("the exact quota popup reports its limit before any inference action or blocked control click", async () => {
    for (const action of ["inspect", "enableTemporary", "prepare", "insert", "sendReady", "submit"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run();
      const popup = observedClaudeQuota(f); f.stop.connected = true;
      expect(await f.run(action, { prompt: outbound })).toEqual({ error: "website_usage_limit" });
      expect(f.send.clicks).toBe(0); expect(f.stop.clicks).toBe(0); expect(f.toggle.clicks).toBe(0);
      expect(popup.upgrade.clicks).toBe(0); expect(popup.dismiss.clicks).toBe(0);
      expect(f.composer.innerText).toBe("");
    }
  });

  test("quota cleanup inspects only the owned physical Incognito indicators without interacting", async () => {
    const f = fixture(provider, { userPrompt: prompt }); const original = await f.run();
    const popup = observedClaudeQuota(f); f.stop.connected = true;
    expect(await f.run("stop")).toMatchObject({ usageLimited: true, temporary: true, busy: false, stopped: false,
      firstUserVerified: true, firstUserFingerprint: original.firstUserFingerprint, firstUserMarkerVerified: true, userCount: 1 });
    expect(await f.run("inspect")).toEqual({ error: "website_usage_limit" });
    for (const control of [f.stop, f.send, f.exit, f.toggle, popup.upgrade, popup.dismiss]) expect(control.clicks).toBe(0);
  });

  test("observed doubled UI heading spacing keeps exact quota identity without changing message bytes", async () => {
    const exact = prompt + "\n  message spacing stays exact";
    const f = fixture(provider, { userPrompt: exact }); const original = await f.run(), body = f.userBody!.innerText;
    const popup = observedClaudeQuota(f);
    popup.heading.text = "Your free messages return at  11:40 PM";
    popup.upgrade.text = "Upgrade to Pro for\n $20/month";
    popup.dismiss.text = "Not\u00a0now";
    expect(await f.run()).toEqual({ error: "website_usage_limit" });
    expect(await f.run("stop")).toMatchObject({ temporary: true, usageLimited: true,
      firstUserFingerprint: original.firstUserFingerprint });
    expect(f.userBody!.innerText).toBe(body); expect(f.send.clicks).toBe(0); expect(popup.dismiss.clicks).toBe(0);
  });

  test("the observed reset heading and non-purchase controls identify quota independently of upgrade price rendering", async () => {
    for (const price of ["Upgrade to Pro for $20 / month", "Upgrade to Pro for\n$20\n/month", "Upgrade to Pro", "Upgrade for €18/month"]) {
      const f = fixture(provider, { userPrompt: prompt }); const original = await f.run();
      const popup = observedClaudeQuota(f); popup.heading.tagName = "H1"; popup.upgrade.text = price;
      expect(await f.run("prepare")).toEqual({ error: "website_usage_limit" });
      expect(await f.run("stop")).toMatchObject({ usageLimited: true, temporary: true, busy: false, stopped: false,
        firstUserFingerprint: original.firstUserFingerprint });
      for (const control of [popup.upgrade, popup.plans, popup.dismiss, f.send, f.exit, f.stop]) expect(control.clicks).toBe(0);
    }
  });

  test("quota cleanup cannot bind a new first message or bypass its unchanged identity and digest", async () => {
    const unbound = fixture(provider, { userPrompt: prompt }); observedClaudeQuota(unbound);
    expect(await unbound.run("inspect")).toEqual({ error: "website_usage_limit" });
    expect(unbound.world.__computaModelFirstProof).toBeUndefined();
    expect(await unbound.run("stop")).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.userBody!.text = f.userBody!.text.replace("C++", "Changed schema"); },
      (f: ReturnType<typeof fixture>) => { f.userRoot!.parentElement!.values.id = "replacement-id"; },
      (f: ReturnType<typeof fixture>) => { f.world.__computaModelOwner = "foreign"; },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); observedClaudeQuota(f); mutate(f);
      expect(["conversation_changed", "document_changed"]).toContain((await f.run("stop")).error);
      expect(f.send.clicks).toBe(0);
    }
    const counts = fixture(provider, { userPrompt: prompt }); await counts.run(); observedClaudeQuota(counts);
    expect(await counts.run("stop", { expectedUserCounts: [0] })).toMatchObject({ error: "conversation_changed", detail: "user_count" });
  });

  test("unknown, incomplete, hidden or message-authored quota text never grants modal cleanup visibility", async () => {
    for (const change of [
      (p: ReturnType<typeof observedClaudeQuota>) => { p.dialog.tagName = "BODY"; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.heading.text = "Unknown error"; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.heading.text = "Your free messages return at 25:99 PM"; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.plans.text = "View plans"; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.plans.tagName = "A"; p.plans.values.role = "button"; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.plans.disabled = true; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.plans.values.visibility = "hidden"; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.dismiss.text = "Close"; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.dismiss.disabled = true; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.dialog.values.hidden = ""; },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.dialog.append(p.heading.cloneNode(true)); },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.dialog.append(p.plans.cloneNode(true)); },
      (p: ReturnType<typeof observedClaudeQuota>) => { p.dialog.children = p.dialog.children.filter(node => node !== p.plans);
        p.dialog.parentElement!.append(p.plans); },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); const popup = observedClaudeQuota(f); change(popup);
      expect(await f.run("stop")).toMatchObject({ error: "temporary_mode_unverified" });
      expect(f.send.clicks).toBe(0); expect(popup.dismiss.clicks).toBe(0);
    }
    const authored = fixture(provider, { userPrompt: prompt }); await authored.run();
    const popup = observedClaudeQuota(authored, false);
    authored.body.children = authored.body.children.filter(node => node !== popup.dialog); authored.answer.append(popup.dialog);
    expect(await authored.run()).toMatchObject({ firstUserVerified: true });
    authored.header.values.inert = ""; authored.exit.values["aria-hidden"] = "true";
    expect(await authored.run("stop")).toMatchObject({ error: "temporary_mode_unverified" });
  });

  test("a known quota cannot substitute missing, hidden, authored or non-Incognito mode evidence", async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.document.URL = f.origin + "/new"; },
      (f: ReturnType<typeof fixture>) => { f.exit.connected = false; },
      (f: ReturnType<typeof fixture>) => { f.badge.text = "Regular chat"; },
      (f: ReturnType<typeof fixture>) => { f.badge.values.visibility = "hidden"; },
      (f: ReturnType<typeof fixture>) => { f.header.parentElement!.children = f.header.parentElement!.children.filter(node => node !== f.header); f.answer.append(f.header); },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); observedClaudeQuota(f); mutate(f);
      expect(await f.run("stop")).toMatchObject({ error: "temporary_mode_unverified" });
      expect(f.send.clicks).toBe(0); expect(f.exit.clicks).toBe(0);
    }
  });

  test("a quota appearing during a guarded digest or focus remains a finite limit failure", async () => {
    const duringDigest = fixture(provider, { userPrompt: prompt }); await duringDigest.run();
    duringDigest.onDigest(() => { observedClaudeQuota(duringDigest); });
    expect(await duringDigest.run()).toEqual({ error: "website_usage_limit" });
    const duringFocus = fixture(provider, { userPrompt: prompt }); await duringFocus.run();
    duringFocus.composer.onFocus = () => { duringFocus.document.activeElement = duringFocus.composer; observedClaudeQuota(duringFocus); };
    expect(await duringFocus.run("prepare")).toEqual({ error: "website_usage_limit" });
    for (const f of [duringDigest, duringFocus]) expect(f.send.clicks).toBe(0);
  });

  test("the observed split rate-limit banner couples official messages and upgrade links without fixing reset time", async () => {
    for (const clock of ["11:40 PM", "1:05 AM", "12:00 PM"]) {
      const f = fixture(provider, { userPrompt: prompt }); const before = await f.run();
      const banner = observedClaudeBanner(f, clock);
      // Query order is irrelevant to the exact two reviewed upgrade parameters.
      banner.upgrade.values.href = "https://claude.ai/upgrade?from=ratelimit&hide_free=true";
      expect(await f.run()).toEqual({ error: "website_usage_limit" });
      expect(await f.run("submit", { prompt: outbound })).toEqual({ error: "website_usage_limit" });
      expect(await f.run("stop")).toMatchObject({ usageLimited: true, temporary: true, busy: false, stopped: false,
        firstUserFingerprint: before.firstUserFingerprint });
      expect(f.send.clicks).toBe(0); expect(banner.support.clicks).toBe(0); expect(banner.upgrade.clicks).toBe(0);
    }
    const fresh = fixture(provider); observedClaudeBanner(fresh);
    expect(await fresh.run()).toEqual(freshQuotaReceipt(fresh));
    expect(fresh.world.__computaModelFirstProof).toBeUndefined();
  });

  test("only an empty initial quota inspection emits the exact abort receipt for owned native cleanup", async () => {
    for (const popup of [false, true]) {
      const f = fixture(provider);
      if (popup) observedClaudeQuota(f); else observedClaudeBanner(f);
      expect(await f.run()).toEqual(freshQuotaReceipt(f));
      expect(f.document.activeElement).toBeNull(); expect(f.send.clicks).toBe(0);
      for (const action of ["enableTemporary", "prepare", "insert", "sendReady", "submit"])
        expect(await f.run(action, { prompt: outbound })).toEqual({ error: "website_usage_limit" });
      expect(f.world.__computaModelFirstPrepared).toBeUndefined();
      expect(f.world.__computaModelFirstPrompt).toBeUndefined(); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
    }
  });

  test("past preparation, private state, physical responses or inexact expected counts cannot emit a fresh quota receipt", async () => {
    for (const name of ["FirstSubmitted", "FirstProof", "LastSubmissionCount", "FirstPrompt", "FirstMarker", "FirstPrepared", "TemporaryRequested"]) {
      const f = fixture(provider); observedClaudeBanner(f); f.world[`__computaModel${name}`] = false;
      expect(await f.run()).toEqual({ error: "website_usage_limit" }); expect(f.send.clicks).toBe(0);
    }
    for (const counts of [undefined, [], [0, 1], [0, 0], [1]]) {
      const f = fixture(provider); observedClaudeBanner(f);
      const result = await f.run("inspect", { expectedUserCounts: counts });
      expect(result.freshQuotaAbort).toBeUndefined(); expect(f.send.clicks).toBe(0);
    }
    for (const hidden of [false, true]) {
      const f = fixture(provider, { response: true }); observedClaudeBanner(f);
      if (hidden) f.response.values.visibility = "hidden";
      expect(await f.run()).toEqual({ error: "website_usage_limit" }); expect(f.send.clicks).toBe(0);
    }
    const prepared = fixture(provider); expect(await prepared.run("prepare")).toMatchObject({ prepared: true });
    observedClaudeBanner(prepared); expect(await prepared.run()).toEqual({ error: "website_usage_limit" });
    const inserted = fixture(provider); expect(await inserted.run("insert", { prompt: outbound })).toMatchObject({ inserted: true });
    observedClaudeBanner(inserted); expect(await inserted.run()).toEqual({ error: "website_usage_limit" });
    const toggled = fixture(provider, { temporary: false }); await toggled.run("enableTemporary");
    observedClaudeBanner(toggled); expect(await toggled.run()).toEqual({ error: "website_usage_limit" });
    const existing = fixture(provider, { userPrompt: prompt }); observedClaudeBanner(existing);
    expect(await existing.run()).toEqual({ error: "website_usage_limit" });
  });

  test("the exact official banner link identifies the warning without trusting its rendered label", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run();
    const banner = observedClaudeBanner(f);
    banner.support.text = "messages";
    banner.support.append(new Element("SPAN", {}, " (opens in new tab)"));
    banner.warning.children[0].text = "You are out of free  ";
    banner.warning.children[2].text = "  until 11:40 PM";
    expect(await f.run()).toEqual({ error: "website_usage_limit" });
    expect(f.send.clicks).toBe(0); expect(banner.support.clicks).toBe(0);
    for (const label of ["messages (opens in a new window)", "\uE056messages\uE057", "Learn more", "unrelated authored text"]) {
      const other = fixture(provider); const copy = observedClaudeBanner(other); copy.support.text = label;
      expect(await other.run()).toEqual(freshQuotaReceipt(other));
      expect(other.world.__computaModelFirstProof).toBeUndefined();
      expect(await other.run("prepare")).toEqual({ error: "website_usage_limit" });
      expect(await other.run("submit", { prompt: outbound })).toEqual({ error: "website_usage_limit" });
      expect(other.send.clicks).toBe(0);
      expect(copy.support.clicks).toBe(0); expect(copy.upgrade.clicks).toBe(0);
    }
    const foreign = fixture(provider, { userPrompt: prompt }); await foreign.run();
    const wrong = observedClaudeBanner(foreign); wrong.support.text += " (opens in new tab)";
    wrong.support.values.href = "https://example.test/usage";
    expect(await foreign.run()).toMatchObject({ firstUserVerified: true });
  });

  test("banner proof excludes wrong links, arbitrary element text, body-wide coupling and message-authored copies", async () => {
    for (const mutate of [
      (b: ReturnType<typeof observedClaudeBanner>) => { b.support.values.href += "?unreviewed=1"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.support.values.href = "https://example.test/usage"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.upgrade.values.href = "https://example.test/upgrade?hide_free=true&from=ratelimit"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.upgrade.values.href += "&extra=1"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.upgrade.values.href += "&hide_free=true"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.upgrade.values.href = "https://claude.ai/upgrade?hide_free=false&from=ratelimit"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.warning.children[0] = new Element("EM", {}, "You are out of free "); },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.warning.append(new Element("#text", {}, " Additional authored prose")); },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.warning.children = [new Element("#text", {}, "You are out of free messages until 11:40 PM")]; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.warning.children = [b.support, new Element("#text", {}, "You are out of free messages until 11:40 PM")]; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.container.append(b.upgrade.cloneNode(true)); },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.support.values.visibility = "hidden"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.upgrade.values.visibility = "hidden"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.warning.children[2].text = " until 25:99 PM"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.container.tagName = "BODY"; },
      (b: ReturnType<typeof observedClaudeBanner>) => { b.container.append(b.support.cloneNode(true)); },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); const banner = observedClaudeBanner(f); mutate(banner);
      expect(await f.run()).toMatchObject({ firstUserVerified: true });
      expect(f.send.clicks).toBe(0);
    }
    const f = fixture(provider, { userPrompt: prompt }); await f.run(); const banner = observedClaudeBanner(f);
    f.body.children = f.body.children.filter(node => node !== banner.container); f.answer.append(banner.container);
    expect(await f.run()).toMatchObject({ firstUserVerified: true });
  });

  test("a banner alone cannot inspect mode indicators through an unrelated modal", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run(); observedClaudeBanner(f);
    f.header.values.inert = ""; f.exit.values["aria-hidden"] = "true";
    expect(await f.run()).toEqual({ error: "website_usage_limit" });
    expect(await f.run("stop")).toMatchObject({ error: "temporary_mode_unverified" });
    expect(f.send.clicks).toBe(0); expect(f.exit.clicks).toBe(0);
  });

  test("quota diagnostics reveal clock, control-tag and private-use categories without broadening classification", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run();
    const popup = observedClaudeQuota(f);
    popup.heading.text = "Your free messages return at 11:40PM";
    popup.upgrade.tagName = "A"; popup.upgrade.values.role = "button";
    popup.upgrade.text = "\uE056 Upgrade to Pro for $20/month";
    const result = await f.run("stop");
    expect(result.error).toBe("temporary_mode_unverified");
    const diagnostic = JSON.parse(result.quotaDiagnostic);
    expect(diagnostic).toMatchObject({ kind: "quota_structure", provider: "claude",
      headings: [{ tag: "h2", spacedClock: false, joinedClock: true }],
      mode: { headerTotal: 1, headerVisible: 0, headerPhysical: 1, exitTotal: 1, exitVisible: 0, exitPhysical: 1 } });
    expect(diagnostic.controls).toContainEqual(expect.objectContaining({ tag: "a", roleButton: true,
      textUpgradeExact: false, upgradeEdgePrivateUse: true, privateUseCount: 1, hasUnknownLabelText: false }));
    expect(diagnostic.popupAncestors[0]).toMatchObject({ tag: "div", buttonCount: 2, roleButtonCount: 1, anchorCount: 1 });
    expect(f.send.clicks).toBe(0); expect(popup.upgrade.clicks).toBe(0);
    const bannerPage = fixture(provider);
    const banner = observedClaudeBanner(bannerPage, "11:40PM"); banner.support.text += " (opens in new tab)";
    const observed = await bannerPage.run();
    expect(observed).toMatchObject({ temporary: true });
    const metadata = JSON.parse(observed.quotaDiagnostic);
    expect(metadata.support[0]).toMatchObject({ tag: "a", labelExact: false, labelKnownSuffix: true });
    expect(metadata.bannerParents[0]).toMatchObject({ joinedClock: true, spacedClock: false,
      supportDirect: true, children: ["text", "support", "text"] });
  });

  test("quota diagnostic output is bounded finite metadata without arbitrary site or account content", async () => {
    const privateText = "Private prompt account token never logged";
    const f = fixture(provider, { userPrompt: privateText }); await f.run();
    const popup = observedClaudeQuota(f); popup.heading.text = "Your free messages return at 11:40PM";
    popup.heading.values = { id: "private-heading-id", class: "private-class" };
    popup.upgrade.values = { role: "button", "aria-label": privateText, href: "https://private.test/account/token", id: "private-control-id" };
    for (let index = 0; index < 20; index++) {
      popup.dialog.append(new Element("H2", {}, "Your free messages return at 12:00AM"),
        new Element("BUTTON", { class: "private-class", id: "private-control-id" }, privateText));
    }
    const result = await f.run("stop"), diagnostic = JSON.parse(result.quotaDiagnostic);
    expect(result.error).toBe("temporary_mode_unverified");
    expect(diagnostic.headings.length).toBeLessThanOrEqual(4); expect(diagnostic.controls.length).toBeLessThanOrEqual(8);
    expect(diagnostic.popupAncestors.length).toBeLessThanOrEqual(8); expect(diagnostic.support.length).toBeLessThanOrEqual(4);
    expect(diagnostic.bannerParents.length).toBeLessThanOrEqual(4); expect(result.quotaDiagnostic.length).toBeLessThanOrEqual(8192);
    const strings = (value: unknown): string[] => typeof value === "string" ? [value]
      : Array.isArray(value) ? value.flatMap(strings) : value && typeof value === "object" ? Object.values(value).flatMap(strings) : [];
    const finite = new Set(["quota_structure", "claude", "a", "button", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6",
      "p", "section", "main", "body", "html", "dialog", "other", "none", "contents", "visible", "hidden", "collapse", "text", "support", "element"]);
    expect(strings(diagnostic).every(value => finite.has(value))).toBe(true);
    for (const value of [privateText, firstMarker, "private-heading-id", "private-class", "private-control-id", "https://private.test", "$20/month", "11:40PM"])
      expect(result.quotaDiagnostic).not.toContain(value);
    expect(f.send.clicks).toBe(0);
  });

  test("every temporary-mode action failure carries the same read-only finite quota diagnostics", async () => {
    for (const action of ["enableTemporary", "prepare", "insert", "sendReady", "submit", "stop"]) {
      const f = fixture(provider, { temporary: false }); f.toggle.connected = false;
      const result = await f.run(action, { prompt: outbound });
      expect(["temporary_mode_unavailable", "temporary_mode_unverified"]).toContain(result.error);
      expect(JSON.parse(result.quotaDiagnostic)).toMatchObject({ kind: "quota_structure", provider: "claude" });
      expect(f.send.clicks).toBe(0); expect(f.toggle.clicks).toBe(0);
    }
  });

  test("sign-in state is detected without performing any account action", async () => {
    const f = fixture(provider, { temporary: false }); f.composer.connected = false;
    const signIn = new Element("BUTTON", { "aria-label": "Sign in" }); f.body.append(signIn);
    expect(await f.run()).toMatchObject({ signIn: true, composer: false, temporary: false });
    expect(signIn.clicks).toBe(0);
  });

  test("assistant extraction omits headings and admits only its enabled scoped completion control", async () => {
    const f = fixture(provider, { userPrompt: prompt, renderedMarkdown: true });
    const result = await f.run();
    expect(result).toMatchObject({ responseCount: 1, userCount: 1, firstUserVerified: true, firstUserMarkerVerified: true,
      temporary: true, busy: false, answerComplete: true, text: '{"type":"message","text":"OK"}' });
    expect(result.firstUserFingerprint).toMatch(/^[a-f0-9]{64}$/);
    expect(result.text).not.toContain("responded"); expect(result.text).not.toContain("said");
    f.copy.disabled = true;
    expect(await f.run()).toMatchObject({ answerComplete: false });
    f.copy.disabled = false; f.copy.connected = false;
    f.body.append(new Element("BUTTON", { "aria-label": "Copy", "data-testid": "action-bar-copy", "data-test-id": "copy-button" }));
    expect(await f.run()).toMatchObject({ answerComplete: false });
  });

  test("streaming or a visible Stop response prevents premature completion", async () => {
    const f = fixture(provider, { userPrompt: prompt }); f.stop.connected = true;
    expect(await f.run()).toMatchObject({ busy: true, answerComplete: false });
    expect(await f.run("insert", { prompt: "Next turn" })).toMatchObject({ error: "composer_unavailable" });
    expect(f.send.clicks).toBe(0);
    f.stop.connected = false;
    if (provider === "claude") f.response.values["data-is-streaming"] = "true"; else f.response.values["aria-busy"] = "true";
    expect(await f.run()).toMatchObject({ busy: true, answerComplete: false });
  });

  test("literal editor insertion preserves exact text and Submit clicks once", async () => {
    const f = fixture(provider);
    expect(await f.run("prepare")).toMatchObject({ prepared: true, temporary: true });
    expect(await f.run("insert", { prompt: outbound })).toMatchObject({ inserted: true });
    expect(f.composer.innerText).toBe(outbound);
    expect(await f.run("sendReady", { prompt: outbound })).toMatchObject({ sendReady: true });
    expect(f.send.clicks).toBe(0);
    expect(await f.run("submit", { prompt: outbound })).toMatchObject({ submitted: true });
    expect(f.send.clicks).toBe(1);
    expect(await f.run()).toMatchObject({ firstUserVerified: true, firstUserMarkerVerified: true, userCount: 1 });
    expect(await f.run("submit", { prompt: outbound })).toHaveProperty("error");
    expect(f.send.clicks).toBe(1);
  });

  test("drafts and provider text substitutions fail before send without exposing prompt text", async () => {
    const f = fixture(provider); f.composer.text = "Human draft";
    expect(await f.run("prepare")).toMatchObject({ error: "composer_not_empty" });
    expect(await f.run("insert", { prompt: outbound })).toMatchObject({ error: "composer_not_empty" });
    expect(f.composer.innerText).toBe("Human draft"); f.composer.text = "";
    await f.run("insert", { prompt: outbound });
    f.composer.replaceChildren(); f.composer.text = outbound.replace('"quoted"', '“quoted”');
    const result = await f.run("submit", { prompt: outbound });
    expect(result).toMatchObject({ error: "prompt_not_inserted", detail: "text_difference" });
    expect(JSON.stringify(result)).not.toContain("quoted"); expect(f.send.clicks).toBe(0);
  });

  test("insertion mismatch diagnostics report exact scalar offsets without changing text", async () => {
    const suffix = "\n\n" + markerLine;
    for (const [expectedBody, actualBody, index, actualScalar, expectedScalar] of [
      ['A "private" text', 'A “private” text', 2, 0x201C, 0x22],
      ["A💡private", "A💢private", 1, 0x1F4A2, 0x1F4A1],
      ["A\u00a0B private", "A B private", 1, 0x20, 0xA0],
    ] as const) {
      const f = fixture(provider), expected = expectedBody + suffix;
      await f.run("insert", { prompt: expected });
      f.composer.replaceChildren(); f.composer.text = actualBody + suffix;
      const result = await f.run("sendReady", { prompt: expected });
      expect(result).toMatchObject({ error: "prompt_not_inserted", firstDifference: index, actualScalar, expectedScalar });
      expect(f.composer.innerText).toBe(actualBody + suffix); expect(f.send.clicks).toBe(0);
      expect(JSON.stringify(result)).not.toContain("private"); expect(JSON.stringify(result)).not.toContain(firstMarker);
    }
    const f = fixture(provider), expected = "Private text" + suffix;
    await f.run("insert", { prompt: expected }); f.composer.replaceChildren(); f.composer.text = expected.slice(0, -1);
    expect(await f.run("sendReady", { prompt: expected })).toMatchObject({ error: "prompt_not_inserted",
      firstDifference: expected.length - 1, actualScalar: null, expectedScalar: expected.codePointAt(expected.length - 1) });
    expect(f.send.clicks).toBe(0);
  });

  test("first submission requires its exact inserted prompt and final marker", async () => {
    const missing = fixture(provider);
    expect(await missing.run("insert", { prompt })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(missing.composer.innerText).toBe("");
    const f = fixture(provider); await f.run("insert", { prompt: outbound });
    f.composer.replaceChildren(); f.composer.text = "Replaced prompt\n\n" + markerLine;
    expect(await f.run("submit", { prompt: f.composer.innerText })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(f.send.clicks).toBe(0);
  });

  test("a lost Send acknowledgment cannot replay the original click", async () => {
    const f = fixture(provider); await f.run("insert", { prompt: outbound });
    f.send.onClick = () => { throw new Error("fixture lost send acknowledgment"); };
    await expect(f.run("submit", { prompt: outbound })).rejects.toThrow("fixture lost");
    expect(await f.run("submit", { prompt: outbound })).toHaveProperty("error");
    expect(f.send.clicks).toBe(1);
  });

  test("rendered Markdown binds once, and same-count replacement cannot authorize cleanup", async () => {
    const f = fixture(provider, { userPrompt: prompt, renderedMarkdown: true });
    expect(f.userBody!.innerText).not.toBe(outbound);
    const result = await f.run("inspect", {}, false);
    expect(result).toMatchObject({ firstUserVerified: true });
    expect(await f.run()).toMatchObject({ firstUserFingerprint: result.firstUserFingerprint });
    const previous = f.userRoot!, replacement = new Element(previous.tagName, { ...previous.values }, previous.innerText.replace("C++", "Changed schema"));
    const wrapper = previous.parentElement!;
    wrapper.children[wrapper.children.indexOf(previous)] = replacement; replacement.parentElement = wrapper; previous.connected = false;
    expect(await f.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(f.send.clicks).toBe(0);
  });

  test("an unchanged rendered first bubble may be recreated between inspections", async () => {
    const f = fixture(provider, { userPrompt: prompt, renderedMarkdown: true });
    const before = await f.run();
    const previous = f.userRoot!, replacement = new Element(previous.tagName, { ...previous.values }, previous.innerText);
    const wrapper = previous.parentElement!;
    wrapper.children[wrapper.children.indexOf(previous)] = replacement; replacement.parentElement = wrapper; previous.connected = false;
    expect(await f.run()).toMatchObject({ firstUserVerified: true, firstUserFingerprint: before.firstUserFingerprint });
  });

  test("a same-document reset is rejected even when native counts are accidentally empty", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run();
    f.userRoot!.parentElement!.connected = false;
    // Remove from query inventory as a real reset would, not only hide it.
    f.messages.children = f.messages.children.filter(node => !node.contains(f.userRoot!));
    expect(await f.run()).toMatchObject({ error: "conversation_changed", detail: "user_count" });
    expect(await f.run("inspect", { expectedUserCounts: [0] })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
  });

  test("markers cannot bind before Submit, without pending native binding, or as a marker-only body", async () => {
    const unsubmitted = fixture(provider, { userPrompt: prompt }); unsubmitted.world.__computaModelFirstSubmitted = false;
    expect(await unsubmitted.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const notPending = fixture(provider, { userPrompt: prompt });
    expect(await notPending.run("inspect", { allowFirstUserBinding: false })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const onlyMarker = fixture(provider, { userPrompt: "" });
    expect(await onlyMarker.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const wrongPlacement = fixture(provider, { userPrompt: prompt }); wrongPlacement.userBody!.text += "\nForeign suffix";
    expect(await wrongPlacement.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    for (const f of [unsubmitted, notPending, onlyMarker, wrongPlacement]) expect(f.world.__computaModelFirstProof).toBeUndefined();
  });

  test("digest yields recheck the exact body, owner, route, mode and physical user count", async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.userBody!.text += " changed"; },
      (f: ReturnType<typeof fixture>) => { f.world.__computaModelOwner = "foreign"; },
      (f: ReturnType<typeof fixture>) => { f.document.URL += "&other=1"; },
      (f: ReturnType<typeof fixture>) => { f.header.connected = false; f.exit.connected = false; },
      (f: ReturnType<typeof fixture>) => { f.appendUser("Foreign user"); },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }); f.onDigest(() => mutate(f));
      const result = await f.run(); expect(["conversation_changed", "temporary_mode_unverified"]).toContain(result.error);
      expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(f.send.clicks).toBe(0);
    }
  });

  test("provider, top-frame, exact URL, owner and pinned route checks precede mutations", async () => {
    for (const overrides of [
      { provider: "chatgpt" }, { expectedURL: "https://example.test/" }, { ownerToken: "foreign" },
      { expectedConversation: fixture(provider).origin + "/foreign" },
    ]) {
      const f = fixture(provider);
      const result = await f.run("enableTemporary", overrides);
      expect(["document_changed", "conversation_changed"]).toContain(result.error);
      expect(f.toggle.clicks).toBe(0); expect(f.send.clicks).toBe(0);
    }
    const frame = fixture(provider); frame.window.top = {};
    expect(await frame.run()).toMatchObject({ error: "document_changed" });
    const foreign = fixture(provider); foreign.location.origin = "https://example.test";
    expect(await foreign.run()).toMatchObject({ error: "document_changed" });
  });

  test("mutation notifications coalesce with no page text or recurring polling", async () => {
    const f = fixture(provider); await f.run(); await f.run();
    expect(f.observers).toHaveLength(1); expect(f.delays).toEqual([]); expect(f.posted).toEqual([]);
    f.observers[0].callback([{ type: "childList" }]); f.observers[0].callback([{ type: "attributes" }]);
    expect(f.delays).toEqual([100]); f.flush();
    expect(f.posted).toEqual([{ ownerToken: "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30", kind: "dom_changed" }]);
    f.observers[0].callback([{ type: "characterData" }]); f.world.__computaModelOwner = "foreign"; f.flush();
    expect(f.posted).toHaveLength(1);
  });

  test("incognito requires its query, header badge and Exit button together", async () => {
    for (const missing of ['query', 'exit', 'badge']) {
      const f = fixture(provider);
      if (missing === 'query') f.document.URL = f.origin + '/new';
      else if (missing === 'exit') f.exit.connected = false;
      else f.header.connected = false;
      expect(await f.run()).toMatchObject({ temporary: false });
      expect(await f.run('prepare')).toMatchObject({ error: 'temporary_mode_unverified' });
    }
  });
  test("interruption prevents response admission but keeps verified inspection available for cleanup", async () => {
    const f = fixture(provider, { userPrompt: prompt }); f.status.text = 'Claude’s response was interrupted.';
    expect(await f.run()).toMatchObject({ temporary: true, firstUserVerified: true, interrupted: true, answerComplete: false });
    f.response.append(new Element('DIV', { 'data-testid': 'response-status-announcer', role: 'status' }, 'Claude’s response was interrupted.'));
    f.status.text = 'Claude finished the response';
    expect(await f.run()).toMatchObject({ interrupted: false, answerComplete: true });
  });
  test("stable first-message ancestor identity cannot be changed during a digest or after binding", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    f.onDigest(() => { f.userRoot!.parentElement!.values.id = 'replacement-id'; });
    expect(await f.run()).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    const pinned = fixture(provider, { userPrompt: prompt }); await pinned.run();
    pinned.userRoot!.parentElement!.values.id = 'replacement-id';
    expect(await pinned.run()).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
  });

});

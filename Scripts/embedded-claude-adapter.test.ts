import { describe, expect, test } from "bun:test";
import { Element, fixture, firstMarker, markerLine, installObservedModelPicker } from "./embedded-provider-adapter-fixture";
import { defineWebsiteModelChoiceTests } from "./embedded-model-choice-tests";
const provider = "claude";
const prompt = 'Use `tool_calls` with C++ "quoted" text\n\n  two spaces and\u00a0NBSP';
const outbound = prompt + "\n\n" + markerLine;

defineWebsiteModelChoiceTests(provider, (owned = false) => fixture(provider, owned ? { userPrompt: 'Synthetic owned prompt' } : {}), Element);

const claudeCodeCaptionClasses = ["text-text-500 font-small pb-0", "text-secondary text-caption-regular font-sans pb-0"] as const;

function observedClaudeCodeBlock(f: ReturnType<typeof fixture>, raw: string, captionClasses: string = claudeCodeCaptionClasses[0]) {
  f.answer.text = ""; f.answer.children = [];
  const wrapper = new Element("DIV", { class: "relative border-border-400" });
  const container = new Element("DIV", { class: "absolute right-0 h-8 px-2 items-center inline-flex" });
  const control = new Element("BUTTON", { class: "cds-reset relative isolate inline-flex shrink-0 items-center" });
  const content = new Element("SPAN", { class: "inline-flex min-w-0 items-center gap-1" });
  const icon = new Element("SPAN", {}, "\uE056"); content.append(icon); control.append(content); container.append(control);
  const label = new Element("DIV", { class: captionClasses }, "json");
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

function observedClaudeBanner(f: ReturnType<typeof fixture>, clock = "11:40 PM", inert = false) {
  if (inert) {
    const background = new Element("DIV", { inert: "", "aria-hidden": "true" });
    background.append(...f.body.children); f.body.children = []; f.body.append(background);
  }
  const container = new Element("DIV"), warning = new Element("SPAN");
  const support = new Element("A", { href: "https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits" }, "messages");
  warning.append(new Element("#text", {}, "You are out of free "), support, new Element("#text", {}, " until " + clock));
  const upgrade = new Element("A", { href: "https://claude.ai/upgrade?hide_free=true&from=ratelimit" }, "Upgrade");
  container.append(warning, upgrade); f.body.append(container);
  return { container, warning, support, upgrade };
}
const freshQuotaReceipt = (f: ReturnType<typeof fixture>) => ({ error: "website_usage_limit", freshQuotaAbort: true,
  url: f.document.URL, userCount: 0, responseCount: 0 });

function claudeCloseFixture(onClosed: (f: ReturnType<typeof fixture>, picker: ReturnType<typeof installObservedModelPicker>, count: number) => void) {
  const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element, { genericHeader: true, unmountMenus: true });
  picker.selected("Sonnet 5");
  const click = picker.trigger.onClick!;
  let closes = 0;
  picker.trigger.onClick = () => {
    const wasOpen = picker.menu.values.hidden === undefined || picker.nested?.values.hidden === undefined;
    click();
    if (wasOpen) onClosed(f, picker, ++closes);
  };
  return { f, picker };
}

function unrelatedClaudeDialog(f: ReturnType<typeof fixture>, attributes: Record<string, string> = {}, tag = "DIV") {
  const dialog = new Element(tag, { role: "dialog", id: "unrelated-dialog", "aria-labelledby": "unrelated-title", ...attributes });
  const dismiss = new Element("BUTTON", { "aria-label": "Dismiss notice" });
  dialog.append(dismiss); f.body.append(dialog);
  Object.defineProperty(f.composer, "getBoundingClientRect", { configurable: true,
    value: () => ({ left: 10, top: 20, width: 100, height: 40 }) });
  f.document.elementFromPoint = () => f.composer;
  return { dialog, dismiss };
}

async function completeClaudeRead(f: ReturnType<typeof fixture>, action: string, overrides: Record<string, unknown>) {
  const result = f.run(action, overrides);
  // Flush only fixture-owned waits after asynchronous proof and digest steps.
  for (let phase = 0; phase < 4; phase++) {
    for (let tick = 0; tick < 40; tick++) await Promise.resolve();
    f.flush();
  }
  return await result;
}

describe("embedded Claude fixed adapter", () => {
  test("a final model guard confirms its exact closed popups without dismissing an unrelated nonmodal dialog", async () => {
    let popup: ReturnType<typeof unrelatedClaudeDialog> | undefined;
    const { f, picker } = claudeCloseFixture((f, picker, count) => {
      if (count === 2) { delete picker.trigger.values["aria-controls"]; popup = unrelatedClaudeDialog(f); }
    });
    const expectedModelChoice = { key: "Sonnet 5", label: "Sonnet 5" };
    const result = await completeClaudeRead(f, "insert", { expectedModelChoice, prompt: outbound });
    expect(result).toMatchObject({ inserted: true, modelEvidence: { selected: expectedModelChoice, source: "checked_model_option" } });
    expect(picker.trigger.values["aria-label"]).toBe("Model: Sonnet 5 Medium");
    expect(picker.trigger.clicks).toBe(4); expect(picker.menu.isConnected).toBe(false); expect(picker.nested!.isConnected).toBe(false);
    expect(popup!.dialog.isConnected).toBe(true); expect(popup!.dismiss.clicks).toBe(0);
    expect(f.composer.textContent).toBe(outbound); expect(f.send.clicks).toBe(0);
    expect(picker.options.every(option => option.clicks === 0)).toBe(true);
    const before = picker.trigger.clicks;
    expect((await completeClaudeRead(f, "sendReady", { expectedModelChoice, prompt: outbound })).error).toBe("model_unverified");
    expect(picker.trigger.clicks).toBe(before); expect(popup!.dismiss.clicks).toBe(0); expect(f.send.clicks).toBe(0);
  });

  test("losing association never confirms a still-physical owned Claude popup", async () => {
    for (const concealment of ["unassociated", "aria-hidden", "inert", "replaced-id", "replaced-id-hidden", "replaced-owner-id",
      "replaced-owner-tokens", "replaced-current-owner-tokens"]) {
      const { f, picker } = claudeCloseFixture((f, picker) => {
        if (concealment.startsWith("replaced-")) {
          const replacement = picker.menu.cloneNode(true);
          replacement.values.role = "dialog"; delete replacement.values.hidden;
          delete replacement.values["aria-labelledby"]; delete picker.trigger.values["aria-controls"];
          if (concealment === "replaced-id-hidden") replacement.values["aria-hidden"] = "true";
          if (concealment.startsWith("replaced-owner-") || concealment === "replaced-current-owner-tokens") {
            replacement.values.id = "new-dialog-id";
            replacement.values["aria-labelledby"] = picker.trigger.values.id;
            picker.trigger.values.id = "changed-trigger-id";
            if (concealment === "replaced-owner-tokens") replacement.values["aria-labelledby"] += " extra-label";
            if (concealment === "replaced-current-owner-tokens") replacement.values["aria-labelledby"] = "extra-label " + picker.trigger.values.id;
          }
          f.body.append(replacement);
          Object.defineProperty(f.composer, "getBoundingClientRect", { value: () => ({ left: 10, top: 20, width: 100, height: 40 }) });
          f.document.elementFromPoint = () => f.composer;
          return;
        }
        const oldPopup = picker.nested!;
        oldPopup.connected = true; delete oldPopup.values.hidden;
        oldPopup.values.role = "dialog"; delete oldPopup.values.id; delete oldPopup.values["aria-labelledby"];
        if (concealment !== "unassociated") oldPopup.values[concealment] = concealment === "inert" ? "" : "true";
      });
      const result = await completeClaudeRead(f, "insert", { expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" }, prompt: outbound });
      expect(result).toMatchObject({ error: "model_unverified", modelDiagnostic: { readStage: "close_unconfirmed",
        readAttempt: { closeAttempted: true, observedProof: true, sameTrigger: true, popupStillAssociated: false } } });
      expect(picker.trigger.clicks).toBe(2); expect(f.composer.textContent).toBe(""); expect(f.send.clicks).toBe(0);
      expect(picker.options.every(option => option.clicks === 0)).toBe(true);
    }
  });

  test("unknown modal dialogs and blocked composer controls cannot be acted through after owned popup closure", async () => {
    for (const kind of ["aria-modal", "native-dialog", "occluding-dialog", "inert-composer", "hidden-composer",
      "geometry-unavailable", "point-unavailable"]) {
      let dismiss: Element | undefined;
      const { f, picker } = claudeCloseFixture((f, _picker, count) => {
        if (count !== 1) return;
        const popup = unrelatedClaudeDialog(f, kind === "aria-modal" ? { "aria-modal": "true" }
          : kind === "native-dialog" ? { open: "" } : {}, kind === "native-dialog" ? "DIALOG" : "DIV");
        dismiss = popup.dismiss;
        if (kind === "inert-composer") f.composer.values.inert = "";
        if (kind === "hidden-composer") f.composer.values["aria-hidden"] = "true";
        if (kind === "occluding-dialog") f.document.elementFromPoint = () => popup.dialog;
        if (kind === "geometry-unavailable") Reflect.deleteProperty(f.composer, "getBoundingClientRect");
        if (kind === "point-unavailable") f.document.elementFromPoint = undefined;
      });
      const result = await completeClaudeRead(f, "insert", { expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" }, prompt: outbound });
      expect(result.error).toBe("model_unverified");
      expect(picker.trigger.clicks).toBe(2); expect(dismiss!.clicks).toBe(0);
      expect(f.composer.textContent).toBe(""); expect(f.composer.events.length).toBe(0); expect(f.send.clicks).toBe(0);
    }
  });

  test("Claude popup closure still requires the same restored enabled trigger", async () => {
    for (const kind of ["replacement", "disabled", "inert", "expanded", "open-state"]) {
      const { f, picker } = claudeCloseFixture((f, picker) => {
        unrelatedClaudeDialog(f);
        if (kind === "replacement") {
          const replacement = picker.trigger.cloneNode(true);
          picker.trigger.connected = false; f.body.append(replacement);
        } else if (kind === "disabled") picker.trigger.disabled = true;
        else if (kind === "inert") picker.trigger.values.inert = "";
        else if (kind === "expanded") picker.trigger.values["aria-expanded"] = "true";
        else picker.trigger.values["data-state"] = "open";
      });
      expect((await completeClaudeRead(f, "insert", { expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" }, prompt: outbound })).error).toBe("model_unverified");
      expect(picker.trigger.clicks).toBe(2); expect(f.composer.textContent).toBe(""); expect(f.send.clicks).toBe(0);
    }
  });

  test("unassociated dialogs cannot grant model proof or authorize a fresh opening", async () => {
    for (const initialDialog of [false, true]) {
      const { f, picker } = claudeCloseFixture(f => { unrelatedClaudeDialog(f); });
      if (initialDialog) unrelatedClaudeDialog(f);
      else for (const option of picker.options) option.values["aria-checked"] = "false";
      const result = await completeClaudeRead(f, "insert", { expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" }, prompt: outbound });
      expect(result.error).toBe("model_unverified");
      expect(result.modelDiagnostic.readAttempt.observedProof).toBe(false);
      expect(picker.trigger.clicks).toBe(initialDialog ? 0 : 2);
      expect(f.composer.textContent).toBe(""); expect(f.send.clicks).toBe(0);
      expect(picker.options.every(option => option.clicks === 0)).toBe(true);
    }
  });

  test("an unrelated dialog cannot occlude the actual Send target even when the composer is exposed", async () => {
    for (const geometry of ["occluded", "unavailable"]) {
      const f = fixture(provider);
      expect((await f.run("insert", { prompt: outbound })).inserted).toBe(true);
      const popup = unrelatedClaudeDialog(f);
      if (geometry === "occluded") Object.defineProperty(f.send, "getBoundingClientRect", {
        value: () => ({ left: 10, top: 80, width: 40, height: 20 }) });
      f.document.elementFromPoint = (_x: number, y: number) => y === 40 ? f.composer : popup.dialog;
      expect((await f.run("sendReady", { prompt: outbound })).sendReady).toBe(false);
      expect((await f.run("submit", { prompt: outbound })).error).toBe("send_unavailable");
      expect(f.send.clicks).toBe(0); expect(popup.dismiss.clicks).toBe(0);
      expect(f.world.__computaModelFirstSubmitted).toBeUndefined(); expect(f.composer.textContent).toBe(outbound);
    }
  });

  test("an exposed composer and Send target allow one normal submission beside an unrelated dialog", async () => {
    const f = fixture(provider);
    expect((await f.run("insert", { prompt: outbound })).inserted).toBe(true);
    const popup = unrelatedClaudeDialog(f), icon = new Element("SPAN"); f.send.append(icon);
    Object.defineProperty(f.send, "getBoundingClientRect", { value: () => ({ left: 10, top: 80, width: 40, height: 20 }) });
    f.document.elementFromPoint = (_x: number, y: number) => y === 40 ? f.composer : icon;
    expect((await f.run("sendReady", { prompt: outbound })).sendReady).toBe(true);
    expect((await f.run("submit", { prompt: outbound })).submitted).toBe(true);
    expect(f.send.clicks).toBe(1); expect(popup.dismiss.clicks).toBe(0); expect(f.userBody!.textContent).toBe(outbound);
  });

  test("an occluding dialog blocks unselected-model editor actions before their mutations", async () => {
    for (const [action, concealment] of [["prepare", ""], ["insert", ""], ["insert", "aria-hidden"], ["insert", "inert"],
      ["insert", "declared-modal"], ["insert", "native-modal"]]) {
      const f = fixture(provider), popup = unrelatedClaudeDialog(f,
        concealment === "declared-modal" ? { "aria-modal": "true" } : concealment === "native-modal" ? { open: "" } : {},
        concealment === "native-modal" ? "DIALOG" : "DIV");
      if (concealment) popup.dialog.values[concealment] = concealment === "inert" ? "" : "true";
      f.document.elementFromPoint = () => concealment.endsWith("modal") ? f.composer : popup.dialog;
      expect((await f.run(action, { prompt: outbound })).error).toBe("composer_unavailable");
      expect(f.composer.textContent).toBe(""); expect(f.composer.events.length).toBe(0);
      expect(f.send.clicks).toBe(0); expect(popup.dismiss.clicks).toBe(0);
      expect(f.world.__computaModelFirstPrepared).toBeUndefined(); expect(f.world.__computaModelFirstPrompt).toBeUndefined();
    }
  });

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
        codeTextLength: raw.length, outsideTextLength: 0, outsideTruncated: false,
        literalCodeValidJSON: true, literalCodeKnownEnvelopeType: envelope.type,
        selectedExtraction: "raw_code", extractionReason: "accepted_literal_code" });
      expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain('quoted');
    }
  });

  test("current and legacy Claude code captions admit only their literal sole JSON envelope", async () => {
    for (const captionClasses of claudeCodeCaptionClasses) for (const envelope of [
      { type: "message", text: 'It\'s "quoted" C:\\tmp\\path\nnext line' },
      { type: "tool_calls", calls: [{ name: "exec_command", arguments: { cmd: 'printf "literal\\n"\nprintf "It\'s quoted"' } }] },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }), raw = "\n" + JSON.stringify(envelope) + "\n";
      observedClaudeCodeBlock(f, raw, captionClasses);
      const result = await f.run();
      expect(result.text).toBe(raw); expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.text).not.toContain("\uE056"); expect(result.text).not.toContain("json\n");
      expect(result.completionEvidence.codeStructure).toMatchObject({ literalCodeValidJSON: true,
        literalCodeKnownEnvelopeType: envelope.type, selectedExtraction: "raw_code", extractionReason: "accepted_literal_code" });
    }
  });

  test("current and legacy Claude code captions do not excuse mismatched structure or authored content", async () => {
    for (const captionClasses of claudeCodeCaptionClasses) for (const change of [
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
      const block = observedClaudeCodeBlock(f, raw, captionClasses); change(f, block);
      expect((await f.run()).text).toBe("\uE056\njson\n" + raw);
      expect(f.send.clicks).toBe(0);
    }
  });

  test("caption alternatives reject class near misses, hidden labels, duplicates and nonliteral language text", async () => {
    for (const captionClasses of claudeCodeCaptionClasses) for (const change of [
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.class = "text-secondary text-caption-regular pb-0"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.class = "text-secondary font-sans pb-0"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.class = "text-caption-regular font-sans pb-0"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.class = "text-secondary text-caption-regular font-sans"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.class = "text-text-500 text-caption-regular font-sans pb-0"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.class = "text-secondary font-small pb-0"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.hidden = ""; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values["aria-hidden"] = "true"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.values.inert = ""; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.text = "json prose"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.label.text = "JSON"; },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.wrapper.append(new Element("DIV", { class: claudeCodeCaptionClasses[1] }, "json")); },
      (block: ReturnType<typeof observedClaudeCodeBlock>) => { block.wrapper.append(new Element("DIV", {}, "json")); },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }), raw = '{"type":"message","text":"Exact bytes"}';
      const block = observedClaudeCodeBlock(f, raw, captionClasses); change(block);
      const result = await f.run();
      expect(result.text).toBe("\uE056\njson\n" + raw);
      expect(result.completionEvidence.codeStructure).toMatchObject({ selectedExtraction: "rendered_fallback", extractionReason: "outside_content" });
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

  test("finite extraction evidence distinguishes rejected structure without exposing response content", async () => {
    const privateText = "PRIVATE_RESPONSE_PROMPT_HEADER_ACCOUNT_938475";
    const cases: { reason: string; validJSON: boolean | null; type: string | null;
      configure: (f: ReturnType<typeof fixture>, pre: Element, code: Element) => void }[] = [
      { reason: "missing_pre", validJSON: null, type: null,
        configure: f => { f.answer.children = []; f.answer.text = privateText; } },
      { reason: "multiple_pre", validJSON: null, type: null,
        configure: f => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, privateText)); f.answer.append(extra); } },
      { reason: "missing_code", validJSON: null, type: null,
        configure: (_f, pre) => { pre.children = []; pre.text = privateText; } },
      { reason: "multiple_code", validJSON: null, type: null,
        configure: (_f, pre) => { pre.append(new Element("CODE", {}, privateText)); } },
      { reason: "oversized_code", validJSON: null, type: null,
        configure: (_f, _pre, code) => { code.text = JSON.stringify({ type: "message", text: privateText + "x".repeat(220_000) }); } },
      { reason: "invalid_json", validJSON: false, type: null,
        configure: (_f, _pre, code) => { code.text = '{"type":"message","text":"' + privateText + '"unescaped""}'; } },
      { reason: "unknown_envelope_type", validJSON: true, type: "unknown",
        configure: (_f, _pre, code) => { code.text = JSON.stringify({ type: privateText, text: privateText }); } },
      { reason: "unknown_envelope_type", validJSON: true, type: "unknown",
        configure: (_f, _pre, code) => { code.text = JSON.stringify([{ type: "message", text: privateText }]); } },
      { reason: "unknown_envelope_type", validJSON: true, type: "unknown",
        configure: (_f, _pre, code) => { code.text = "null"; } },
      { reason: "outside_content", validJSON: true, type: "message",
        configure: f => { f.answer.append(new Element("P", { id: privateText, "data-private-header": privateText }, privateText)); } },
      { reason: "outside_scan_limit", validJSON: true, type: "message",
        configure: f => { for (let index = 0; index < 10_001; index++) f.answer.append(new Element("#text", {}, " ")); } },
    ];
    for (const { reason, validJSON, type, configure } of cases) {
      const f = fixture(provider, { userPrompt: privateText });
      f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, JSON.stringify({ type: "message", text: privateText }));
      pre.append(code); f.answer.append(pre); configure(f, pre, code);
      const rendered = "Rendered whole answer " + privateText;
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      const result = await f.run(), evidence = result.completionEvidence.codeStructure;
      expect(result.text).toBe(rendered);
      expect(evidence).toMatchObject({ literalCodeValidJSON: validJSON, literalCodeKnownEnvelopeType: type,
        selectedExtraction: "rendered_fallback", extractionReason: reason });
      const encoded = JSON.stringify(evidence);
      expect(encoded).not.toContain(privateText); expect(encoded).not.toContain(firstMarker);
      expect(encoded).not.toContain("data-private-header"); expect(encoded).not.toContain("unescaped");
      expect(encoded.length).toBeLessThanOrEqual(8192); expect(f.send.clicks).toBe(0);
    }
  });

  test("absent answers leave literal JSON facts unobserved and keep empty extraction", async () => {
    const f = fixture(provider, { userPrompt: prompt, response: false });
    const result = await f.run();
    expect(result.text).toBe("");
    expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 0, codeCount: 0,
      literalCodeValidJSON: null, literalCodeKnownEnvelopeType: null,
      selectedExtraction: "rendered_fallback", extractionReason: "absent_answer" });
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

  test("a submitted quota banner permits only read-only cleanup of the pinned physical Incognito mode", async () => {
    const f = fixture(provider, { userPrompt: prompt }); const before = await f.run();
    const banner = observedClaudeBanner(f, "11:40 PM", true); f.stop.connected = true;
    for (const action of ["inspect", "enableTemporary", "prepare", "insert", "sendReady", "submit"])
      expect(await f.run(action, { prompt: outbound })).toEqual({ error: "website_usage_limit" });
    expect(await f.run("stop")).toMatchObject({ usageLimited: true, temporary: true, busy: false, stopped: false,
      firstUserVerified: true, firstUserFingerprint: before.firstUserFingerprint, firstUserMarkerVerified: true, userCount: 1 });
    expect(f.composer.innerText).toBe(""); expect(f.document.activeElement).toBeNull();
    for (const control of [f.stop, f.send, f.exit, f.toggle, banner.support, banner.upgrade]) expect(control.clicks).toBe(0);
  });

  test("quota banner cleanup cannot establish ownership or accept changed first-message proof", async () => {
    const unbound = fixture(provider, { userPrompt: prompt }); observedClaudeBanner(unbound, "11:40 PM", true);
    expect(await unbound.run()).toEqual({ error: "website_usage_limit" });
    expect(await unbound.run("stop")).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(unbound.world.__computaModelFirstProof).toBeUndefined();
    for (const mutation of ["body", "identity", "owner", "count", "fingerprint", "marker", "url", "document"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run();
      const originalURL = f.document.URL, banner = observedClaudeBanner(f, "11:40 PM", true);
      const overrides: Record<string, unknown> = {};
      if (mutation === "body") f.userBody!.text += " changed";
      if (mutation === "identity") f.userRoot!.parentElement!.values.id = "replacement-id";
      if (mutation === "owner") f.world.__computaModelOwner = "foreign";
      if (mutation === "count") overrides.expectedUserCounts = [0];
      if (mutation === "fingerprint") overrides.expectedFirstUserFingerprint = "f".repeat(64);
      if (mutation === "marker") overrides.expectedFirstUserMarker = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
      if (mutation === "url") { f.document.URL = f.origin + "/chat/foreign?incognito"; overrides.expectedURL = originalURL; }
      if (mutation === "document") f.window.top = {};
      expect(["conversation_changed", "document_changed"]).toContain((await f.run("stop", overrides)).error);
      for (const control of [f.send, f.stop, f.exit, banner.support, banner.upgrade]) expect(control.clicks).toBe(0);
    }
  });

  test("quota cleanup requires one physical Incognito exit and header outside quota, authored and dialog scopes", async () => {
    for (const kind of ["banner", "popup"]) {
      for (const mutation of ["missing-exit", "hidden-exit", "missing-header", "hidden-header", "wrong-header", "no-incognito",
        "duplicate-exit", "duplicate-header", "authored-header", "quota-header", "quota-exit", "dialog-header"]) {
        const f = fixture(provider, { userPrompt: prompt }); await f.run();
        const surface = kind === "banner" ? observedClaudeBanner(f, "11:40 PM", true).container : observedClaudeQuota(f).dialog;
        if (mutation === "missing-exit") f.exit.connected = false;
        if (mutation === "hidden-exit") f.exit.values.hidden = "";
        if (mutation === "missing-header") f.badge.connected = false;
        if (mutation === "hidden-header") f.badge.values.visibility = "hidden";
        if (mutation === "wrong-header") f.badge.text = "Regular chat";
        if (mutation === "no-incognito") f.document.URL = f.origin + "/new";
        if (mutation === "duplicate-exit") f.exit.parentElement!.append(f.exit.cloneNode(true));
        if (mutation === "duplicate-header") f.header.parentElement!.append(f.header.cloneNode(true));
        if (["authored-header", "quota-header", "quota-exit", "dialog-header"].includes(mutation)) {
          const node = mutation === "quota-exit" ? f.exit : f.header;
          node.parentElement!.children = node.parentElement!.children.filter(child => child !== node);
          if (mutation === "authored-header") f.answer.append(node);
          else if (mutation === "dialog-header") { const dialog = new Element("DIV", { role: "dialog" }); dialog.append(node); f.body.append(dialog); }
          else surface.append(node);
        }
        expect((await f.run("stop")).error).toBe("temporary_mode_unverified");
        for (const control of [f.send, f.stop, f.exit]) expect(control.clicks).toBe(0);
        for (const control of surface.querySelectorAll("button, a")) expect(control.clicks).toBe(0);
      }
    }
  });

  test("unknown, ambiguous or authored banner surfaces cannot authorize hidden-mode cleanup", async () => {
    for (const mutation of ["support", "upgrade", "text", "hidden", "duplicate-support", "duplicate-upgrade", "duplicate-banner", "popup-too", "authored"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run();
      const banner = observedClaudeBanner(f, "11:40 PM", true);
      if (mutation === "support") banner.support.values.href += "?extra=1";
      if (mutation === "upgrade") banner.upgrade.values.href += "&extra=1";
      if (mutation === "text") banner.warning.children[2].text = " until someday";
      if (mutation === "hidden") banner.container.values.hidden = "";
      if (mutation === "duplicate-support") banner.container.append(banner.support.cloneNode(true));
      if (mutation === "duplicate-upgrade") banner.container.append(banner.upgrade.cloneNode(true));
      if (mutation === "duplicate-banner") f.body.append(banner.container.cloneNode(true));
      if (mutation === "popup-too") observedClaudeQuota(f, false);
      if (mutation === "authored") {
        f.body.children = f.body.children.filter(node => node !== banner.container); f.answer.append(banner.container);
      }
      expect((await f.run("stop")).error).toBe("temporary_mode_unverified");
      for (const control of [f.send, f.stop, f.exit, banner.support, banner.upgrade]) expect(control.clicks).toBe(0);
    }
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
    const modal = unrelatedClaudeDialog(f, { "aria-modal": "true" });
    f.header.values.inert = ""; f.exit.values["aria-hidden"] = "true";
    expect(await f.run()).toEqual({ error: "website_usage_limit" });
    expect(await f.run("stop")).toMatchObject({ error: "temporary_mode_unverified" });
    expect(f.send.clicks).toBe(0); expect(f.exit.clicks).toBe(0);
    expect(modal.dismiss.clicks).toBe(0);
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

  test("the unique semantic Copy control completes after its obsolete testid disappears or changes", async () => {
    for (const testid of [undefined, "new-provider-copy-id"] as const) for (const insideMessage of [false, true]) {
      const f = fixture(provider, { userPrompt: prompt });
      if (testid === undefined) delete f.copy.values["data-testid"]; else f.copy.values["data-testid"] = testid;
      if (insideMessage) {
        f.article.children = f.article.children.filter(node => node !== f.controls); f.response.append(f.controls);
      }
      const observed = await f.run();
      expect(observed).toMatchObject({ answerComplete: true, busy: false, interrupted: false,
        firstUserVerified: true, firstUserMarkerVerified: true, text: '{"type":"message","text":"OK"}',
        completionEvidence: { scopedCopies: 1, enabledCopies: 1,
          claudeCompletionStructure: { articleActionBars: 1, articleCopyLabelButtons: 1, articleCopyTestIDButtons: 0 } } });
      expect(f.copy.clicks).toBe(0); expect(f.send.clicks).toBe(0);
    }
  });

  test("semantic completion accepts one logical nested reply body and a display-contents toolbar", async () => {
    const f = fixture(provider, { userPrompt: prompt, computedStyle: node => ({ visibility: "visible",
      display: node.values["data-testid"] === "message-actions" ? "contents" : "block" }) });
    delete f.copy.values["data-testid"];
    const nested = new Element("DIV", { "data-perf-reply-text": "" }, f.answer.text);
    f.answer.text = ""; f.answer.append(nested);
    f.controls.getClientRects = () => [];
    expect(await f.run()).toMatchObject({ answerComplete: true, responseCount: 1,
      text: '{"type":"message","text":"OK"}', completionEvidence: { scopedCopies: 1, enabledCopies: 1 } });
  });

  test("semantic completion rejects authored, nested, duplicate, hidden, disabled and unrelated controls", async () => {
    for (const variant of ["authored-bar", "user-bar", "nested-article", "nested-bar", "duplicate-bar", "duplicate-copy",
      "hidden-duplicate-copy", "disabled-copy", "aria-disabled-copy", "hidden-copy", "hidden-bar", "disabled-bar", "code-copy",
      "foreign-copy", "other-assistant", "other-reply-body", "user-in-article", "nested-article-scope"] as const) {
      const f = fixture(provider, { userPrompt: prompt }); delete f.copy.values["data-testid"];
      const move = (node: Element, parent: Element) => {
        if (node.parentElement) node.parentElement.children = node.parentElement.children.filter(child => child !== node);
        parent.append(node);
      };
      if (variant === "authored-bar") move(f.controls, f.answer);
      if (variant === "user-bar") move(f.controls, f.userBody!);
      if (variant === "nested-article" || variant === "code-copy") {
        const wrapper = new Element(variant === "code-copy" ? "CODE" : "DIV", variant === "nested-article" ? { role: "article" } : {});
        f.controls.append(wrapper); move(f.copy, wrapper);
      }
      if (variant === "nested-bar") {
        const nested = new Element("DIV", { "data-testid": "message-actions" }); f.controls.append(nested); move(f.copy, nested);
      }
      if (variant === "duplicate-bar") f.article.append(new Element("DIV", { "data-testid": "message-actions" }));
      if (["duplicate-copy", "hidden-duplicate-copy"].includes(variant)) f.controls.append(new Element("BUTTON", {
        "aria-label": "Copy", ...(variant === "hidden-duplicate-copy" ? { hidden: "" } : {}) }));
      if (variant === "disabled-copy") f.copy.disabled = true;
      if (variant === "aria-disabled-copy") f.copy.values["aria-disabled"] = "true";
      if (variant === "hidden-copy") f.copy.values.hidden = "";
      if (variant === "hidden-bar") f.controls.values.hidden = "";
      if (variant === "disabled-bar") f.controls.values["aria-disabled"] = "true";
      if (variant === "foreign-copy") move(f.controls, f.body);
      if (variant === "other-assistant") f.article.append(new Element("DIV", { "data-testid": "assistant-message" }));
      if (variant === "other-reply-body") f.response.append(new Element("DIV", { "data-perf-reply-text": "" }, "Other response"));
      if (variant === "user-in-article") f.article.append(new Element("DIV", { "data-testid": "user-message" }, "Other user"));
      if (variant === "nested-article-scope") {
        const wrapper = new Element("DIV", { "data-testid": "assistant-message" }); f.messages.append(wrapper); move(f.article, wrapper);
      }
      const observed = await f.run();
      // A user-message mutation fails ownership before completion is considered.
      if (variant === "user-in-article") expect(observed.error).toBe("conversation_changed");
      else expect(observed.answerComplete).toBe(false);
      expect(f.copy.clicks).toBe(0); expect(f.send.clicks).toBe(0);
    }
  });

  test("semantic completion cannot reuse an older response's Copy toolbar", async () => {
    const f = fixture(provider, { userPrompt: prompt }); delete f.copy.values["data-testid"];
    const article = new Element("DIV", { role: "article" });
    const message = new Element("DIV", { "data-testid": "assistant-message", "data-is-streaming": "false" });
    message.append(new Element("DIV", { "data-perf-reply-text": "" }, '{"type":"message","text":"New response"}'));
    article.append(message); f.messages.append(article);
    expect(await f.run()).toMatchObject({ answerComplete: false, responseCount: 2,
      text: '{"type":"message","text":"New response"}', completionEvidence: { scopedCopies: 0, enabledCopies: 0 } });
  });

  test("the final model await cannot admit stale response landmarks, content or a restarted stream", async () => {
    for (const variant of ["remove-copy", "replace-copy", "duplicate-copy", "replace-bar", "hidden-copy", "disabled-copy",
      "streaming", "stop", "interrupted", "replace-answer", "changed-text", "append-response"] as const) {
      const f = fixture(provider, { userPrompt: prompt }); delete f.copy.values["data-testid"];
      const picker = installObservedModelPicker(f, provider, Element, { genericHeader: true, unmountMenus: true });
      picker.selected("Sonnet 5"); const click = picker.trigger.onClick!; let closes = 0;
      picker.trigger.onClick = () => {
        const wasOpen = picker.menu.values.hidden === undefined || picker.nested?.values.hidden === undefined;
        click();
        if (!wasOpen || ++closes !== 2) return;
        if (variant === "remove-copy") f.copy.connected = false;
        if (variant === "replace-copy") f.controls.replaceChildren(new Element("BUTTON", { "aria-label": "Copy" }));
        if (variant === "duplicate-copy") f.controls.append(new Element("BUTTON", { "aria-label": "Copy" }));
        if (variant === "replace-bar") {
          const bar = new Element("DIV", { "data-testid": "message-actions" }); bar.append(new Element("BUTTON", { "aria-label": "Copy" }));
          f.article.children = f.article.children.filter(node => node !== f.controls); f.controls.connected = false; f.article.append(bar);
        }
        if (variant === "hidden-copy") f.copy.values.hidden = "";
        if (variant === "disabled-copy") f.copy.disabled = true;
        if (variant === "streaming") f.response.values["data-is-streaming"] = "true";
        if (variant === "stop") f.stop.connected = true;
        if (variant === "interrupted") f.status.text = "Claude's response was interrupted.";
        if (variant === "replace-answer") f.response.replaceChildren(new Element("DIV", { "data-perf-reply-text": "" }, f.answer.text));
        if (variant === "changed-text") f.answer.text = '{"type":"message","text":"Changed"}';
        if (variant === "append-response") {
          const article = new Element("DIV", { role: "article" }), message = new Element("DIV", { "data-testid": "assistant-message", "data-is-streaming": "false" });
          const bar = new Element("DIV", { "data-testid": "message-actions" }); bar.append(new Element("BUTTON", { "aria-label": "Copy" }));
          message.append(new Element("DIV", { "data-perf-reply-text": "" }, f.answer.text)); article.append(message, bar); f.messages.append(article);
        }
      };
      const observed = await completeClaudeRead(f, "inspect", { expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" } });
      expect(closes).toBe(2);
      expect(observed.error).toBeUndefined(); expect(observed.answerComplete).toBe(false);
      expect(f.copy.clicks).toBe(0); expect(f.send.clicks).toBe(0);
    }
  });

  test("completion diagnostics distinguish a missing article from zero scoped controls without accepting it", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    delete f.article.values.role;
    const observed = await f.run(), shape = observed.completionEvidence.claudeCompletionStructure;
    expect(observed.answerComplete).toBe(false);
    expect(shape).toMatchObject({ answerPresent: true, messagePresent: true, messageStreamingState: "false",
      articlePresent: false, articleIsMessage: null, articleAssistantDescendants: null,
      articleReplyBodies: null, articleActionBars: null, articleExactCopyButtons: null,
      articleVisibleCopies: null, articleEnabledCopies: null });
    expect(shape.ancestors[0]).toMatchObject({ depth: 1, tag: "div", role: "none", isAssistantMessage: true,
      assistantDescendants: 0, replyBodyDescendants: 1, actionBars: 0, exactCopyButtons: 0 });
    expect(shape.ancestors[1]).toMatchObject({ depth: 2, role: "none", isAssistantMessage: false,
      assistantDescendants: 1, actionBars: 1, copyTestIDButtons: 1, copyLabelButtons: 1, exactCopyButtons: 1 });
    expect(shape.ancestors).toHaveLength(4);
  });

  test("completion diagnostics distinguish self scopes, changed action bars and changed Copy labels", async () => {
    for (const variant of ["self", "bar", "testid", "label"] as const) {
      const f = fixture(provider, { userPrompt: prompt });
      if (variant === "self") f.response.values.role = "article";
      if (variant === "bar") f.controls.values["data-testid"] = "changed";
      if (variant === "testid") f.copy.values["data-testid"] = "changed";
      if (variant === "label") f.copy.values["aria-label"] = "changed";
      const observed = await f.run(), shape = observed.completionEvidence.claudeCompletionStructure;
      expect(observed.answerComplete).toBe(variant === "testid");
      expect(shape.articleIsMessage).toBe(variant === "self");
      expect(shape.articleAssistantDescendants).toBe(variant === "self" ? 0 : 1);
      expect(shape.articleActionBars).toBe(["self", "bar"].includes(variant) ? 0 : 1);
      expect(shape.articleExactCopyButtons).toBe(0);
      expect(shape.articleCopyTestIDButtons).toBe(variant === "label" ? 1 : 0);
      expect(shape.articleCopyLabelButtons).toBe(variant === "testid" ? 1 : 0);
      expect(shape.ancestors[1].exactCopyButtons).toBe(["self", "bar"].includes(variant) ? 1 : 0);
    }
  });

  test("completion diagnostics preserve visibility, enabled and streaming distinctions", async () => {
    for (const variant of ["hidden", "disabled", "streaming", "absent", "other", "complete"] as const) {
      const f = fixture(provider, { userPrompt: prompt });
      if (variant === "hidden") f.copy.values.hidden = "";
      if (variant === "disabled") f.copy.disabled = true;
      if (variant === "streaming") f.response.values["data-is-streaming"] = "true";
      if (variant === "absent") delete f.response.values["data-is-streaming"];
      if (variant === "other") f.response.values["data-is-streaming"] = "PRIVATE_STREAMING_STATE";
      const observed = await f.run(), shape = observed.completionEvidence.claudeCompletionStructure;
      expect(observed.answerComplete).toBe(variant === "complete");
      expect(shape.articleExactCopyButtons).toBe(1);
      expect(shape.articleVisibleCopies).toBe(variant === "hidden" ? 0 : 1);
      expect(shape.articleEnabledCopies).toBe(["hidden", "disabled"].includes(variant) ? 0 : 1);
      expect(shape.messageStreamingState).toBe(variant === "streaming" ? "true" : ["absent", "other"].includes(variant) ? variant : "false");
      expect(JSON.stringify(shape)).not.toContain("PRIVATE");
    }
  });

  test("completion diagnostics retain absent-answer unknowns and never leak arbitrary ancestor attributes", async () => {
    const empty = fixture(provider);
    const missing = (await empty.run()).completionEvidence.claudeCompletionStructure;
    expect(missing).toMatchObject({ answerPresent: false, messagePresent: false, messageStreamingState: null,
      articlePresent: false, articleIsMessage: null, articleActionBars: null, ancestors: [] });
    const f = fixture(provider, { userPrompt: prompt });
    f.response.tagName = "PRIVATE_ELEMENT"; f.response.values.role = "PRIVATE_ROLE";
    f.response.values.id = "PRIVATE_ID"; f.response.values.class = "PRIVATE_CLASS";
    f.copy.values["data-private-url"] = "https://PRIVATE_URL";
    const shape = (await f.run()).completionEvidence.claudeCompletionStructure;
    expect(shape.ancestors[0]).toMatchObject({ tag: "other", role: "other" });
    expect(JSON.stringify(shape)).not.toContain("PRIVATE");
  });

  test("completion diagnostic counts and ancestor walks remain bounded when duplicate controls deny completion", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    for (let index = 0; index < 1_005; index++) f.controls.append(new Element("BUTTON", { "aria-label": "Copy", "data-testid": "action-bar-copy" }));
    const observed = await f.run(), shape = observed.completionEvidence.claudeCompletionStructure;
    expect(observed.answerComplete).toBe(false);
    expect(shape.articleExactCopyButtons).toBe(1_000);
    expect(shape.articleVisibleCopies).toBe(1_000); expect(shape.articleEnabledCopies).toBe(1_000);
    expect(shape.ancestors).toHaveLength(4);
    expect(shape.ancestors[1].exactCopyButtons).toBe(1_000);
  });

  test("an unavailable optional completion diagnostic cannot fail or complete an adapter read", async () => {
    for (const disabled of [false, true]) {
      const f = fixture(provider, { userPrompt: prompt }); f.copy.disabled = disabled;
      const query = f.response.querySelectorAll.bind(f.response);
      f.response.querySelectorAll = selector => {
        if (selector === 'button[data-testid="action-bar-copy"]') throw new Error("diagnostic-only fixture exception");
        return query(selector);
      };
      const observed = await f.run();
      expect(observed.answerComplete).toBe(!disabled);
      expect(observed.completionEvidence.claudeCompletionStructure).toBeNull();
      expect(observed.text).toBe('{"type":"message","text":"OK"}');
    }
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

  test("mutation notifications deliver without page timers and carry only ownership and kind", async () => {
    const f = fixture(provider); await f.run(); await f.run();
    expect(f.observers).toHaveLength(1); expect(f.delays).toEqual([]); expect(f.posted).toEqual([]);
    // Leave the fixture's timer queue undrained: a parked background timer
    // must not prevent either actual DOM change reaching the native receiver.
    f.observers[0].callback([{ type: "childList" }]); f.observers[0].callback([{ type: "attributes" }]);
    expect(f.delays).toEqual([]);
    expect(f.posted).toEqual(Array(2).fill({ ownerToken: "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30", kind: "dom_changed" }));
    f.world.__computaModelOwner = "foreign";
    f.observers[0].callback([{ type: "characterData" }]);
    expect(f.posted).toHaveLength(2);
    f.world.__computaModelOwner = "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30";
    f.location.origin = "https://example.test";
    f.observers[0].callback([{ type: "characterData" }]);
    expect(f.posted).toHaveLength(2);
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

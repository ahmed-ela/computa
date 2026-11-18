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
  Object.defineProperty(f.answer, "innerText", { configurable: true, get: () => "\uE056\njson\n" + raw });
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
function observedClaudePause(f: ReturnType<typeof fixture>, family = "Opus 5", continuation = "Sonnet 4.6", observedDOM = true) {
  // Saved direct379 DOM: warning SPAN, isolated CODE reason, and edit/retry text.
  // The older AX-only shape remains an explicit compatibility fixture.
  const surface = new Element("DIV", observedDOM ? { "data-testid": "asl3-stop-warning" } : {});
  const paused = new Element(observedDOM ? "H4" : "SPAN", {}, "Paused");
  const warning = new Element("SPAN", {}, `${family}'s safeguards flagged this message. This sometimes happens with safe, normal conversations.`);
  const details = new Element(observedDOM ? "CODE" : "SPAN", {}, "[reasoning_extraction]");
  const retry = new Element("BUTTON", {}, `${observedDOM ? "Edit and retry" : "Retry"} with ${family}`);
  const fallback = new Element("BUTTON", {}, `Continue with ${continuation}`);
  const paragraph = new Element("P"), reason = new Element("SPAN", {}, "Details: ");
  paragraph.append(warning, new Element("#text", {}, " "), fallback, new Element("#text", {}, ", "),
    new Element("BUTTON", {}, "send feedback"), new Element("#text", {}, ", or "), new Element("A", {}, "learn more"), new Element("#text", {}, "."));
  reason.append(details); surface.append(paused, retry, paragraph, reason);
  f.body.append(surface);
  const finished = new Element("DIV", { "data-testid": "response-status-announcer", role: "status" }, "Claude finished the response");
  f.body.append(finished);
  return { surface, paused, warning, details, retry, fallback, finished };
}
const safeguardFailure = { error: "website_response_blocked", detail: "reasoning_extraction" };

const freshQuotaReceipt = (f: ReturnType<typeof fixture>) => ({ error: "website_usage_limit", freshQuotaAbort: true,
  url: f.document.URL, userCount: 0, responseCount: 0 });

function claudeCloseFixture(onClosed: (f: ReturnType<typeof fixture>, picker: ReturnType<typeof installObservedModelPicker>, count: number) => void) {
  const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element, { genericHeader: true, unmountMenus: true });
  picker.selected("Sonnet 5");
  let closes = 0;
  for (const menu of [picker.menu, picker.nested].filter(Boolean)) {
    const dismiss = menu!.onDispatch!;
    menu!.onDispatch = (event: any) => {
      dismiss(event);
      if (event.type === "keydown" && event.key === "Escape") onClosed(f, picker, ++closes);
    };
  }
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
  test("selection-driven asynchronous Claude closure cannot be toggled open by dismissal", async () => {
    for (const label of ["Haiku 4.5", "Sonnet 5"]) {
      const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element, { genericHeader: true, unmountMenus: true });
      const modelChoice = { key: label, label };
      if (label === "Haiku 4.5") picker.secondary!.connected = false;
      const closingMenu = label === "Haiku 4.5" ? picker.menu : picker.nested!;
      const option = picker.options.find(node => node.children[0].text === label)!;
      const triggerClick = picker.trigger.onClick!;
      let selectionClosing = false, componentOpen = true, reopens = 0;
      option.onClick = () => {
        picker.selected(label);
        // React has committed the selected family/closed state, but its portal
        // remains in the physical DOM through the asynchronous closing phase.
        selectionClosing = true; componentOpen = false;
      };
      picker.trigger.onClick = () => {
        if (selectionClosing) {
          componentOpen = !componentOpen;
          if (componentOpen) reopens++;
          return;
        }
        triggerClick();
      };
      const escapes: Element[] = [];
      for (const menu of [picker.menu, picker.nested].filter(Boolean)) menu!.onDispatch = (event: any) => {
        if (event.type === "keydown" && event.key === "Escape") { escapes.push(menu!); componentOpen = false; }
      };
      for (let step = 0; step < 4 && !selectionClosing; step++)
        expect((await f.run("selectModel", { modelChoice })).pending).toBe(true);
      expect(option.clicks).toBe(1); expect(selectionClosing).toBe(true);
      let finished = false;
      const pending = f.run("selectModel", { modelChoice }).then(result => { finished = true; return result; });
      for (let tick = 0; tick < 40; tick++) await Promise.resolve();
      expect(finished).toBe(false); expect(escapes).toEqual([closingMenu]);
      expect(picker.trigger.clicks).toBe(1); expect(reopens).toBe(0);
      // Only the actual closing commit, not the Escape event, supplies proof.
      if (!componentOpen) {
        for (const menu of [picker.menu, picker.nested].filter(Boolean)) { menu!.values.hidden = ""; menu!.connected = false; }
        picker.trigger.values["aria-expanded"] = "false";
      }
      f.observers.forEach(observer => observer.callback([]));
      const result = await pending;
      expect(result).toMatchObject({ selected: true, modelEvidence: { selected: modelChoice, source: "checked_model_option" } });
      expect(escapes).toHaveLength(1); expect(option.clicks).toBe(1); expect(reopens).toBe(0);
      expect(f.composer.textContent).toBe(""); expect(f.composer.events).toHaveLength(0); expect(f.send.clicks).toBe(0);
    }
  });

  test("ignored Claude Escape cannot qualify a still-visible popup or mutate the composer", async () => {
    const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element, { genericHeader: true, unmountMenus: true });
    picker.selected("Sonnet 5");
    const foreign = new Element("DIV", { role: "menu", hidden: "" }); f.body.append(foreign);
    for (const menu of [picker.menu, picker.nested].filter(Boolean)) menu!.onDispatch = () => {};
    const result = await completeClaudeRead(f, "insert", { expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" }, prompt: outbound });
    expect(result).toMatchObject({ error: "model_unverified", modelDiagnostic: { readStage: "close_unconfirmed",
      readAttempt: { closeAttempted: true, observedProof: true, popupStillAssociated: true } } });
    expect(picker.trigger.clicks).toBe(1); expect(picker.nested!.events).toHaveLength(1); expect(picker.menu.events).toHaveLength(0);
    expect(foreign.events).toHaveLength(0); expect(picker.options.every(option => option.clicks === 0)).toBe(true);
    expect(f.composer.textContent).toBe(""); expect(f.composer.events).toHaveLength(0); expect(f.send.clicks).toBe(0);
  });

  test("Claude Escape does not permit owner or document drift during its closure acknowledgment", async () => {
    for (const drift of ["owner", "url", "top-frame"]) {
      const { f, picker } = claudeCloseFixture(f => {
        if (drift === "owner") f.world.__computaModelOwner = "foreign-owner";
        else if (drift === "url") f.document.URL += "&foreign-route=1";
        else f.window.top = {};
      });
      const result = await completeClaudeRead(f, "insert", { expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" }, prompt: outbound });
      expect(result.error).toBe("model_unverified"); expect(picker.trigger.clicks).toBe(1);
      expect(picker.nested!.events).toHaveLength(1); expect(picker.options.every(option => option.clicks === 0)).toBe(true);
      expect(f.composer.textContent).toBe(""); expect(f.composer.events).toHaveLength(0); expect(f.send.clicks).toBe(0);
    }
  });

  test("a final model guard confirms its exact closed popups without dismissing an unrelated nonmodal dialog", async () => {
    let popup: ReturnType<typeof unrelatedClaudeDialog> | undefined;
    const { f, picker } = claudeCloseFixture((f, picker, count) => {
      if (count === 2) { delete picker.trigger.values["aria-controls"]; popup = unrelatedClaudeDialog(f); }
    });
    const expectedModelChoice = { key: "Sonnet 5", label: "Sonnet 5" };
    const result = await completeClaudeRead(f, "insert", { expectedModelChoice, prompt: outbound });
    expect(result).toMatchObject({ inserted: true, modelEvidence: { selected: expectedModelChoice, source: "checked_model_option" } });
    expect(picker.trigger.values["aria-label"]).toBe("Model: Sonnet 5 Medium");
    expect(picker.trigger.clicks).toBe(2); expect(picker.menu.isConnected).toBe(false); expect(picker.nested!.isConnected).toBe(false);
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
      expect(picker.trigger.clicks).toBe(1); expect(f.composer.textContent).toBe(""); expect(f.send.clicks).toBe(0);
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
      expect(picker.trigger.clicks).toBe(1); expect(dismiss!.clicks).toBe(0);
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
      expect(picker.trigger.clicks).toBe(1); expect(f.composer.textContent).toBe(""); expect(f.send.clicks).toBe(0);
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
      expect(picker.trigger.clicks).toBe(initialDialog ? 0 : 1);
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
      expect(await f.run("sendReady", { prompt: outbound })).toMatchObject({
        sendReady: false, claudeSendReadiness: "not_unobstructed" });
      expect(await f.run("submit", { prompt: outbound })).toMatchObject({
        error: "send_unavailable", detail: "not_unobstructed" });
      expect(f.send.clicks).toBe(0); expect(popup.dismiss.clicks).toBe(0);
      expect(f.world.__computaModelFirstSubmitted).toBeUndefined(); expect(f.composer.textContent).toBe(outbound);
    }
  });

  test("missing and disabled exact Send controls take precedence over obstruction", async () => {
    for (const [attribute, value, reason] of [
      ["aria-label", "Other button", "no_visible_exact_send"],
      ["aria-disabled", "true", "disabled_or_hidden"],
    ]) {
      const f = fixture(provider);
      expect((await f.run("insert", { prompt: outbound })).inserted).toBe(true);
      const ready = await f.run("sendReady", { prompt: outbound });
      expect(ready.sendReady).toBe(true);
      expect(ready.claudeSendReadiness).toBeUndefined();

      const popup = unrelatedClaudeDialog(f);
      f.document.elementFromPoint = () => f.composer;
      f.send.values[attribute] = value;
      expect(await f.run("sendReady", { prompt: outbound })).toMatchObject({
        sendReady: false, claudeSendReadiness: reason });
      expect(await f.run("submit", { prompt: outbound })).toMatchObject({
        error: "send_unavailable", detail: reason });
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
      expect(result.completionEvidence.codeStructure.unknownLiteralEnvelope).toBeUndefined();
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
    const privateKey = "PRIVATE_UNRECOGNIZED_TOP_LEVEL_KEY";
    const cases: { reason: string; validJSON: boolean | null; type: string | null;
      unknownEnvelope?: { rootKind: string; typeClass: string; knownKeys: string[]; unknownKeyCount: number };
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
        unknownEnvelope: { rootKind: "object", typeClass: "other_string", knownKeys: ["type", "text"], unknownKeyCount: 2 },
        configure: (_f, _pre, code) => { code.text = JSON.stringify({ text: privateText, [privateKey]: privateText,
          ["__proto__"]: { output: privateText }, type: privateText }); } },
      { reason: "unknown_envelope_type", validJSON: true, type: "unknown",
        unknownEnvelope: { rootKind: "object", typeClass: "missing", unknownKeyCount: 0,
          knownKeys: ["text", "phase", "calls", "commentary", "tool_calls", "message", "answer", "output", "result", "content"] },
        configure: (_f, _pre, code) => { code.text = JSON.stringify({ content: privateText, result: privateText,
          output: privateText, answer: privateText, message: privateText, tool_calls: [], commentary: privateText,
          calls: [], phase: privateText, text: privateText }); } },
      { reason: "unknown_envelope_type", validJSON: true, type: "unknown",
        unknownEnvelope: { rootKind: "object", typeClass: "non_string", knownKeys: ["type", "output"], unknownKeyCount: 0 },
        configure: (_f, _pre, code) => { code.text = JSON.stringify({ type: null, output: privateText }); } },
      ...([
        ["array", [{ type: "message", text: privateText }]], ["null", null], ["string", privateText],
        ["number", 42], ["bool", true],
      ] as const).map(([rootKind, value]) => ({ reason: "unknown_envelope_type", validJSON: true, type: "unknown",
        unknownEnvelope: { rootKind, typeClass: "not_applicable", knownKeys: [], unknownKeyCount: 0 },
        configure: (_f: ReturnType<typeof fixture>, _pre: Element, code: Element) => { code.text = JSON.stringify(value); } })),
      { reason: "outside_content", validJSON: true, type: "message",
        configure: f => { f.answer.append(new Element("P", { id: privateText, "data-private-header": privateText }, privateText)); } },
      { reason: "outside_scan_limit", validJSON: true, type: "message",
        configure: f => { for (let index = 0; index < 10_001; index++) f.answer.append(new Element("#text", {}, " ")); } },
    ];
    for (const { reason, validJSON, type, unknownEnvelope, configure } of cases) {
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
      expect(evidence.unknownLiteralEnvelope).toEqual(unknownEnvelope);
      if (unknownEnvelope) expect(evidence.isolatedJSONCodeBlock).toBeNull();
      const encoded = JSON.stringify(evidence);
      expect(encoded).not.toContain(privateText); expect(encoded).not.toContain(firstMarker);
      expect(encoded).not.toContain(privateKey); expect(encoded).not.toContain("__proto__");
      expect(encoded).not.toContain("data-private-header"); expect(encoded).not.toContain("unescaped");
      expect(encoded.length).toBeLessThanOrEqual(8192); expect(f.send.clicks).toBe(0);
    }
  });

  test("two identical tool-code blocks expose only bounded correction evidence, never extracted calls", async () => {
    const raw = JSON.stringify({ type: "tool_calls", calls: [{ name: "browser_close", arguments: {} }] });
    const scenarios = ["identical", "different_arguments", "whitespace", "message", "malformed", "array",
      "nested_pre", "extra_code", "missing_code", "third_pre", "oversized", "utf8_oversized"];
    for (const scenario of scenarios) {
      const f = fixture(provider, { userPrompt: prompt });
      let first = raw, second = raw;
      if (scenario === "different_arguments") second = JSON.stringify({ type: "tool_calls", calls: [{ name: "browser_close", arguments: { tab_id: "different" } }] });
      if (scenario === "whitespace") second = " " + raw;
      if (scenario === "message") first = second = JSON.stringify({ type: "message", text: "I cannot comply." });
      if (scenario === "malformed") first = second = raw + "]";
      if (scenario === "array") first = second = "[" + raw + "]";
      if (scenario === "oversized") first = second = JSON.stringify({ type: "tool_calls", calls: [], private: "x".repeat(220_000) });
      if (scenario === "utf8_oversized") first = second = JSON.stringify({ type: "tool_calls", calls: [], private: "é".repeat(120_000) });
      f.answer.text = ""; f.answer.children = [];
      const a = new Element("PRE"), b = new Element("PRE");
      a.append(new Element("CODE", {}, first)); b.append(new Element("CODE", {}, second));
      f.answer.append(a, new Element("P", {}, "I need to review the observed result before closing the tab."), b);
      if (scenario === "nested_pre") { f.answer.children.pop(); a.append(b); }
      if (scenario === "extra_code") f.answer.append(new Element("CODE", {}, raw));
      if (scenario === "missing_code") b.children = [];
      if (scenario === "third_pre") { const third = new Element("PRE"); third.append(new Element("CODE", {}, raw)); f.answer.append(third); }
      const rendered = "Whole authored reply with private_canary narration and both blocks: " + first + "\n" + second;
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      const result = await f.run(), evidence = result.completionEvidence.codeStructure;
      expect(result.text).toBe(rendered.slice(0, 220_001));
      expect(evidence).toMatchObject({ selectedExtraction: "rendered_fallback", extractionReason: "multiple_pre",
        literalCodeValidJSON: null, literalCodeKnownEnvelopeType: null,
        repeatedIdenticalToolCalls: scenario === "third_pre" ? null : scenario === "identical" });
      const encoded = JSON.stringify(evidence);
      expect(encoded.length).toBeLessThanOrEqual(8192);
      expect(encoded).not.toContain("private_canary"); expect(encoded).not.toContain("browser_close");
      expect(f.send.clicks).toBe(0);
    }
  });

  test("absent answers leave literal JSON facts unobserved and keep empty extraction", async () => {
    const f = fixture(provider, { userPrompt: prompt, response: false });
    const result = await f.run();
    expect(result.text).toBe("");
    expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 0, codeCount: 0,
      literalCodeValidJSON: null, literalCodeKnownEnvelopeType: null, repeatedIdenticalToolCalls: null,
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

  test("Claude safeguard pause wins over finished and complete-looking responses without any action", async () => {
    for (const action of ["inspect", "verifyModel", "enableTemporary", "prepare", "insert", "sendReady", "submit"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run();
      const pause = observedClaudePause(f); f.stop.connected = true;
      expect(await f.run(action, { prompt: outbound })).toEqual(safeguardFailure);
      for (const control of [f.send, f.stop, f.toggle, f.exit, pause.retry, pause.fallback]) expect(control.clicks).toBe(0);
      expect(f.composer.innerText).toBe("");
    }
  });

  test("Claude safeguard family labels are validated and Retry must match the exact warning family", async () => {
    for (const [family, next] of [["Opus 5", "Sonnet 4.6"], ["Opus 5.5", "Haiku 5.5"], ["Sonnet 4.6", "Opus 5"]]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); observedClaudePause(f, family, next);
      expect(await f.run()).toEqual(safeguardFailure);
    }
    for (const mutation of ["unknown_family", "mismatch_retry", "unknown_continuation", "same_continuation", "different_reason", "different_warning", "missing_pause", "missing_reason", "missing_retry", "missing_continuation", "duplicate_warning", "duplicate_retry", "disabled_retry"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); const p = observedClaudePause(f);
      if (mutation === "unknown_family") { p.warning.text = p.warning.text.replace("Opus 5", "Unknown 5"); p.retry.text = "Retry with Unknown 5"; }
      if (mutation === "mismatch_retry") p.retry.text = "Retry with Opus 5.5";
      if (mutation === "unknown_continuation") p.fallback.values["aria-label"] = "Continue with External 4";
      if (mutation === "same_continuation") p.fallback.values["aria-label"] = "Continue with Opus 5";
      if (mutation === "different_reason") p.details.text = "[unknown_private_reason]";
      if (mutation === "different_warning") p.warning.text += " Extra";
      if (mutation === "missing_pause") p.paused.connected = false;
      if (mutation === "missing_reason") p.details.connected = false;
      if (mutation === "missing_retry") p.retry.connected = false;
      if (mutation === "missing_continuation") p.fallback.connected = false;
      if (mutation === "duplicate_warning") p.surface.append(p.warning.cloneNode(true));
      if (mutation === "duplicate_retry") p.surface.append(p.retry.cloneNode(true));
      if (mutation === "disabled_retry") p.retry.disabled = true;
      expect((await f.run()).error, mutation).toBeUndefined();
      expect(p.retry.clicks + p.fallback.clicks).toBe(0);
    }
  });

  test("Claude safeguard observed CODE reason and both exact retry variants preserve the complete conjunction", async () => {
    for (const observedDOM of [true, false]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run();
      const p = observedClaudePause(f, "Opus 5", "Sonnet 4.6", observedDOM);
      expect(p.retry.getAttribute("aria-label")).toBeNull();
      expect(await f.run()).toEqual(safeguardFailure);
      expect(p.retry.clicks + p.fallback.clicks + f.stop.clicks + f.send.clicks).toBe(0);
    }
    for (const variant of ["legacy", "both", "duplicate_edit", "wrong_family", "suffix", "prefix", "wrong_case"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); const p = observedClaudePause(f);
      if (variant === "legacy") p.retry.text = "Retry with Opus 5";
      if (variant === "both") p.surface.append(new Element("BUTTON", {}, "Retry with Opus 5"));
      if (variant === "duplicate_edit") p.surface.append(p.retry.cloneNode(true));
      if (variant === "wrong_family") p.retry.text = "Edit and retry with Opus 5.5";
      if (variant === "suffix") p.retry.text += " now";
      if (variant === "prefix") p.retry.text = "Please " + p.retry.text;
      if (variant === "wrong_case") p.retry.text = "Edit And Retry with Opus 5";
      const result = await f.run();
      if (variant === "legacy") expect(result).toEqual(safeguardFailure);
      else expect(result.error, variant).toBeUndefined();
      expect(p.retry.clicks + p.fallback.clicks + f.stop.clicks + f.send.clicks).toBe(0);
    }
  });

  test("Claude safeguard CODE exception requires one exact visible token in the provider wrapper", async () => {
    for (const mutation of ["missing_wrapper", "wrong_wrapper", "pre", "outer_code", "tooltip", "own_authored", "hidden", "aria_hidden", "inert", "display", "visibility", "split", "nested", "extra", "long", "empty", "duplicate"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run(); const p = observedClaudePause(f);
      if (mutation === "missing_wrapper") delete p.surface.values["data-testid"];
      if (mutation === "wrong_wrapper") p.surface.values["data-testid"] = "foreign-stop-warning";
      if (["pre", "outer_code", "tooltip"].includes(mutation)) {
        const parent = p.details.parentElement!; parent.children = parent.children.filter(node => node !== p.details);
        const wrapper = new Element(mutation === "pre" ? "PRE" : mutation === "outer_code" ? "CODE" : "SPAN", mutation === "tooltip" ? { role: "tooltip" } : {});
        wrapper.append(p.details); parent.append(wrapper);
      }
      if (mutation === "own_authored") p.details.values["data-message-author-role"] = "assistant";
      if (mutation === "hidden") p.details.values.hidden = "";
      if (mutation === "aria_hidden") p.details.values["aria-hidden"] = "true";
      if (mutation === "inert") p.details.values.inert = "";
      if (mutation === "display") p.details.values.display = "none";
      if (mutation === "visibility") p.details.values.visibility = "hidden";
      if (mutation === "split") { p.details.text = "[reasoning_"; p.details.append(new Element("#text", {}, "extraction]")); }
      if (mutation === "nested") { p.details.text = ""; p.details.append(new Element("SPAN", {}, "[reasoning_extraction]")); }
      if (mutation === "extra") p.details.text += " private-canary";
      if (mutation === "long") p.details.text = "private-canary".repeat(1000);
      if (mutation === "empty") p.details.text = "";
      if (mutation === "duplicate") p.surface.append(p.details.cloneNode(true));
      const result = await f.run(); expect(result.error, mutation).toBeUndefined();
      expect(JSON.stringify(result)).not.toContain("private-canary");
      expect(p.retry.clicks + p.fallback.clicks + f.stop.clicks + f.send.clicks).toBe(0);
    }
  });

  test("Claude safeguard quotations in authored messages, tool code, editors and hidden UI never classify", async () => {
    for (const location of ["user", "assistant", "tool_code", "editor", "hidden", "aria_hidden", "inert", "visibility", "display"]) {
      const f = fixture(provider, { userPrompt: prompt }); const p = observedClaudePause(f);
      f.body.children = f.body.children.filter(node => node !== p.surface);
      if (location === "user") {
        f.userBody!.text = prompt + "\n";
        f.userBody!.append(p.surface, new Element("#text", {}, "\n\n" + markerLine));
        f.world.__computaModelFirstPrompt = f.userBody!.innerText;
      } else if (location === "assistant") f.answer.append(p.surface);
      else if (location === "tool_code") { const pre = new Element("PRE"); pre.append(p.surface); f.body.append(pre); }
      else if (location === "editor") f.composer.append(p.surface);
      else {
        if (location === "hidden") p.surface.values.hidden = "";
        if (location === "aria_hidden") p.surface.values["aria-hidden"] = "true";
        if (location === "inert") p.surface.values.inert = "";
        if (location === "visibility") p.surface.values.visibility = "hidden";
        if (location === "display") p.surface.values.display = "none";
        f.body.append(p.surface);
      }
      expect((await f.run()).error, location).toBeUndefined();
      expect(p.retry.clicks + p.fallback.clicks).toBe(0);
    }
  });

  test("Claude safeguard scan is bounded and cannot leak unknown UI or turn a partial scan into a block", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run();
    for (let n = 0; n < 2100; n++) f.body.append(new Element("SPAN", {}, "private-canary"));
    const p = observedClaudePause(f);
    const result = await f.run(); expect(result.error).toBeUndefined();
    expect(JSON.stringify(result)).not.toContain("private-canary"); expect(p.retry.clicks + p.fallback.clicks).toBe(0);
    const g = fixture(provider, { userPrompt: prompt }); await g.run(); const q = observedClaudePause(g);
    Object.defineProperty(q.surface, "childNodes", { get: () => { throw new Error("private-canary"); } });
    const unavailable = await g.run(); expect(unavailable.error).toBeUndefined();
    expect(JSON.stringify(unavailable)).not.toContain("private-canary"); expect(q.retry.clicks + q.fallback.clicks).toBe(0);
  });

  test("Claude safeguard cleanup retains ordinary exact first body and Incognito proof and never clicks", async () => {
    const f = fixture(provider, { userPrompt: prompt }); const bound = await f.run(); const p = observedClaudePause(f);
    f.stop.connected = true;
    expect(await f.run("stop")).toMatchObject({ responseBlocked: true, busy: false, stopped: false, text: "", answerComplete: false,
      temporary: true, firstUserVerified: true, firstUserFingerprint: bound.firstUserFingerprint, firstUserMarkerVerified: true });
    for (const control of [f.send, f.stop, f.toggle, f.exit, p.retry, p.fallback]) expect(control.clicks).toBe(0);
    const unbound = fixture(provider, { userPrompt: prompt }); observedClaudePause(unbound);
    expect(await unbound.run()).toEqual(safeguardFailure); expect(unbound.world.__computaModelFirstProof).toBeUndefined();
    expect(await unbound.run("stop")).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    for (const mutation of ["body", "owner", "temporary"]) {
      const g = fixture(provider, { userPrompt: prompt }); await g.run(); const q = observedClaudePause(g);
      if (mutation === "body") g.userBody!.text += " changed";
      if (mutation === "owner") g.world.__computaModelOwner = "foreign";
      if (mutation === "temporary") g.badge.connected = false;
      expect((await g.run("stop")).error).toBeTruthy();
      expect(q.retry.clicks + q.fallback.clicks + g.stop.clicks).toBe(0);
    }
  });

  test("Claude safeguard cleanup cannot fall through to clickable Stop after the pause disappears", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run(); const p = observedClaudePause(f);
    expect(await f.run()).toEqual(safeguardFailure);
    p.surface.connected = false; f.stop.connected = true;
    expect(await f.run("stop", { requireClaudeSafeguardPause: true })).toEqual({ error: "model_unverified" });
    expect(f.stop.clicks + p.retry.clicks + p.fallback.clicks).toBe(0);
    // The new restriction changes only native's explicitly tagged read.
    expect(await f.run("stop")).toMatchObject({ stopped: true }); expect(f.stop.clicks).toBe(1);
  });

  test("Claude safeguard arrival cannot replace fresh-page ownership rejection after model-proof await", async () => {
    const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element);
    picker.selected("Opus 5"); let tracked = false, value: unknown;
    Object.defineProperty(f.world, "__computaModelReadUI", { configurable: true,
      get: () => value, set: next => {
        value = next; if (tracked) return; tracked = true;
        queueMicrotask(() => { observedClaudePause(f); f.world.__computaModelOwner = "foreign"; });
      } });
    const result = await f.run("inspect", { expectedModelChoice: { key: "Opus 5", label: "Opus 5" } });
    expect(tracked).toBe(true); expect(result).toMatchObject({ error: "model_unverified" });
    expect(result.detail).not.toBe("reasoning_extraction");
    expect(f.send.clicks).toBe(0);
  });

  test("Claude safeguard arrival during the first-user digest aborts while ownership drift still wins", async () => {
    for (const drift of [false, true]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run();
      let p: ReturnType<typeof observedClaudePause>;
      f.onDigest(() => {
        p = observedClaudePause(f);
        if (drift) f.world.__computaModelOwner = "foreign";
      });
      const result = await f.run();
      expect(result).toMatchObject(drift ? { error: "conversation_changed", detail: "first_user_message" } : safeguardFailure);
      expect(p!.retry.clicks + p!.fallback.clicks + f.send.clicks).toBe(0);
    }
  });


  function fiveHourLimit(f: ReturnType<typeof fixture>, apostrophe = '’') {
    const usage = new Element('BUTTON', { 'aria-haspopup': 'dialog', 'aria-expanded': 'false',
      'aria-label': 'View usage limits · 100% used · 2 limit resets available' });
    const card = new Element('SECTION'), heading = new Element('P', {}, `You${apostrophe}ve hit your 5-hour limit. It resets at 5:00 AM.`);
    const notify = new Element('BUTTON', {}, 'Turn on notifications');
    const detail = new Element('SPAN', {}, 'and Claude will notify you, or reset now and keep going.');
    const about = new Element('BUTTON', { 'aria-haspopup': 'dialog', 'aria-expanded': 'false' }, 'About resets');
    const offer = new Element('BUTTON', {}, 'Get more usage');
    const reset = new Element('A', { href: 'https://claude.ai/settings/usage?highlight=resets' }, 'Use reset');
    const dismiss = new Element('BUTTON', {}, 'Dismiss');
    card.append(heading, notify, detail, about, offer, reset, dismiss); f.body.append(usage, card); f.send.disabled = true;
    return { usage, card, heading, notify, detail, about, offer, reset, dismiss, controls: [usage, notify, about, offer, reset, dismiss] };
  }

  test('five-hour quota aborts before and after exact insertion with cleanup witness only on pristine inspect', async () => {
    for (const apostrophe of ["'", '’']) for (const inserted of [false, true]) {
      for (const action of inserted ? ['sendReady', 'submit'] : ['inspect', 'insert', 'sendReady', 'submit']) {
        const f = fixture(provider);
        if (inserted) expect((await f.run('insert', { prompt: outbound })).inserted).toBe(true);
        const surface = fiveHourLimit(f, apostrophe), draft = f.composer.innerText, events = f.composer.events.length;
        expect(await f.run(action, { prompt: outbound }), `${inserted}/${action}`).toEqual(
          !inserted && action === 'inspect' ? freshQuotaReceipt(f) : { error: 'website_usage_limit' });
        expect(f.composer.innerText).toBe(draft); expect(f.composer.events.length).toBe(events);
        expect([...surface.controls, f.send, f.stop, f.exit, f.toggle].every(node => node.clicks === 0)).toBe(true);
        expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
      }
    }
    const f = fixture(provider, { temporary: false }); fiveHourLimit(f);
    expect(await f.run('inspect')).toEqual(freshQuotaReceipt(f));
    expect(await f.run('stop')).toMatchObject({ error: 'temporary_mode_unverified' });
    expect(f.stop.clicks).toBe(0);
  });

  test('five-hour quota requires the independent visible usage and exact bounded banner controls', async () => {
    for (const variation of ['authored', 'quoted', 'hidden-card', 'hidden-copy', 'inert', 'aria-hidden', 'duplicate-banner',
      'duplicate-usage', 'hidden-usage', 'non-100', 'open-usage', 'wrong-link', 'extra-query', 'foreign-link', 'missing-control',
      'extra-control', 'disabled-control', 'open-about', 'bad-clock', 'wrong-copy', 'enabled-send', 'duplicate-send',
      'hidden-send', 'unowned-draft', 'clipped', 'foreign-owner', 'wrong-route']) {
      const f = fixture(provider), s = fiveHourLimit(f);
      switch (variation) {
        case 'authored': s.card.values['data-testid'] = 'assistant-message'; break;
        case 'quoted': s.card.tagName = 'PRE'; break;
        case 'hidden-card': s.card.values.hidden = ''; break;
        case 'hidden-copy': s.detail.values.hidden = ''; break;
        case 'inert': s.card.values.inert = ''; break;
        case 'aria-hidden': s.detail.values['aria-hidden'] = 'true'; break;
        case 'duplicate-banner': f.body.append(s.card.cloneNode(true)); break;
        case 'duplicate-usage': f.body.append(s.usage.cloneNode()); break;
        case 'hidden-usage': s.usage.values.hidden = ''; break;
        case 'non-100': s.usage.values['aria-label'] = s.usage.values['aria-label'].replace('100%', '99%'); break;
        case 'open-usage': s.usage.values['aria-expanded'] = 'true'; break;
        case 'wrong-link': s.reset.values.href = 'https://claude.ai/settings/usage'; break;
        case 'extra-query': s.reset.values.href += '&other=true'; break;
        case 'foreign-link': s.reset.values.href = 'https://example.invalid/settings/usage?highlight=resets'; break;
        case 'missing-control': s.notify.text = 'Notify'; break;
        case 'extra-control': s.card.append(new Element('BUTTON', {}, 'Other')); break;
        case 'disabled-control': s.offer.disabled = true; break;
        case 'open-about': s.about.values['aria-expanded'] = 'true'; break;
        case 'bad-clock': s.heading.text = s.heading.text.replace('5:00 AM', '25:00 AM'); break;
        case 'wrong-copy': s.detail.text = 'Your usage credits are enabled.'; break;
        case 'enabled-send': f.send.disabled = false; break;
        case 'duplicate-send': f.body.append(f.send.cloneNode()); break;
        case 'hidden-send': f.send.values.hidden = ''; break;
        case 'unowned-draft': f.composer.text = outbound; break;
        case 'clipped': s.card.append(...Array.from({ length: 97 }, () => new Element('SPAN'))); break;
        case 'foreign-owner': f.world.__computaModelOwner = 'foreign'; break;
        case 'wrong-route': f.location.pathname = '/chat/other'; f.document.URL = f.origin + f.location.pathname; break;
      }
      const result = await f.run('inspect', { prompt: outbound });
      expect(result.error, variation).not.toBe('website_usage_limit'); expect(result.freshQuotaAbort, variation).toBeUndefined();
      expect([...s.controls, f.send, f.stop].every(node => node.clicks === 0), variation).toBe(true);
    }
  });

  test('five-hour quota cannot classify a changed inserted draft, submitted turn or lost ownership', async () => {
    for (const variation of ['draft', 'prompt', 'private-prompt', 'submitted', 'proof', 'owner', 'authored', 'inspect']) {
      const f = fixture(provider);
      expect((await f.run('insert', { prompt: outbound })).inserted).toBe(true);
      const s = fiveHourLimit(f); let sentPrompt = outbound;
      switch (variation) {
        case 'draft': f.composer.text += 'changed'; break;
        case 'prompt': sentPrompt += 'changed'; break;
        case 'private-prompt': f.world.__computaModelFirstPrompt += 'changed'; break;
        case 'submitted': f.world.__computaModelFirstSubmitted = true; break;
        case 'proof': f.world.__computaModelFirstProof = {}; break;
        case 'owner': f.world.__computaModelOwner = 'foreign'; break;
        case 'authored': f.body.append(new Element('DIV', { 'data-testid': 'user-message' })); break;
      }
      const draft = f.composer.innerText, events = f.composer.events.length;
      const result = await f.run(variation === 'inspect' ? 'inspect' : 'sendReady', { prompt: sentPrompt });
      expect(result.error, variation).not.toBe('website_usage_limit'); expect(result.freshQuotaAbort, variation).toBeUndefined();
      expect(f.composer.innerText).toBe(draft); expect(f.composer.events.length).toBe(events);
      expect([...s.controls, f.send, f.stop].every(node => node.clicks === 0)).toBe(true);
    }
  });

  function freshAccountLimit(f: ReturnType<typeof fixture>) {
    const picker = installObservedModelPicker(f, provider, Element); picker.selected("Sonnet 5");
    const usage = new Element("BUTTON", { "aria-haspopup": "dialog", "aria-label": "View usage limits · 100% used" });
    const card = new Element("DIV"), heading = new Element("H3", {}, "You’ve reached your usage limit.");
    const reset = new Element("P", {}, "Your limit resets at 8:20 AM. Turn on notifications and Claude will notify you then.");
    const credits = new Element("P", {}, "Wait for the reset, or keep working now with usage credits, billed on top of your plan.");
    const actions = new Element("DIV"), buttons = ["Get notified", "Get more usage", "Dismiss"].map(label => new Element("BUTTON", {}, label));
    actions.append(...buttons); card.append(heading, reset, credits, actions); f.body.append(usage, card);
    f.send.disabled = true;
    return { usage, picker, card, heading, reset, credits, actions, buttons };
  }

  test("fresh account limit aborts each preflight action without using the picker, composer or notice", async () => {
    for (const temporary of [false, true]) for (const action of ["inspect", "discoverModels", "selectModel", "modelDiagnostic",
      "verifyModel", "enableTemporary", "prepare", "insert", "sendReady", "submit"]) {
      const f = fixture(provider, { temporary }), surface = freshAccountLimit(f);
      const observed = await f.run(action, { prompt: outbound, expectedModelChoice: { key: "Sonnet 5", label: "Sonnet 5" } });
      expect(observed, action).toEqual(action === "inspect" ? freshQuotaReceipt(f) : { error: "website_usage_limit" });
      for (const control of [...surface.buttons, surface.usage, surface.picker.trigger, f.send, f.stop, f.exit, f.toggle])
        expect(control.clicks).toBe(0);
      expect(f.composer.events).toEqual([]); expect(f.composer.innerText).toBe(""); expect(f.document.activeElement).toBeNull();
    }
  });

  test("fresh account limit requires the exact new-chat controls, card, visible copy and unused composer", async () => {
    for (const variation of ["partial-usage", "duplicate-usage", "hidden-usage", "not-popup", "open-picker", "missing-picker",
      "permitted-send", "nonempty-draft", "changed-notice", "bad-clock", "no-card-controls", "disabled-offer", "credits-active", "meter-text-99", "additional-control",
      "quoted-card", "in-editor", "hidden-text", "different-card", "authored-row", "alternate-author", "clipped", "chat-route", "submitted"]) {
      const f = fixture(provider), { usage, picker, card, reset, credits, actions, buttons } = freshAccountLimit(f);
      switch (variation) {
        case "partial-usage": usage.values["aria-label"] = "View usage limits · 99% used"; break;
        case "duplicate-usage": f.body.append(usage.cloneNode()); break;
        case "hidden-usage": usage.values.hidden = ""; break;
        case "not-popup": delete usage.values["aria-haspopup"]; break;
        case "open-picker": picker.trigger.values["aria-expanded"] = "true"; break;
        case "missing-picker": picker.trigger.connected = false; break;
        case "permitted-send": f.send.disabled = false; break;
        case "nonempty-draft": f.composer.text = "private draft"; break;
        case "changed-notice": credits.text = credits.text.replace("usage credits", "model choices"); break;
        case "bad-clock": reset.text = reset.text.replace("8:20 AM", "25:20 AM"); break;
        case "no-card-controls": buttons[2].text = "Close"; buttons[0].text = "Notify me"; break;
        case "disabled-offer": buttons[1].disabled = true; break;
        case "credits-active": credits.text += " Your usage credits are enabled."; break;
        case "meter-text-99": delete usage.values["aria-label"]; usage.text = "View usage limits · 99% used"; break;
        case "additional-control": actions.append(new Element("BUTTON", {}, "Another action")); break;
        case "quoted-card": card.tagName = "PRE"; break;
        case "in-editor": f.body.children = f.body.children.filter(node => node !== card); f.composer.append(card); break;
        case "hidden-text": credits.values.hidden = ""; break;
        case "different-card": actions.children.pop(); f.body.append(buttons[2]); break;
        case "authored-row": f.body.append(new Element("DIV", { "data-testid": "assistant-message", hidden: "" })); break;
        case "alternate-author": f.body.append(new Element("DIV", { "data-message-author-role": "assistant" })); break;
        case "clipped": card.append(...Array.from({ length: 97 }, () => new Element("SPAN"))); break;
        case "chat-route": f.location.pathname = "/chat/other"; f.document.URL = f.origin + f.location.pathname; break;
        case "submitted": f.world.__computaModelFirstSubmitted = true; break;
      }
      const result = await f.run();
      expect(result.error, variation).not.toBe("website_usage_limit"); expect(result.freshQuotaAbort, variation).toBeUndefined();
      expect(buttons.map(node => node.clicks)).toEqual([0, 0, 0]);
    }
  });

  test("fresh account limit accepts the exact rendered meter with split reset time and varied auxiliary copy", async () => {
    const f = fixture(provider), { usage, reset, credits, buttons } = freshAccountLimit(f);
    delete usage.values["aria-label"]; usage.append(new Element("SPAN", {}, "View usage limits ·"), new Element("SPAN", {}, "100% used"));
    reset.text = "Your limit resets at "; reset.append(new Element("STRONG", {}, "8:20 AM"), new Element("#text", {}, "."));
    credits.text = "Wait for the reset, or keep working now with usage credits. See your billing settings for details.";
    buttons[0].text = "Notify me"; f.composer.append(new Element("P")); f.composer.children[0].append(new Element("BR"));
    expect(await f.run()).toEqual(freshQuotaReceipt(f));
  });

  test("fresh account limit cannot supersede lost ownership or establish quota cleanup", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run(); freshAccountLimit(f);
    f.userRoot!.parentElement!.children = []; f.userRoot!.connected = false;
    expect(await f.run("inspect")).toMatchObject({ error: "conversation_changed", detail: "user_count" });
    expect(await f.run("stop")).toMatchObject({ error: "conversation_changed", detail: "user_count" });
    const fresh = fixture(provider, { temporary: false }); freshAccountLimit(fresh);
    expect(await fresh.run("stop")).toMatchObject({ error: "temporary_mode_unverified" });
  });

  function incognitoResetCard(f: ReturnType<typeof fixture>) {
    const card = new Element("DIV"), heading = new Element("DIV"), actions = new Element("DIV");
    const clock = new Element("#text", {}, "Usage limit reached · Resets 7:00 PM · ");
    const shared = new Element("A", { href: "https://claude.ai/settings/claude-code" }, "limits shared with Claude Code");
    const available = new Element("SPAN", {}, "You have 2 resets available.");
    const about = new Element("BUTTON", { "aria-haspopup": "dialog", "aria-expanded": "false" }, "About resets");
    const offer = new Element("BUTTON", {}, "Get more usage");
    const reset = new Element("A", { href: "https://claude.ai/settings/usage?highlight=resets" }, "Use reset");
    heading.append(clock, shared); actions.append(about, offer, reset);
    card.append(heading, available, actions); f.body.append(card); f.send.disabled = true;
    return { card, clock, shared, available, about, offer, reset, actions };
  }

  function freshIncognitoResetLimit(f: ReturnType<typeof fixture>) {
    const picker = installObservedModelPicker(f, provider, Element); picker.selected("Haiku 5.5");
    return { picker, ...incognitoResetCard(f) };
  }

  test("the signed-in Incognito reset card aborts fresh preflight without interacting or proving cleanup", async () => {
    for (const action of ["inspect", "discoverModels", "selectModel", "verifyModel", "enableTemporary", "prepare", "insert", "sendReady", "submit"]) {
      const f = fixture(provider), { picker, about, offer, reset, shared, available, clock } = freshIncognitoResetLimit(f);
      if (["inspect", "sendReady", "submit"].includes(action))
        clock.text = "Usage limit reached · Resets tomorrow at 12:00 AM · ";
      if (action === "prepare") {
        reset.values.href = "/settings/usage?highlight=resets"; available.text = "You have 1 reset available.";
      }
      const result = await f.run(action, { prompt: outbound, expectedModelChoice: { key: "Haiku 5.5", label: "Haiku 5.5" } });
      expect(result, action).toEqual(action === "inspect" ? freshQuotaReceipt(f) : { error: "website_usage_limit" });
      for (const control of [picker.trigger, about, offer, reset, shared, f.send, f.stop, f.exit, f.toggle])
        expect(control.clicks).toBe(0);
      expect(f.composer.events).toEqual([]); expect(f.composer.innerText).toBe(""); expect(f.document.activeElement).toBeNull();
    }
    const f = fixture(provider, { temporary: false }); freshIncognitoResetLimit(f); f.document.URL += "?incognito";
    expect(await f.run()).toEqual(freshQuotaReceipt(f));
    expect(await f.run("stop")).toMatchObject({ error: "temporary_mode_unverified" });
    expect(f.stop.clicks).toBe(0);
  });

  test("the exact Incognito reset card blocks an already-inserted draft before Send", async () => {
    for (const action of ["sendReady", "submit"]) for (const resetTime of ["8:30 PM", "tomorrow at 8:30 PM"]) {
      const f = fixture(provider);
      expect((await f.run("insert", { prompt: outbound })).inserted).toBe(true);
      const { picker, clock, shared, about, offer, reset } = freshIncognitoResetLimit(f);
      clock.text = `Usage limit reached · Resets ${resetTime} · `;
      const draft = f.composer.innerText, events = f.composer.events.length;
      expect(await f.run(action, { prompt: outbound }), `${action}/${resetTime}`).toEqual({ error: "website_usage_limit" });
      expect(f.composer.innerText).toBe(draft);
      expect(f.composer.events.length).toBe(events);
      expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
      const inspected = await f.run("inspect");
      expect(inspected.error).not.toBe("website_usage_limit");
      expect(inspected.freshQuotaAbort).toBeUndefined();
      for (const control of [picker.trigger, shared, about, offer, reset, f.send, f.stop, f.exit])
        expect(control.clicks).toBe(0);
    }
  });

  test("an inserted draft does not widen the Incognito reset card proof", async () => {
    for (const variation of ["changed-draft", "changed-prompt", "wrong-owner", "wrong-link", "missing-reset", "copy",
        "non-incognito", "missing-incognito", "aria-only-disabled", "duplicate-send", "submitted", "physical-message"]) {
      const f = fixture(provider);
      expect((await f.run("insert", { prompt: outbound })).inserted).toBe(true);
      const { clock, shared, reset } = freshIncognitoResetLimit(f);
      let prompt = outbound;
      switch (variation) {
        case "changed-draft": f.composer.text = "Other draft"; f.composer.children = []; break;
        case "changed-prompt": prompt = "Other prompt\n\n" + markerLine; break;
        case "wrong-owner": f.world.__computaModelOwner = "foreign"; break;
        case "wrong-link": shared.values.href = "/settings/usage"; break;
        case "missing-reset": reset.connected = false; break;
        case "copy": clock.text = "Usage limit reached · Resets in a few hours · "; break;
        case "non-incognito": f.document.URL = f.origin + "/new"; break;
        case "missing-incognito": f.badge.connected = false; break;
        case "aria-only-disabled": f.send.disabled = false; f.send.values["aria-disabled"] = "true"; break;
        case "duplicate-send": f.body.append(f.send.cloneNode(true)); break;
        case "submitted": f.world.__computaModelFirstSubmitted = true; break;
        case "physical-message": f.body.append(new Element("DIV", { "data-testid": "assistant-message", hidden: "" })); break;
      }
      const result = await f.run("sendReady", { prompt });
      expect(result.error, variation).not.toBe("website_usage_limit");
      expect(result.freshQuotaAbort, variation).toBeUndefined();
      expect(f.send.clicks + f.stop.clicks + shared.clicks + reset.clicks, variation).toBe(0);
    }
  });

  test("the exact reset card can omit its informational popup or expose it with another button label or role", async () => {
    for (const variation of ["absent", "renamed", "explicit-role", "outside-card"]) {
      const f = fixture(provider), { about, actions, offer, reset, shared, picker } = freshIncognitoResetLimit(f);
      if (variation === "absent" || variation === "outside-card") actions.children.shift();
      if (variation === "outside-card") f.body.append(about);
      if (variation === "renamed") about.text = "Reset information";
      if (variation === "explicit-role") {
        about.tagName = "DIV"; about.values.role = "button"; about.text = "Reset information";
      }
      expect(await f.run(), variation).toEqual(freshQuotaReceipt(f));
      for (const control of [about, offer, reset, shared, picker.trigger, f.send, f.stop]) expect(control.clicks).toBe(0);
      expect(f.composer.events).toEqual([]); expect(f.document.activeElement).toBeNull();
    }
  });

  test("the fresh Incognito reset limit requires the exact complete card and shared preflight guards", async () => {
    const outcomes = {
      "ordinary-new": "route_ineligible", "nonempty-draft": "editor_nonempty", "missing-editor": "editor_guard",
      "send-enabled": "send_guard", "open-picker": "picker_guard", "submitted": undefined, "authored-card": "authored_content",
      "bad-clock": "copy_mismatch", "bad-relative-clock": "copy_mismatch",
      "different-copy": "copy_mismatch", "zero-resets": "copy_mismatch", "wrong-plural": "copy_mismatch",
      "hidden-copy": "copy_unavailable", "clipped-copy": "copy_unavailable", "other-link-origin": "card_links", "other-reset-query": "card_links",
      "missing-offer": "offer_absent", "about-not-popup": "card_controls", "about-open": "card_controls",
      "about-open-state": "card_controls", "about-link": "card_controls", "about-form-control": "card_controls",
      "extra-control": "card_controls", "different-card": "card_controls", "extra-visible-copy": "copy_mismatch", "button-scan-limit": "button_scan_limit"
    } as const;
    for (const variation of Object.keys(outcomes) as (keyof typeof outcomes)[]) {
      const f = fixture(provider), { picker, card, clock, shared, available, about, offer, reset, actions } = freshIncognitoResetLimit(f);
      switch (variation) {
        case "ordinary-new": f.temporary(false); break;
        case "nonempty-draft": f.composer.text = "existing draft"; break;
        case "missing-editor": f.composer.connected = false; break;
        case "send-enabled": f.send.disabled = false; break;
        case "open-picker": picker.trigger.values["aria-expanded"] = "true"; break;
        case "submitted": f.world.__computaModelFirstSubmitted = true; break;
        case "authored-card": card.values["data-testid"] = "assistant-message"; break;
        case "bad-clock": clock.text = "Usage limit reached · Resets 25:00 PM · "; break;
        case "bad-relative-clock": clock.text = "Usage limit reached · Resets tomorrow at 12:60 AM · "; break;
        case "different-copy": available.text = "You have 2 rewards available."; break;
        case "zero-resets": available.text = "You have 0 resets available."; break;
        case "wrong-plural": available.text = "You have 1 resets available."; break;
        case "hidden-copy": available.values.hidden = ""; break;
        case "clipped-copy": card.append(...Array.from({ length: 97 }, () => new Element("SPAN"))); break;
        case "other-link-origin": shared.values.href = "https://other.example/settings/claude-code"; break;
        case "other-reset-query": reset.values.href = "https://claude.ai/settings/usage?highlight=resets&other=1"; break;
        case "missing-offer": offer.text = "More options"; break;
        case "about-not-popup": delete about.values["aria-haspopup"]; break;
        case "about-open": about.values["aria-expanded"] = "true"; break;
        case "about-open-state": about.values["data-state"] = "open"; break;
        case "about-link":
          actions.children.shift(); card.append(about);
          about.tagName = "A"; about.values.role = "button"; about.values.href = "/settings/usage"; break;
        case "about-form-control": about.tagName = "SELECT"; about.values.role = "button"; break;
        case "extra-control": card.append(new Element("BUTTON", {}, "Another action")); break;
        case "different-card": actions.children.pop(); f.body.append(reset); break;
        case "extra-visible-copy": card.append(new Element("SPAN", {}, "Credits already enabled")); break;
        case "button-scan-limit": f.body.append(...Array.from({ length: 257 }, () => new Element("BUTTON"))); break;
      }
      const result = await f.run();
      expect(result.error, variation).not.toBe("website_usage_limit"); expect(result.freshQuotaAbort, variation).toBeUndefined();
      expect(JSON.parse(result.quotaDiagnostic ?? "{}").resetCardOutcome, variation).toBe(outcomes[variation]);
      for (const control of [about, offer, reset, shared, f.send]) expect(control.clicks).toBe(0);
    }
  });

  test("the rejected offer diagnostic distinguishes exact anchored alternatives without qualifying them", async () => {
    const outcomes = {
      disabled: "offer_disabled", hidden: "offer_hidden", duplicate: "offer_ambiguous", role: "offer_alternate_role",
      title: "offer_alternate_label_source", labelledby: "offer_alternate_label_source", overridden: "offer_alternate_label_source",
      unrelated: "offer_missing_or_ambiguous", externalLabel: "offer_absent",
    } as const;
    for (const variation of Object.keys(outcomes) as (keyof typeof outcomes)[]) {
      const f = fixture(provider), { card, about, actions, offer, reset, shared, picker } = freshIncognitoResetLimit(f);
      const labelID = "synthetic-private-offer-id";
      switch (variation) {
        case "disabled": offer.values["aria-disabled"] = "true"; break;
        case "hidden": offer.values.hidden = ""; break;
        case "duplicate": actions.append(offer.cloneNode()); break;
        case "role": offer.tagName = "DIV"; offer.values.role = "button"; break;
        case "title": offer.text = ""; offer.values.title = "Get more usage"; break;
        case "labelledby":
        case "externalLabel":
          offer.text = ""; offer.values["aria-labelledby"] = labelID;
          (variation === "labelledby" ? card : f.body).append(new Element("SPAN", { id: labelID }, "Get more usage")); break;
        case "overridden": offer.values["aria-label"] = "synthetic private alternate label"; break;
        case "unrelated": offer.disabled = true; reset.values.href += "&unrelated=true"; break;
      }
      const result = await f.run();
      expect(result.error, variation).toBeUndefined(); expect(result.freshQuotaAbort).toBeUndefined();
      expect(JSON.parse(result.quotaDiagnostic).resetCardOutcome, variation).toBe(outcomes[variation]);
      expect(result.quotaDiagnostic).not.toContain(labelID);
      expect(result.quotaDiagnostic).not.toContain("synthetic private alternate label");
      for (const control of [about, offer, reset, shared, picker.trigger, f.send]) expect(control.clicks).toBe(0);
      expect(f.composer.events).toEqual([]); expect(f.document.activeElement).toBeNull();
    }
  });

  test("Claude discovery aborts for an exact reset card only after its fresh picker has closed", async () => {
    for (const variation of ["matched", "matched-explicit-role", "disabled-offer", "non-popup", "lost-editor", "lost-mode", "lost-owner", "select-model"]) {
      const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element);
      const surface = incognitoResetCard(f); surface.card.values.hidden = "";
      for (const menu of [picker.menu, picker.nested]) {
        const dismiss = menu.onDispatch!;
        menu.onDispatch = (event: any) => {
          dismiss(event);
          if (event.type !== "keydown" || event.key !== "Escape" || picker.trigger.values["aria-expanded"] !== "false") return;
          delete surface.card.values.hidden;
          if (variation === "matched-explicit-role") {
            surface.about.tagName = "DIV"; surface.about.values.role = "button"; surface.about.text = "Reset information";
          }
          if (variation === "disabled-offer") surface.offer.disabled = true;
          if (variation === "non-popup") delete surface.about.values["aria-haspopup"];
          if (variation === "lost-editor") f.composer.connected = false;
          if (variation === "lost-mode") f.exit.connected = false;
          if (variation === "lost-owner") f.world.__computaModelOwner = "foreign";
        };
      }
      const action = variation === "select-model" ? "selectModel" : "discoverModels";
      const overrides = variation === "select-model" ? { modelChoice: picker.choice("Sonnet 4.6") } : {};
      let result = await f.run(action, overrides);
      expect(result.pending, variation).toBe(true);
      for (let phase = 0; phase < 4 && result.pending; phase++) {
        expect(result.quotaDiagnostic, variation).toBeUndefined();
        result = await f.run(action, overrides);
      }
      if (variation === "lost-owner") expect(result.error).toBe("model_unverified");
      else if (variation === "select-model") expect(result.selected).toBe(true);
      else if (variation === "matched" || variation === "matched-explicit-role") {
        expect(Object.keys(result).sort()).toEqual(["error", "quotaDiagnostic"]);
        expect(result.error).toBe("website_usage_limit");
      }
      else {
        expect(result.error, variation).toBeUndefined();
        expect(result.modelChoices?.length ?? 0, variation).toBeGreaterThan(0);
      }
      if (["matched", "matched-explicit-role", "disabled-offer", "non-popup"].includes(variation)) {
        const diagnostic = JSON.parse(result.quotaDiagnostic);
        expect(diagnostic.resetCardOutcome).toBe(variation === "disabled-offer" ? "offer_disabled"
          : variation === "non-popup" ? "card_controls" : "matched_after_menu");
        expect(diagnostic.temporaryProof).toBeNull();
        expect(result.freshQuotaAbort).toBeUndefined();
        expect((await f.run(action, overrides)).quotaDiagnostic).toBeUndefined();
      } else expect(result.quotaDiagnostic, variation).toBeUndefined();
      expect(f.send.clicks).toBe(0); expect(surface.about.clicks + surface.offer.clicks + surface.reset.clicks + surface.shared.clicks).toBe(0);
      expect(f.composer.events).toEqual([]);
    }
  });

  test('Claude discovery rechecks five-hour quota at verified picker close without overriding owner loss', async () => {
    for (const drift of [false, true]) {
      const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element), surface = fiveHourLimit(f);
      surface.card.values.hidden = ''; surface.usage.values.hidden = '';
      for (const menu of [picker.menu, picker.nested]) {
        const dismiss = menu.onDispatch!;
        menu.onDispatch = (event: any) => {
          dismiss(event);
          if (event.type !== 'keydown' || event.key !== 'Escape' || picker.trigger.values['aria-expanded'] !== 'false') return;
          delete surface.card.values.hidden; delete surface.usage.values.hidden;
          if (drift) f.world.__computaModelOwner = 'foreign';
        };
      }
      let result = await f.run('discoverModels');
      expect(result.pending).toBe(true);
      for (let phase = 0; phase < 4 && result.pending; phase++) result = await f.run('discoverModels');
      expect(result.error).toBe(drift ? 'model_unverified' : 'website_usage_limit');
      expect(result.modelChoices).toBeUndefined(); expect(result.freshQuotaAbort).toBeUndefined();
      expect(picker.trigger.values['aria-expanded']).toBe('false'); expect(picker.trigger.clicks).toBe(1);
      expect([...surface.controls, f.send, f.stop].every(node => node.clicks === 0)).toBe(true);
      expect(f.composer.events).toEqual([]);
    }
  });

  function claudeDiscoveryQuotaWaitFixture(variation: string, deadline: number) {
    const f = fixture(provider), picker = installObservedModelPicker(f, provider, Element);
    const surface = incognitoResetCard(f); surface.card.values.hidden = "";
    const extra = new Element("BUTTON", {}, "Unexpected action");
    if (variation === "control_count") surface.card.append(extra);
    if (variation === "active_control") surface.about.values["aria-pressed"] = "true";
    if (variation === "accessory") delete surface.about.values["aria-haspopup"];
    if (variation === "no_canonical_scope") { surface.reset.tagName = "DIV"; surface.reset.values.role = "link"; }
    for (const menu of [picker.menu, picker.nested]) {
      const dismiss = menu.onDispatch!;
      menu.onDispatch = (event: any) => {
        dismiss(event);
        if (event.type === "keydown" && event.key === "Escape" && picker.trigger.values["aria-expanded"] === "false"
          && variation !== "healthy") delete surface.card.values.hidden;
      };
    }
    const waits: { milliseconds: number; expire: () => void }[] = [];
    f.window.webkit.messageHandlers.computaModelClock = { postMessage: ({ milliseconds }: { milliseconds: number }) =>
      new Promise<void>(resolve => waits.push({ milliseconds, expire: resolve })) };
    const run = () => f.run("discoverModels", { operationID: "e05fe31a-e94a-4752-9d68-085b80a2c096", evaluationDeadlineEpochMilliseconds: deadline });
    return { f, picker, surface, extra, waits, run };
  }

  test("Claude's post-close quota wait wakes on delayed control repair and rechecks the exact card", async () => {
    const { f, picker, surface, extra, waits, run } = claudeDiscoveryQuotaWaitFixture("control_count", Date.now() + 5_000);
    expect((await run()).pending).toBe(true); expect((await run()).pending).toBe(true);
    const pending = run();
    for (let tick = 0; tick < 40 && waits.length === 0; tick++) await Promise.resolve();
    expect(waits).toHaveLength(1); expect(waits[0].milliseconds).toBeGreaterThan(0); expect(waits[0].milliseconds).toBeLessThanOrEqual(1_500);
    expect(picker.trigger.values["aria-expanded"]).toBe("false");
    f.observers.at(-1)!.callback([]);
    surface.card.children = surface.card.children.filter(node => node !== extra); extra.connected = false;
    f.observers.at(-1)!.callback([]);
    const result = await pending;
    expect(Object.keys(result).sort()).toEqual(["error", "quotaDiagnostic"]);
    expect(result.error).toBe("website_usage_limit");
    const diagnostic = JSON.parse(result.quotaDiagnostic);
    expect(diagnostic.resetCardOutcome).toBe("matched_after_menu"); expect(diagnostic.resetCardControlReason).toBeUndefined();
    waits[0].expire();
    expect(waits).toHaveLength(1); expect(f.delays).toEqual([]);
    expect(picker.trigger.clicks).toBe(1); expect(f.send.clicks + surface.about.clicks + surface.offer.clicks + surface.reset.clicks + surface.shared.clicks).toBe(0);
    expect(f.composer.events).toEqual([]);
  });

  test('Claude existing post-close wait wakes for five-hour quota and revalidates ownership', async () => {
    for (const drift of [false, true]) {
      const { f, picker, surface, waits, run } = claudeDiscoveryQuotaWaitFixture('control_count', Date.now() + 5_000);
      expect((await run()).pending).toBe(true); expect((await run()).pending).toBe(true);
      const pending = run();
      for (let tick = 0; tick < 40 && waits.length === 0; tick++) await Promise.resolve();
      expect(waits).toHaveLength(1);
      surface.card.connected = false;
      const quota = fiveHourLimit(f);
      if (drift) f.world.__computaModelOwner = 'foreign';
      f.observers.at(-1)!.callback([]);
      const result = await pending;
      expect(result.error).toBe(drift ? 'model_unverified' : 'website_usage_limit');
      expect(result.modelChoices).toBeUndefined(); expect(result.freshQuotaAbort).toBeUndefined();
      waits[0].expire(); expect(waits).toHaveLength(1); expect(f.delays).toEqual([]);
      expect(picker.trigger.clicks).toBe(1); expect(picker.trigger.values['aria-expanded']).toBe('false');
      expect([...quota.controls, f.send, f.stop].every(node => node.clicks === 0)).toBe(true);
      expect(f.composer.events).toEqual([]);
    }
  });

  test("Claude's post-close quota wait uses the original deadline and retains unresolved finite reasons", async () => {
    for (const variation of ["control_count", "active_control", "accessory", "no_canonical_scope", "healthy", "short-budget"]) {
      const start = Date.now(), budget = variation === "short-budget" ? 50 : 500;
      const shape = variation === "short-budget" ? "accessory" : variation;
      const { f, surface, waits, run } = claudeDiscoveryQuotaWaitFixture(shape, start + budget);
      expect((await run()).pending).toBe(true); expect((await run()).pending).toBe(true);
      const pending = run();
      for (let tick = 0; tick < 40 && waits.length === 0; tick++) await Promise.resolve();
      if (variation === "healthy" || variation === "short-budget") expect(waits, variation).toHaveLength(0);
      else {
        expect(waits, variation).toHaveLength(1);
        expect(waits[0].milliseconds).toBeGreaterThan(0); expect(waits[0].milliseconds).toBeLessThanOrEqual(budget - 100);
        waits[0].expire();
      }
      const result = await pending;
      expect(result.error, variation).toBeUndefined(); expect(result.modelChoices?.length ?? 0, variation).toBeGreaterThan(0);
      const diagnostic = JSON.parse(result.quotaDiagnostic);
      expect(diagnostic.resetCardControlReason, variation).toBe(variation === "healthy" ? undefined : shape);
      expect(diagnostic.resetCardOutcome, variation).toBe(variation === "healthy" ? "offer_missing_or_ambiguous" : "card_controls");
      expect(f.send.clicks + surface.about.clicks + surface.offer.clicks + surface.reset.clicks + surface.shared.clicks).toBe(0);
      expect(f.delays).toEqual([]);
    }
  });

  test("Claude's post-close quota wait latches context loss before any catalog or quota can return", async () => {
    for (const drift of ["owner", "trigger", "mode", "editor", "route"]) {
      const { f, picker, surface, extra, waits, run } = claudeDiscoveryQuotaWaitFixture("control_count", Date.now() + 5_000);
      expect((await run()).pending).toBe(true); expect((await run()).pending).toBe(true);
      const pending = run();
      for (let tick = 0; tick < 40 && waits.length === 0; tick++) await Promise.resolve();
      expect(waits, drift).toHaveLength(1);
      const owner = f.world.__computaModelOwner, url = f.document.URL;
      if (drift === "owner") f.world.__computaModelOwner = "foreign";
      if (drift === "trigger") picker.trigger.connected = false;
      if (drift === "mode") f.exit.connected = false;
      if (drift === "editor") f.composer.text = "Foreign draft";
      if (drift === "route") f.document.URL = f.origin + "/new";
      f.observers.at(-1)!.callback([]);
      f.world.__computaModelOwner = owner; f.document.URL = url;
      picker.trigger.connected = true; f.exit.connected = true; f.composer.text = "";
      surface.card.children = surface.card.children.filter(node => node !== extra); extra.connected = false;
      waits[0].expire();
      const result = await pending;
      expect(result.error, drift).toBe("model_unverified"); expect(result.quotaDiagnostic).toBeUndefined(); expect(result.modelChoices).toBeUndefined();
      expect(f.send.clicks + surface.about.clicks + surface.offer.clicks + surface.reset.clicks + surface.shared.clicks).toBe(0);
    }
  });

  test("the fresh reset-card diagnostic is absent from editor actions and inspections after preparation", async () => {
    const f = fixture(provider), { available, about, offer, reset, shared } = freshIncognitoResetLimit(f);
    available.text = "synthetic canary text";
    const before = await f.run();
    expect(JSON.parse(before.quotaDiagnostic).resetCardOutcome).toBe("copy_mismatch");
    expect(before.quotaDiagnostic).not.toContain(available.text);
    const prepared = await f.run("prepare");
    expect(prepared.prepared).toBe(true); expect(prepared.quotaDiagnostic).toBeUndefined();
    expect(JSON.parse((await f.run()).quotaDiagnostic).resetCardOutcome).toBeUndefined();
    for (const control of [about, offer, reset, shared, f.send]) expect(control.clicks).toBe(0);
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
      "p", "section", "main", "body", "html", "dialog", "other", "none", "contents", "visible", "hidden", "collapse", "text", "support", "element",
      "claude_temporary_proof_v1", "stop", "stop_check", "exit_count"]);
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
      expect(JSON.parse(result.quotaDiagnostic)).toMatchObject({ kind: "quota_structure", provider: "claude",
        temporaryProof: { action, verified: false, quotaObservationSource: action === "stop" ? "stop_check" : "preceding_check" } });
      expect(f.send.clicks).toBe(0); expect(f.toggle.clicks).toBe(0);
    }
  });

  test("temporary proof diagnostics distinguish an inspect rejection from a fresh stop check", async () => {
    const healthy = fixture(provider, { userPrompt: prompt });
    expect(JSON.parse((await healthy.run()).quotaDiagnostic).temporaryProof).toEqual({
      kind: "claude_temporary_proof_v1", action: "inspect", quotaObservationSource: "preceding_check",
      quotaPopupCount: 0, quotaBannerCount: 0, quotaSurfaceCount: 0, bannerUpgradeLinkCount: null,
      physicalMode: false, separatePhysicalDialog: null, eligibleExitCount: 1, eligibleHeaderCount: 1,
      incognitoQuery: true, verified: true, reason: "verified" });
    const banner = observedClaudeBanner(healthy, "11:40 PM", true);
    banner.upgrade.values.href += "&private-token=never-log";
    for (const action of ["inspect", "stop"]) {
      const result = await healthy.run(action);
      expect(result.error).toBe("temporary_mode_unverified");
      expect(JSON.parse(result.quotaDiagnostic).temporaryProof).toMatchObject({ action,
        quotaObservationSource: action === "stop" ? "stop_check" : "preceding_check",
        quotaPopupCount: 0, quotaBannerCount: 0, quotaSurfaceCount: 0, bannerUpgradeLinkCount: 0,
        physicalMode: false, separatePhysicalDialog: null, eligibleExitCount: 0, eligibleHeaderCount: 0,
        incognitoQuery: true, verified: false, reason: "exit_count" });
      expect(result.quotaDiagnostic).not.toContain("private-token");
    }
    expect(healthy.send.clicks).toBe(0); expect(banner.upgrade.clicks).toBe(0);
  });

  test("quota proof reports the actual rejecting predicate and leaves skipped predicates unknown", async () => {
    for (const scenario of ["two-surfaces", "separate-dialog", "duplicate-exit", "wrong-header", "query"]) {
      const f = fixture(provider, { userPrompt: prompt }); await f.run();
      const banner = observedClaudeBanner(f, "11:40 PM", true);
      if (scenario === "two-surfaces") observedClaudeQuota(f, false);
      if (scenario === "separate-dialog") unrelatedClaudeDialog(f);
      if (scenario === "duplicate-exit") f.exit.parentElement!.append(f.exit.cloneNode(true));
      if (scenario === "wrong-header") f.badge.text = "PRIVATE_HEADER";
      if (scenario === "query") f.document.URL = f.origin + "/new?incognito=PRIVATE_VALUE";
      const result = await f.run("stop"), proof = JSON.parse(result.quotaDiagnostic).temporaryProof;
      expect(result.error).toBe("temporary_mode_unverified");
      expect(proof).toMatchObject({ kind: "claude_temporary_proof_v1", action: "stop", quotaObservationSource: "stop_check",
        quotaPopupCount: scenario === "two-surfaces" ? 1 : 0, quotaBannerCount: 1,
        quotaSurfaceCount: scenario === "two-surfaces" ? 2 : 1, bannerUpgradeLinkCount: 1, verified: false });
      if (scenario === "two-surfaces") expect(proof).toMatchObject({ physicalMode: false, reason: "multiple_quota_surfaces",
        separatePhysicalDialog: null, eligibleExitCount: null, eligibleHeaderCount: null, incognitoQuery: null });
      if (scenario === "separate-dialog") expect(proof).toMatchObject({ physicalMode: true, reason: "separate_dialog",
        separatePhysicalDialog: true, eligibleExitCount: null, eligibleHeaderCount: null, incognitoQuery: null });
      if (scenario === "duplicate-exit") expect(proof).toMatchObject({ physicalMode: true, reason: "exit_count",
        separatePhysicalDialog: false, eligibleExitCount: 2, eligibleHeaderCount: 1, incognitoQuery: true });
      if (scenario === "wrong-header") expect(proof).toMatchObject({ physicalMode: true, reason: "header_count",
        separatePhysicalDialog: false, eligibleExitCount: 1, eligibleHeaderCount: 0, incognitoQuery: true });
      if (scenario === "query") expect(proof).toMatchObject({ physicalMode: true, reason: "incognito_query",
        separatePhysicalDialog: false, eligibleExitCount: 1, eligibleHeaderCount: 1, incognitoQuery: false });
      expect(JSON.stringify(proof)).not.toContain("PRIVATE");
      expect(JSON.stringify(proof).length).toBeLessThanOrEqual(960);
      for (const control of [f.send, f.stop, f.exit, f.toggle, banner.support, banner.upgrade]) expect(control.clicks).toBe(0);
    }
  });

  test("temporary proof retains the evaluated failure when a later diagnostic read sees changed page state", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run();
    const banner = observedClaudeBanner(f, "11:40 PM", true); f.badge.text = "Wrong header";
    // Only diagnostic label classification reads this support anchor's text.
    // The quota detector uses its fixed URL and substitutes the word messages.
    Object.defineProperty(banner.support, "textContent", { get: () => { f.badge.text = "Incognito chat"; return "messages"; } });
    const result = await f.run("stop");
    expect(f.badge.text).toBe("Incognito chat");
    expect(result.error).toBe("temporary_mode_unverified");
    expect(JSON.parse(result.quotaDiagnostic).temporaryProof).toMatchObject({ action: "stop",
      reason: "header_count", eligibleHeaderCount: 0, verified: false });
    expect(await f.run("stop")).toMatchObject({ usageLimited: true, temporary: true, busy: false,
      stopped: false, firstUserVerified: true });
    expect(f.send.clicks).toBe(0); expect(f.stop.clicks).toBe(0); expect(f.exit.clicks).toBe(0);
  });

  test("temporary proof counts saturate without leaking authored strings or relaxing duplicate rejection", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run();
    const banner = observedClaudeBanner(f, "11:40 PM", true);
    for (let index = 0; index < 1_005; index++) {
      f.exit.parentElement!.append(f.exit.cloneNode(true));
      f.header.parentElement!.append(f.header.cloneNode(true));
    }
    const result = await f.run("stop"), proof = JSON.parse(result.quotaDiagnostic).temporaryProof;
    expect(result.error).toBe("temporary_mode_unverified");
    expect(proof).toMatchObject({ reason: "exit_count", eligibleExitCount: 1_000, eligibleHeaderCount: 1_000, verified: false });
    expect(JSON.stringify(proof).length).toBeLessThanOrEqual(960);
    expect(result.quotaDiagnostic.length).toBeLessThanOrEqual(8192);
    for (const control of [f.send, f.stop, f.exit, banner.support, banner.upgrade]) expect(control.clicks).toBe(0);
    const duplicateLinks = fixture(provider, { userPrompt: prompt }); await duplicateLinks.run();
    const ambiguous = observedClaudeBanner(duplicateLinks, "11:40 PM", true);
    for (let index = 0; index < 1_005; index++) ambiguous.container.append(ambiguous.upgrade.cloneNode(true));
    const rejected = await duplicateLinks.run("stop");
    expect(rejected.error).toBe("temporary_mode_unverified");
    expect(JSON.parse(rejected.quotaDiagnostic).temporaryProof).toMatchObject({ bannerUpgradeLinkCount: 1_000,
      quotaBannerCount: 0, quotaSurfaceCount: 0, physicalMode: false, reason: "exit_count", verified: false });
    expect(rejected.quotaDiagnostic.length).toBeLessThanOrEqual(8192);
    for (const control of [duplicateLinks.send, duplicateLinks.stop, ambiguous.support, ...ambiguous.container.querySelectorAll("a")])
      expect(control.clicks).toBe(0);
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
      picker.selected("Sonnet 5"); let closes = 0;
      const onClosed = () => {
        if (++closes !== 2) return;
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
      for (const menu of [picker.menu, picker.nested].filter(Boolean)) {
        const dismiss = menu!.onDispatch!;
        menu!.onDispatch = (event: any) => { dismiss(event); if (event.type === "keydown" && event.key === "Escape") onClosed(); };
      }
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

describe("Claude isolated malformed JSON correction evidence", () => {
  const raw = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf rejected-one"}}},{"name":"exec_command","arguments":{"cmd":"printf rejected-two"}}},{"name":"exec_command","arguments":{"cmd":"printf rejected-three"}}]}';
  for (const scenario of ["extra_braces", "python_caption", "python_class", "multiple", "extra_code", "empty", "oversize", "utf8_oversize", "prose", "pre_control", "outside_button", "outside_input", "outside_role_button", "missing_caption", "unknown_control"]) {
    test(`${scenario}: evidence never repairs or releases malformed source`, async () => {
      const f = fixture("claude", { userPrompt: "Synthetic owned request" });
      const literal = scenario === "empty" ? " " : scenario === "oversize" ? "x".repeat(220_001)
        : scenario === "utf8_oversize" ? "é".repeat(110_001) : raw;
      const b = observedClaudeCodeBlock(f, literal, claudeCodeCaptionClasses[1]);
      if (scenario === "python_caption") b.label.text = "python";
      if (scenario === "python_class") b.code.values.class = "language-python";
      if (scenario === "multiple") { const pre = new Element("PRE"); pre.append(new Element("CODE", {}, raw)); f.answer.append(pre); }
      if (scenario === "extra_code") f.answer.append(new Element("CODE", {}, " "));
      if (scenario === "prose") f.answer.append(new Element("P", {}, "I cannot perform this request."));
      if (scenario === "pre_control") b.pre.append(new Element("BUTTON", {}, "Authored control"));
      if (scenario === "outside_button") f.answer.append(new Element("BUTTON"));
      if (scenario === "outside_input") f.answer.append(new Element("INPUT"));
      if (scenario === "outside_role_button") f.answer.append(new Element("DIV", { role: "button" }));
      if (scenario === "missing_caption") b.label.values.hidden = "";
      if (scenario === "unknown_control") b.icon.text = "Copy private prose";
      // Override the fixture's provider-chrome renderer only to include every
      // deliberately added test node; no source bytes are omitted by the assertion.
      Object.defineProperty(f.answer, "innerText", { configurable: true, get: () => f.answer.textContent });
      const rendered = f.answer.innerText.trim();
      const result = await f.run("inspect"), evidence = result.completionEvidence.codeStructure;
      expect(result.error).toBeUndefined(); expect(result.answerComplete).toBe(true);
      expect(result.text).toBe(rendered.slice(0, 220_001));
      expect(evidence.selectedExtraction).toBe("rendered_fallback");
      expect(evidence.isolatedJSONCodeBlock).toBe(scenario === "multiple" || scenario === "oversize" ? null : scenario === "extra_braces");
      if (!["multiple", "oversize"].includes(scenario)) expect(evidence.literalCodeValidJSON).toBe(false);
      expect(() => JSON.parse(result.text)).toThrow();
      expect(f.send.clicks).toBe(0);
    });
  }
  test("unavailable isolation diagnostics preserve malformed JSON rejection and original text", async () => {
    const f = fixture("claude", { userPrompt: "Synthetic owned request" });
    const b = observedClaudeCodeBlock(f, raw, claudeCodeCaptionClasses[1]);
    Object.defineProperty(b.code, "classList", { get: () => { throw new Error("Private diagnostic unavailable"); } });
    const result = await f.run("inspect");
    expect(result.error).toBeUndefined(); expect(result.text).toBe(f.answer.innerText.trim());
    expect(result.completionEvidence.codeStructure).toMatchObject({ isolatedJSONCodeBlock: null,
      literalCodeValidJSON: false, selectedExtraction: "rendered_fallback", extractionReason: "invalid_json" });
    expect(f.send.clicks).toBe(0);
  });
  test("new diagnostic exceptions do not reject an otherwise valid literal envelope", async () => {
    const literal = '{"type":"message","text":"I cannot perform this request."}';
    const f = fixture("claude", { userPrompt: "Synthetic owned request" });
    const b = observedClaudeCodeBlock(f, literal, claudeCodeCaptionClasses[1]);
    Object.defineProperty(b.code, "classList", { get: () => { throw new Error("Private diagnostic unavailable"); } });
    const result = await f.run("inspect");
    expect(result.error).toBeUndefined(); expect(result.text).toBe(literal);
    expect(result.completionEvidence.codeStructure).toMatchObject({ isolatedJSONCodeBlock: null,
      literalCodeValidJSON: true, selectedExtraction: "raw_code", extractionReason: "accepted_literal_code" });
    expect(f.send.clicks).toBe(0);
  });
  test("valid literal envelopes retain their original exact extraction", async () => {
    for (const literal of ['{"type":"message","text":"I cannot perform this request."}', '{"type":"tool_calls","calls":[{"name":"browser_close","arguments":{}}]}']) {
      const f = fixture("claude", { userPrompt: "Synthetic owned request" });
      observedClaudeCodeBlock(f, literal, claudeCodeCaptionClasses[1]);
      const result = await f.run("inspect");
      expect(result.text).toBe(literal); expect(result.completionEvidence.codeStructure).toMatchObject({
        literalCodeValidJSON: true, isolatedJSONCodeBlock: true, selectedExtraction: "raw_code", extractionReason: "accepted_literal_code" });
      expect(f.send.clicks).toBe(0);
    }
  });
});

describe('Claude post-submit detached header settling', () => {
  const expectedModelChoice = { key: 'Opus 5', label: 'Opus 5' };
  const operationID = 'a909845c-2857-4b22-a66b-261b22281513';
  const tickUntil = async (condition: () => boolean) => {
    for (let count = 0; count < 100 && !condition(); count++) await Bun.sleep(1);
    expect(condition()).toBe(true);
  };
  const currentHeader = (label = 'Opus 5') => {
    const node = new Element('BUTTON', { 'aria-label': `Model: ${label} High`, 'aria-expanded': 'false', 'data-state': 'closed' });
    node.append(new Element('SPAN', {}, label), new Element('SPAN', {}, 'High'));
    return node;
  };
  const detached = async (action = 'inspect', prepare?: (f: ReturnType<typeof fixture>) => void,
    overrides: Record<string, unknown> = {}, initialResponse = true) => {
    const f = fixture('claude', { userPrompt: 'Bounded detached-header control', response: initialResponse });
    const picker = installObservedModelPicker(f, 'claude', Element);
    picker.selected('Opus 5');
    const before = await f.run('inspect', { expectedModelChoice });
    expect(before).toMatchObject({ firstUserVerified: true, modelEvidence: { selected: expectedModelChoice } });
    expect(f.world.__computaClaudeLastModelTrigger.node).toBe(picker.trigger);
    prepare?.(f);
    picker.trigger.connected = false;
    const clocks: any[] = []; let expire: () => void = () => {}, rejectClock: () => void = () => {};
    f.window.webkit.messageHandlers.computaModelClock = { postMessage: (request: any) => {
      clocks.push(request); return new Promise((resolve, reject) => {
        expire = () => resolve(true); rejectClock = () => reject(new Error('synthetic clock failure'));
      });
    } };
    let settled = false;
    const pending = f.run(action, { expectedModelChoice, operationID, ...overrides }).then(result => { settled = true; return result; });
    await tickUntil(() => clocks.length > 0 || settled);
    expect(settled).toBe(false); expect(clocks).toHaveLength(1);
    expect(clocks[0].milliseconds).toBeGreaterThan(0); expect(clocks[0].milliseconds).toBeLessThanOrEqual(1800);
    expect(f.delays).toHaveLength(0);
    const wake = () => { for (const observer of [...f.observers]) observer.callback([{ type: 'childList', target: f.body }]); };
    const noActions = () => {
      expect(f.send.clicks).toBe(0); expect(picker.trigger.clicks).toBe(0);
      expect(picker.options.every((node: Element) => node.clicks === 0)).toBe(true);
      expect(picker.menu.events).toHaveLength(0); expect(picker.nested!.events).toHaveLength(0);
      expect(clocks).toHaveLength(1);
    };
    return { f, picker, before, pending, wake, noActions, clocks, expire: () => expire(), rejectClock: () => rejectClock() };
  };

  const emptyShell = (f: ReturnType<typeof fixture>) => {
    f.response.replaceChildren(new Element('DIV')); f.controls.connected = false;
    if (!f.article.parentElement) f.messages.append(f.article);
  };
  const pendingDetached = (overrides: Record<string, unknown> = {}) => detached('inspect', emptyShell,
    { allowClaudeModelObservationPending: true, ...overrides }, false);

  test('Claude safeguard pause observed during detached-header waiting wins pending and cannot be unlatched', async () => {
    for (const transient of [false, true]) {
      const x = await pendingDetached(), pause = observedClaudePause(x.f);
      x.wake(); for (let tick = 0; tick < 12; tick++) await Promise.resolve();
      if (transient) {
        pause.surface.connected = false;
        x.f.body.append(currentHeader()); x.wake();
      } else x.expire();
      const result = await x.pending;
      expect(result).toEqual(safeguardFailure); expect(result.claudeModelObservationPending).toBeUndefined();
      expect(result.text).toBeUndefined(); expect(pause.retry.clicks + pause.fallback.clicks).toBe(0); x.noActions();
    }
  });

  test('Claude safeguard pause does not override ownership loss observed during the same wait', async () => {
    const x = await pendingDetached(), pause = observedClaudePause(x.f);
    x.f.world.__computaModelOwner = 'foreign'; x.wake(); x.expire();
    const result = await x.pending;
    expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(pause.retry.clicks + pause.fallback.clicks).toBe(0); x.noActions();
  });

  test('Claude safeguard pause arriving at the final model-proof await withdraws completion', async () => {
    const x = await detached(), replacement = currentHeader();
    let tracked = false, trackedValue: any, pause: ReturnType<typeof observedClaudePause>;
    Object.defineProperty(x.f.world, '__computaModelReadUI', { configurable: true,
      get: () => trackedValue, set: value => {
        trackedValue = value;
        if (tracked) return;
        tracked = true; queueMicrotask(() => { pause = observedClaudePause(x.f); });
      } });
    x.f.body.append(replacement); x.wake();
    const result = await x.pending;
    expect(tracked).toBe(true); expect(result).toEqual(safeguardFailure);
    expect(result.text).toBeUndefined(); expect(result.answerComplete).toBeUndefined();
    expect(pause!.retry.clicks + pause!.fallback.clicks).toBe(0); x.noActions();
  });

  test('Claude no-output pending expires only the existing read and later requires a fresh exact header', async () => {
    for (const busy of [false, true]) {
      const x = await pendingDetached(); x.f.stop.connected = busy;
      x.expire(); const result = await x.pending;
      expect(Object.keys(result).sort()).toEqual(['answerComplete', 'busy', 'claudeModelObservationPending', 'conversationIdentity',
        'firstUserFingerprint', 'firstUserIdentity', 'firstUserMarkerVerified', 'firstUserVerified', 'interrupted',
        'responseCount', 'temporary', 'text', 'url', 'userCount']);
      expect(result).toEqual({ claudeModelObservationPending: true, url: x.f.document.URL, temporary: true,
        conversationIdentity: null, userCount: 1, firstUserIdentity: x.before.firstUserIdentity,
        firstUserFingerprint: x.before.firstUserFingerprint, firstUserVerified: true, firstUserMarkerVerified: true,
        responseCount: 0, text: '', answerComplete: false, busy, interrupted: false });
      expect(x.f.world.__computaModelFirstProof.fingerprint).toBe(x.before.firstUserFingerprint);
      x.noActions();
      const replacement = currentHeader(); x.f.body.append(replacement);
      x.f.stop.connected = false; x.f.answer.connected = true; x.f.response.append(x.f.answer); x.f.controls.connected = true;
      const completed = await x.f.run('inspect', { expectedModelChoice, allowClaudeModelObservationPending: true });
      expect(completed).toMatchObject({ answerComplete: true, text: '{"type":"message","text":"OK"}',
        firstUserFingerprint: x.before.firstUserFingerprint, modelEvidence: { selected: expectedModelChoice } });
      expect(completed.claudeModelObservationPending).toBeUndefined(); expect(replacement.clicks).toBe(0); x.noActions();
    }
  });

  test('Claude no-output pending requires strict permission, existing native binding and exact expected count', async () => {
    for (const overrides of [{ allowClaudeModelObservationPending: undefined }, { allowClaudeModelObservationPending: false },
      { allowClaudeModelObservationPending: 'true' }, { allowClaudeModelObservationPending: 1 },
      { allowFirstUserBinding: true }, { allowFirstUserBinding: true, expectedFirstUserFingerprint: null },
      { expectedUserCounts: [0, 1] }]) {
      const x = await pendingDetached(overrides); x.expire(); const result = await x.pending;
      expect(result.error).toBe('model_unverified'); expect(result.claudeModelObservationPending).toBeUndefined();
      expect(result.modelDiagnostic.readStage).toBe('trigger_remount_timeout'); x.noActions();
    }
    const x = await detached('verifyModel', emptyShell, { allowClaudeModelObservationPending: true }, false);
    x.expire(); const result = await x.pending;
    expect(result.error).toBe('model_unverified'); expect(result.claudeModelObservationPending).toBeUndefined(); x.noActions();
  });

  test('Claude no-output pending never masks reply markup, alternative text, interrupted or blocked pages', async () => {
    for (const mode of ['reply', 'hidden_reply', 'empty_reply_markup', 'alternative', 'deep', 'duplicate_root', 'interrupted', 'sign_in', 'quota', 'dialog']) {
      const x = await pendingDetached();
      if (['reply', 'hidden_reply', 'empty_reply_markup'].includes(mode)) {
        x.f.response.append(x.f.answer);
        if (mode === 'hidden_reply') x.f.answer.values.hidden = '';
        if (mode === 'empty_reply_markup') x.f.answer.text = '';
      }
      if (mode === 'alternative') x.f.response.append(new Element('SECTION', {}, 'Alternative authored reply'));
      if (mode === 'deep') {
        let node = x.f.response;
        for (let index = 0; index < 70; index++) { const child = new Element('DIV'); node.append(child); node = child; }
      }
      if (mode === 'duplicate_root') x.f.messages.append(new Element('DIV', { 'data-testid': 'assistant-message' }));
      if (mode === 'interrupted') x.f.status.text = "Claude's response was interrupted.";
      if (mode === 'sign_in') x.f.body.append(new Element('BUTTON', {}, 'Sign in'));
      if (mode === 'quota') observedClaudeBanner(x.f);
      if (mode === 'dialog') x.f.body.append(new Element('DIV', { role: 'dialog' }));
      x.wake(); x.expire(); const result = await x.pending;
      expect(result.error).toBe(mode === 'quota' ? 'website_usage_limit' : 'model_unverified');
      expect(result.claudeModelObservationPending).toBeUndefined(); expect(result.text).toBeUndefined();
      expect(result.modelEvidence).toBeUndefined(); x.noActions();
    }
  });

  test('Claude no-output pending never converts clock rejection or restored wrong model into waiting', async () => {
    for (const mode of ['clock', 'wrong_model', 'unknown_model', 'hidden_old_header']) {
      const x = await pendingDetached();
      if (mode === 'clock') x.rejectClock();
      if (mode === 'wrong_model') { x.f.body.append(currentHeader('Sonnet 5')); x.wake(); }
      if (mode === 'unknown_model') { x.f.body.append(currentHeader('Unknown 5')); x.wake(); }
      if (mode === 'hidden_old_header') { x.picker.trigger.connected = true; x.picker.trigger.values.hidden = ''; x.expire(); }
      const result = await x.pending;
      expect(result.error).toBe(mode === 'wrong_model' ? 'model_mismatch' : 'model_unverified');
      expect(result.claudeModelObservationPending).toBeUndefined(); expect(result.text).toBeUndefined(); x.noActions();
    }
  });

  test('Claude no-output pending cannot unlatch observed rejection when the original context returns', async () => {
    for (const mode of ['owner', 'body', 'model', 'popup']) {
      const x = await pendingDetached(), owner = x.f.world.__computaModelOwner, body = x.f.userBody!.text;
      const wrong = currentHeader('Sonnet 5'), popup = new Element('DIV', { role: 'dialog' });
      if (mode === 'owner') x.f.world.__computaModelOwner = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
      if (mode === 'body') x.f.userBody!.text += ' foreign';
      if (mode === 'model') x.f.body.append(wrong);
      if (mode === 'popup') x.f.body.append(popup);
      x.wake();
      x.f.world.__computaModelOwner = owner; x.f.userBody!.text = body;
      wrong.connected = false; popup.connected = false;
      const result = await x.pending;
      expect(result.error).toBe(mode === 'model' ? 'model_mismatch' : 'model_unverified');
      expect(result.claudeModelObservationPending).toBeUndefined(); expect(result.text).toBeUndefined(); x.noActions();
    }
  });

  test('Claude no-output pending latches transient semantic or traversal loss on delivered observations', async () => {
    for (const mode of ['quota', 'sign_in', 'interrupted', 'reply', 'hidden_reply', 'empty_reply_markup',
      'alternative', 'deep', 'unreadable']) {
      const x = await pendingDetached();
      let restore: () => void = () => {};
      if (mode === 'quota') {
        const banner = observedClaudeBanner(x.f); restore = () => { banner.container.connected = false; };
      } else if (mode === 'sign_in') {
        const signIn = new Element('BUTTON', {}, 'Sign in'); x.f.body.append(signIn);
        restore = () => { signIn.connected = false; };
      } else if (mode === 'interrupted') {
        const text = x.f.status.text; x.f.status.text = "Claude's response was interrupted.";
        restore = () => { x.f.status.text = text; };
      } else if (['reply', 'hidden_reply', 'empty_reply_markup'].includes(mode)) {
        x.f.answer.connected = true; x.f.response.append(x.f.answer);
        if (mode === 'hidden_reply') x.f.answer.values.hidden = '';
        if (mode === 'empty_reply_markup') x.f.answer.text = '';
        restore = () => { x.f.response.replaceChildren(new Element('DIV')); };
      } else if (mode === 'alternative') {
        x.f.response.append(new Element('SECTION', {}, 'Alternative authored reply'));
        restore = () => { x.f.response.replaceChildren(new Element('DIV')); };
      } else if (mode === 'deep') {
        let node = x.f.response;
        for (let index = 0; index < 70; index++) { const child = new Element('DIV'); node.append(child); node = child; }
        restore = () => { x.f.response.replaceChildren(new Element('DIV')); };
      } else {
        Object.defineProperty(x.f.response, 'childNodes', { configurable: true,
          get: () => { throw new Error('synthetic unreadable traversal'); } });
        restore = () => { delete (x.f.response as any).childNodes; };
      }
      x.wake(); // Deliver the failure while it exists, then remove its surface.
      restore(); x.wake(); x.expire();
      const result = await x.pending;
      expect(result.error).toBe('model_unverified');
      expect(result.claudeModelObservationPending).toBeUndefined();
      expect(result.text).toBeUndefined(); expect(result.modelEvidence).toBeUndefined(); x.noActions();
    }
  });

  test('Claude losing no-output eligibility does not reject a normally restored exact header and reply', async () => {
    const x = await pendingDetached();
    x.f.answer.connected = true; x.f.response.append(x.f.answer); x.f.controls.connected = true;
    x.wake(); // A normal response revokes absence, not future positive proof.
    const replacement = currentHeader(); x.f.body.append(replacement); x.wake();
    const result = await x.pending;
    expect(result).toMatchObject({ answerComplete: true, text: '{"type":"message","text":"OK"}',
      firstUserFingerprint: x.before.firstUserFingerprint, modelEvidence: { selected: expectedModelChoice } });
    expect(result.claudeModelObservationPending).toBeUndefined();
    expect(replacement.clicks).toBe(0); x.noActions();
  });

  test('Claude no-output pending retains first-body, count, owner and mode rejection', async () => {
    for (const mode of ['body', 'marker', 'owner', 'url', 'count', 'mode']) {
      const x = await pendingDetached();
      if (mode === 'body') x.f.userBody!.text = 'Changed ' + x.f.userBody!.text;
      if (mode === 'marker') x.f.world.__computaModelFirstMarker = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
      if (mode === 'owner') x.f.world.__computaModelOwner = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
      if (mode === 'url') x.f.document.URL += '&foreign=true';
      if (mode === 'count') x.f.appendUser('Foreign added message');
      if (mode === 'mode') x.f.temporary(false);
      x.wake(); const result = await x.pending;
      expect(result.claudeModelObservationPending).toBeUndefined(); expect(result.error).toBe(mode === 'marker' ? 'model_unverified' : 'conversation_changed');
      expect(result.text).toBeUndefined(); x.noActions();
    }
  });

  test('Claude no-output pending cannot be used by editor, Send, selection or cleanup actions', async () => {
    for (const action of ['prepare', 'insert', 'sendReady', 'submit', 'selectModel', 'discoverModels', 'stop']) {
      const f = fixture('claude', { userPrompt: 'Bounded action control', response: false });
      const picker = installObservedModelPicker(f, 'claude', Element); picker.selected('Opus 5');
      const before = await f.run('inspect', { expectedModelChoice }); expect(before.firstUserVerified).toBe(true);
      emptyShell(f); picker.trigger.connected = false;
      const result = await f.run(action, { expectedModelChoice, allowClaudeModelObservationPending: true, prompt: 'Unsent' });
      expect(result.claudeModelObservationPending).toBeUndefined(); expect(result.answerComplete).not.toBe(true);
      expect(f.send.clicks).toBe(0); expect(picker.trigger.clicks).toBe(0); expect(f.composer.events).toHaveLength(0);
    }
  });

  test('remount diagnostics distinguish streaming, complete and absent answer without admitting any of them', async () => {
    for (const shape of ['streaming', 'complete', 'absent']) {
      const x = await detached('inspect', f => {
        f.answer.text = 'PRIVATE_REPLY_CANARY';
        if (shape === 'streaming') { f.stop.connected = true; f.response.values['data-is-streaming'] = 'true'; }
        if (shape === 'absent') f.answer.connected = false;
      });
      x.expire(); const result = await x.pending;
      expect(result.error).toBe('model_unverified'); expect(result.text).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
      const d = result.modelDiagnostic.remountObservation;
      expect(Object.keys(d).sort()).toEqual(['elapsedMs', 'entry', 'kind', 'observations', 'surface', 'terminal']);
      expect(d.kind).toBe('claude_remount_observation_v1');
      expect(d.elapsedMs).toBeGreaterThanOrEqual(0); expect(d.elapsedMs).toBeLessThanOrEqual(10000);
      expect(d.observations).toBeGreaterThanOrEqual(2); expect(d.observations).toBeLessThanOrEqual(1000);
      expect(d.entry).toEqual(d.terminal);
      expect(Object.keys(d.entry).sort()).toEqual(['answerComplete', 'busy', 'enabledCopies', 'interrupted', 'logicalAnswerCount', 'messageStreamingState', 'scopedCopies']);
      expect(d.entry).toEqual({ logicalAnswerCount: shape === 'absent' ? 0 : 1,
        busy: shape === 'streaming', interrupted: false, messageStreamingState: shape === 'absent' ? 'no_message' : shape === 'streaming' ? 'true' : 'false',
        scopedCopies: shape === 'absent' ? 0 : 1, enabledCopies: shape === 'absent' ? 0 : 1,
        answerComplete: shape === 'complete' });
      expect(JSON.stringify(d)).not.toContain('PRIVATE_REPLY_CANARY');
      expect(JSON.stringify(d).length).toBeLessThan(6000); x.noActions();
    }
  });

  test('remount surface distinguishes missing, hidden and inert rendered reply subtrees', async () => {
    for (const mode of ['missing', 'hidden_body', 'hidden_root', 'inert_root']) {
      const x = await detached('inspect', f => {
        if (mode === 'missing') f.response.replaceChildren(new Element('H2', {}, 'PRIVATE_HEADER'));
        if (mode === 'hidden_body') f.answer.values.hidden = '';
        if (mode === 'hidden_root') f.response.values.hidden = '';
        if (mode === 'inert_root') f.response.values.inert = '';
      });
      x.expire(); const result = await x.pending, d = result.modelDiagnostic.remountObservation.surface;
      expect(result.error).toBe('model_unverified'); expect(result.modelDiagnostic.readStage).toBe('trigger_remount_timeout');
      expect(result.text).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
      expect(d.kind).toBe('claude_remount_surface_v1');
      expect(d.responseRoots).toMatchObject({ sampled: 1, truncated: false, shapesTruncated: false,
        physical: mode === 'hidden_root' ? 0 : 1, visible: ['hidden_root', 'inert_root'].includes(mode) ? 0 : 1 });
      expect(d.renderedReplies).toEqual({ sampled: mode === 'missing' ? 0 : 1, truncated: false,
        physical: mode === 'inert_root' ? 1 : 0, visible: 0, enabled: 0 });
      expect(d.replyTextNodes).toEqual(d.renderedReplies);
      expect(d.responseRoots.shapes[0].children.some((child: any) => child.replyText)).toBe(mode !== 'missing');
      expect(JSON.stringify(d)).not.toContain('PRIVATE_HEADER'); x.noActions();
    }
  });

  test('remount surface records alternate direct children and only finite control categories', async () => {
    const x = await detached('verifyModel', f => {
      f.response.replaceChildren(new Element('SECTION', { role: 'region', class: 'PRIVATE_CLASS' }, 'PRIVATE_REPLY'),
        new Element('PRIVATE-TAG', { role: 'PRIVATE_ROLE', 'data-testid': 'PRIVATE_TESTID', 'data-perf-reply-text': 'PRIVATE_ATTRIBUTE' }));
      f.body.append(new Element('BUTTON', { 'aria-label': 'Model: PRIVATE_MODEL', hidden: '' }),
        new Element('BUTTON', { 'aria-label': 'PRIVATE_CONTROL' }),
        new Element('BUTTON', { 'aria-label': 'Model: Opus 5 High', hidden: '' }));
      f.composer.disabled = true;
      f.send.values['aria-disabled'] = 'true'; delete f.send.values['data-testid']; f.stop.connected = true;
      Object.assign(f.document, { hidden: true, visibilityState: 'hidden', readyState: 'complete' });
      Object.assign(f.window, { innerWidth: 1024, innerHeight: 768, scrollX: -4.5, scrollY: 12.9 });
    });
    x.expire(); const result = await x.pending, d = result.modelDiagnostic.remountObservation.surface;
    expect(result.error).toBe('model_unverified'); expect(result.text).toBeUndefined();
    expect(d.responseRoots.shapes[0].children).toEqual([
      { tag: 'section', role: 'region', testID: 'absent', replyText: false, physical: true, visible: true,
        textNodes: { utf16Units: 13, saturated: false, nodesVisited: 1, truncated: false } },
      { tag: 'other', role: 'other', testID: 'other', replyText: true, physical: true, visible: true,
        textNodes: { utf16Units: 0, saturated: false, nodesVisited: 0, truncated: false } }]);
    expect(d.modelControls.prefix).toMatchObject({ sampled: 3, truncated: false, physical: 0, visible: 0, enabled: 0 });
    expect(d.modelControls.labelKinds).toMatchObject({ recognized: 2, known_prefix_unrecognized: 1 });
    expect(d.composers).toEqual({ sampled: 1, truncated: false, physical: 1, visible: 1, enabled: 0 });
    expect(d.sendButtons.enabled).toBe(0); expect(d.stopButtons.enabled).toBe(1);
    expect(d.document).toEqual({ hidden: true, visibility: 'hidden', ready: 'complete',
      width: { value: 1024, saturated: false }, height: { value: 768, saturated: false },
      scrollX: { value: -4, saturated: false }, scrollY: { value: 12, saturated: false } });
    expect(JSON.stringify(d)).not.toContain('PRIVATE_'); x.noActions();
  });

  test('remount surface distinguishes empty placeholders from alternate text without reading text content', async () => {
    for (const mode of ['empty', 'nonempty', 'long', 'deep']) {
      const x = await detached('inspect', f => {
        f.response.replaceChildren();
        const child = new Element('SECTION'); f.response.append(child);
        let leaf = child;
        if (mode === 'deep') for (let index = 0; index < 80; index++) {
          const next = new Element('DIV'); leaf.append(next); leaf = next;
        }
        if (mode !== 'empty') {
          const text = new Element('#text', {}, mode === 'long' ? 'PRIVATE_TEXT_'.repeat(20000) : 'PRIVATE_TEXT_😀');
          // Diagnostic must use CharacterData.length, never textContent/innerText.
          Object.defineProperty(text, 'textContent', { get: () => { throw new Error('RAW_TEXT_READ'); } });
          leaf.append(text);
        }
      });
      x.expire(); const result = await x.pending, d = result.modelDiagnostic.remountObservation.surface;
      expect(result.error).toBe('model_unverified'); expect(result.text).toBeUndefined();
      const root = d.responseRoots.shapes[0], child = root.children[0];
      for (const shape of [root, child]) {
        expect(shape.textNodes).toMatchObject({ utf16Units: mode === 'long' ? 180201 : mode === 'nonempty' ? 15 : 0,
          saturated: mode === 'long', truncated: mode === 'deep' });
        expect(shape.textNodes.nodesVisited).toBeLessThanOrEqual(64);
      }
      expect(d.renderedReplies.sampled).toBe(0);
      expect(JSON.stringify(d)).not.toContain('PRIVATE_TEXT'); expect(JSON.stringify(d)).not.toContain('RAW_TEXT_READ'); x.noActions();
    }
  });

  test('remount surface is a failure-time reread and can describe a rejected replacement', async () => {
    const x = await detached();
    x.f.response.replaceChildren(new Element('DIV', { 'data-testid': 'message-actions' }));
    x.f.body.append(currentHeader('Sonnet 5')); x.wake();
    const result = await x.pending, d = result.modelDiagnostic.remountObservation.surface;
    expect(result.error).toBe('model_mismatch'); expect(result.modelDiagnostic.readStage).toBe('trigger_remount_rejected');
    expect(result.modelDiagnostic.remountObservation.entry.logicalAnswerCount).toBe(1);
    expect(d.renderedReplies.sampled).toBe(0); expect(d.modelControls.prefix.visible).toBe(1);
    expect(d.responseRoots.shapes[0].children[0].testID).toBe('message-actions');
    expect(result.text).toBeUndefined(); expect(result.modelEvidence).toBeUndefined(); x.noActions();
  });

  test('remount surface exceptions preserve the original error, clock and no actions', async () => {
    const x = await detached();
    Object.defineProperty(x.f.document, 'hidden', { get: () => { throw new Error('PRIVATE_DIAGNOSTIC_FAILURE'); } });
    x.expire(); const result = await x.pending;
    expect(result.error).toBe('model_unverified'); expect(result.modelDiagnostic.readStage).toBe('trigger_remount_timeout');
    expect(result.modelDiagnostic.remountObservation.surface).toBeNull();
    expect(result.modelDiagnostic.remountObservation.terminal.answerComplete).toBe(true);
    expect(JSON.stringify(result)).not.toContain('PRIVATE_DIAGNOSTIC_FAILURE'); x.noActions();
  });

  test('remount surface discards the inventory if ownership changes during the projection', async () => {
    const x = await detached();
    Object.defineProperty(x.f.document, 'hidden', { get: () => {
      x.f.world.__computaModelOwner = 'PRIVATE_FOREIGN_OWNER'; return false;
    } });
    x.expire(); const result = await x.pending;
    expect(result.error).toBe('conversation_changed'); expect(result.detail).toBe('first_user_message');
    expect(result.text).toBeUndefined(); expect(result.modelEvidence).toBeUndefined(); x.noActions();
  });

  test('remount surface caps every inventory and shape and fits the existing native diagnostic budget', async () => {
    const x = await detached('inspect', f => {
      f.response.replaceChildren();
      for (let root = 0; root < 70; root++) {
        const node = root === 0 ? f.response : new Element('DIV', { 'data-testid': 'assistant-message' });
        for (let child = 0; child < 10; child++) node.append(new Element('SECTION', {
          role: 'presentation', 'data-testid': 'response-status-announcer', 'data-perf-reply-text': 'PRIVATE_VALUE', class: 'PRIVATE_CLASS' }));
        if (root !== 0) f.messages.append(node);
        f.body.append(new Element('BUTTON', { 'aria-label': 'Model: PRIVATE_' + root, hidden: '' }),
          new Element('DIV', { 'data-testid': 'chat-input', contenteditable: 'true', role: 'textbox', hidden: '' }),
          new Element('BUTTON', { 'aria-label': 'Send message', 'data-testid': 'chat-input-send', hidden: '' }),
          new Element('BUTTON', { 'aria-label': 'Stop response', hidden: '' }));
      }
      Object.assign(f.document, { hidden: false, visibilityState: 'PRIVATE_VISIBILITY', readyState: 'PRIVATE_READY' });
      Object.assign(f.window, { innerWidth: Infinity, innerHeight: 900000, scrollX: -900000, scrollY: NaN });
    });
    x.expire(); const result = await x.pending, d = result.modelDiagnostic.remountObservation.surface;
    expect(result.error).toBe('model_unverified'); expect(result.text).toBeUndefined();
    for (const sample of [d.composers, d.stopButtons, d.sendButtons, d.responseRoots, d.renderedReplies, d.replyTextNodes, d.modelControls.labeledScan])
      expect(sample).toMatchObject({ sampled: 64, truncated: true });
    expect(d.modelControls.prefix.truncated).toBe(true);
    expect(d.responseRoots.shapesTruncated).toBe(true); expect(d.responseRoots.shapes).toHaveLength(2);
    for (const root of d.responseRoots.shapes) { expect(root.childrenTruncated).toBe(true); expect(root.children).toHaveLength(6); }
    expect(d.document).toMatchObject({ visibility: 'other', ready: 'other',
      width: { value: null, saturated: false }, height: { value: 100000, saturated: true },
      scrollX: { value: -100000, saturated: true }, scrollY: { value: null, saturated: false } });
    expect(JSON.stringify(d)).not.toContain('PRIVATE_');
    expect(new TextEncoder().encode(JSON.stringify(d)).length).toBeLessThan(6000);
    expect(new TextEncoder().encode(JSON.stringify(result.modelDiagnostic)).length).toBeLessThan(16384);
    x.noActions();
  });

  test('remount diagnostics preserve entry separately from the later completion reread', async () => {
    const x = await detached('inspect', f => { f.stop.connected = true; f.response.values['data-is-streaming'] = 'true'; });
    x.f.stop.connected = false; x.f.response.values['data-is-streaming'] = 'false'; x.wake();
    x.expire(); const result = await x.pending;
    expect(result.error).toBe('model_unverified'); expect(result.text).toBeUndefined();
    expect(result.modelDiagnostic.remountObservation.entry).toMatchObject({ busy: true, answerComplete: false, messageStreamingState: 'true' });
    expect(result.modelDiagnostic.remountObservation.terminal).toMatchObject({ busy: false, answerComplete: true, messageStreamingState: 'false' });
    x.noActions();
  });

  test('remount diagnostic exceptions become unknown while the original timeout and actions are preserved', async () => {
    for (const phase of ['entry', 'terminal']) {
      const failRead = (f: ReturnType<typeof fixture>) => {
        const original = f.response.getAttribute.bind(f.response);
        f.response.getAttribute = name => { if (name === 'data-is-streaming') throw new Error('PRIVATE_DIAGNOSTIC_CANARY'); return original(name); };
      };
      const x = await detached('inspect', phase === 'entry' ? failRead : undefined);
      if (phase === 'terminal') failRead(x.f);
      x.expire(); const result = await x.pending;
      expect(result.error).toBe('model_unverified'); expect(result.modelDiagnostic.readStage).toBe('trigger_remount_timeout');
      expect(result.text).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
      const d = result.modelDiagnostic.remountObservation;
      expect(d.terminal).toBeNull();
      if (phase === 'entry') expect(d.entry).toBeNull(); else expect(d.entry.answerComplete).toBe(true);
      expect(JSON.stringify(d)).not.toContain('PRIVATE_DIAGNOSTIC_CANARY'); x.noActions();
    }
  });

  test('remount diagnostics do not inspect completion after the original owned context is lost', async () => {
    let reads = 0;
    const x = await detached('inspect', f => {
      const original = f.response.getAttribute.bind(f.response);
      f.response.getAttribute = name => { if (name === 'data-is-streaming') reads++; return original(name); };
    });
    const entryReads = reads; expect(entryReads).toBeGreaterThan(0);
    x.f.world.__computaModelOwner = 'PRIVATE_FOREIGN_OWNER'; x.wake();
    const result = await x.pending;
    expect(result.error).toBe('conversation_changed'); expect(result.detail).toBe('first_user_message');
    expect(reads).toBe(entryReads); expect(result.text).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
    x.noActions();
  });

  test('remount diagnostic elapsed time is bounded without extending the original clock', async () => {
    const x = await detached(); const originalNow = Date.now, future = originalNow() + 30000;
    try {
      Date.now = () => future;
      x.expire(); const result = await x.pending;
      expect(result.error).toBe('model_unverified'); expect(result.modelDiagnostic.readStage).toBe('trigger_remount_timeout');
      expect(result.modelDiagnostic.remountObservation.elapsedMs).toBe(10000);
      expect(result.text).toBeUndefined(); x.noActions();
    } finally { Date.now = originalNow; }
  });

  test('remount diagnostic enums and counters stay finite without copying page attributes', async () => {
    const x = await detached('verifyModel', f => { f.response.values['data-is-streaming'] = 'PRIVATE_ATTRIBUTE_CANARY'; });
    for (let i = 0; i < 1005; i++) x.wake();
    x.expire(); const result = await x.pending;
    expect(result.error).toBe('model_unverified'); expect(result.modelDiagnostic.remountObservation.observations).toBe(1000);
    expect(result.modelDiagnostic.remountObservation.entry.messageStreamingState).toBe('other');
    expect(result.modelDiagnostic.remountObservation.terminal.messageStreamingState).toBe('other');
    expect(JSON.stringify(result.modelDiagnostic.remountObservation)).not.toContain('PRIVATE_ATTRIBUTE_CANARY');
    expect(result.text).toBeUndefined(); x.noActions();
  });

  test('a new exact current header after Send supplies fresh proof without any picker or editor action', async () => {
    for (const action of ['inspect', 'verifyModel']) {
      const x = await detached(action), replacement = currentHeader(); x.f.body.append(replacement); x.wake();
      const result = await x.pending;
      expect(result).toMatchObject({ firstUserVerified: true, firstUserFingerprint: x.before.firstUserFingerprint,
        modelEvidence: { selected: expectedModelChoice, verification: 'website_selection', source: 'model_picker_label' } });
      if (action === 'inspect') expect(result).toMatchObject({ answerComplete: true, text: '{"type":"message","text":"OK"}' });
      expect(result.modelDiagnostic?.remountObservation).toBeUndefined();
      expect(x.f.world.__computaClaudeLastModelTrigger.node).toBe(replacement);
      expect(replacement.clicks).toBe(0); x.noActions();
      x.expire(); await Bun.sleep(0); x.noActions();
    }
  });

  test('the old diagnostic node is never promoted and a missing replacement or rejected clock fails closed', async () => {
    for (const kind of ['deadline', 'clock_rejected', 'header_after_deadline']) {
      const x = await detached();
      // Even a still-recognized old label cannot qualify a detached node.
      expect(x.f.world.__computaClaudeLastModelTrigger.node.getAttribute('aria-label')).toContain('Opus 5');
      if (kind === 'clock_rejected') x.rejectClock(); else x.expire();
      if (kind === 'header_after_deadline') { await Promise.resolve(); await Promise.resolve(); x.f.body.append(currentHeader()); x.wake(); }
      const result = await x.pending;
      expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
      expect(result.modelDiagnostic.lastModelTrigger).toMatchObject({ connected: false, physical: false, visible: false });
      x.noActions();
    }
  });

  test('mismatch, unknown, disabled, ambiguous or open replacement controls never become model proof', async () => {
    for (const kind of ['mismatch', 'unknown', 'disabled', 'duplicate', 'expanded']) {
      const x = await detached(), replacement = currentHeader(kind === 'mismatch' ? 'Haiku 5.5' : 'Opus 5');
      if (kind === 'unknown') replacement.values['aria-label'] = 'Model: unrecognized model';
      if (kind === 'disabled') replacement.disabled = true;
      if (kind === 'expanded') replacement.values['aria-expanded'] = 'true';
      x.f.body.append(replacement); if (kind === 'duplicate') x.f.body.append(currentHeader()); x.wake();
      const result = await x.pending;
      expect(result.error).toBe(kind === 'mismatch' ? 'model_mismatch' : 'model_unverified');
      expect(result.modelEvidence).toBeUndefined(); expect(replacement.clicks).toBe(0); x.noActions();
    }
  });

  test('owner, route, first-user and foreign-popup negatives stay latched even if restored before the await resumes', async () => {
    for (const kind of ['owner', 'route', 'frame', 'first_text', 'first_identity', 'first_count', 'submitted', 'first_marker', 'first_proof', 'temporary', 'foreign_menu', 'foreign_dialog', 'mismatch']) {
      const x = await detached(), originalOwner = x.f.world.__computaModelOwner, originalURL = x.f.document.URL;
      const originalText = x.f.userBody!.text, wrapper = x.f.userRoot!.parentElement!, originalID = wrapper.values.id;
      const originalMessages = [...x.f.messages.children], originalTop = x.f.window.top;
      const originalProof = x.f.world.__computaModelFirstProof, originalMarker = x.f.world.__computaModelFirstMarker;
      const foreign = new Element('DIV', { role: kind === 'foreign_dialog' ? 'dialog' : 'menu' });
      const wrong = currentHeader('Haiku 5.5');
      if (kind === 'owner') x.f.world.__computaModelOwner = '00000000-0000-4000-8000-000000000009';
      if (kind === 'route') x.f.document.URL = x.f.origin + '/chat/foreign?incognito';
      if (kind === 'frame') x.f.window.top = {};
      if (kind === 'submitted') x.f.world.__computaModelFirstSubmitted = false;
      if (kind === 'first_marker') x.f.world.__computaModelFirstMarker = '00000000-0000-4000-8000-000000000009';
      if (kind === 'first_proof') x.f.world.__computaModelFirstProof = { ...originalProof };
      if (kind === 'first_text') x.f.userBody!.text += ' changed';
      if (kind === 'first_identity') wrapper.values.id = 'foreign-first-message';
      if (kind === 'first_count') x.f.messages.append(new Element('DIV', { 'data-testid': 'user-message' }, 'foreign'));
      if (kind === 'temporary') x.f.badge.connected = false;
      if (kind.startsWith('foreign_')) x.f.body.append(foreign);
      if (kind === 'mismatch') x.f.body.append(wrong);
      x.wake();
      x.f.world.__computaModelOwner = originalOwner; x.f.document.URL = originalURL; x.f.window.top = originalTop;
      x.f.world.__computaModelFirstSubmitted = true; x.f.world.__computaModelFirstMarker = originalMarker;
      x.f.world.__computaModelFirstProof = originalProof;
      x.f.userBody!.text = originalText; wrapper.values.id = originalID; x.f.badge.connected = true;
      if (kind === 'first_count') x.f.messages.children = originalMessages;
      foreign.connected = false; wrong.connected = false;
      x.f.body.append(currentHeader()); x.wake();
      const result = await x.pending;
      expect(result.error).toBe(kind === 'mismatch' ? 'model_mismatch' : 'model_unverified');
      expect(result.modelEvidence).toBeUndefined(); x.noActions();
    }
  });

  test('a replacement losing proof before the ordinary loop cannot open a picker', async () => {
    const x = await detached(), replacement = currentHeader();
    let reads = 0;
    const get = replacement.getAttribute.bind(replacement);
    // The observer sees exact evidence; its last closed-state read invalidates
    // the label before the independent ordinary read, without a DOM action.
    replacement.getAttribute = (name: string) => {
      const result = get(name);
      if (name === 'data-state' && ++reads === 1) replacement.values['aria-label'] = 'Model: unknown';
      return result;
    };
    x.f.body.append(replacement); x.wake();
    const result = await x.pending;
    expect(result.error).toBe('model_unverified'); expect(replacement.clicks).toBe(0); x.noActions();
  });

  test('final close await rechecks exact replacement, current proof and the original deadline', async () => {
    for (const kind of ['detached', 'replaced', 'unknown', 'mismatch', 'disabled', 'menu', 'scan_limit', 'deadline']) {
      const x = await detached(), replacement = currentHeader();
      let tracked = false, mutated = false, trackedValue: any;
      const realNow = Date.now;
      Object.defineProperty(x.f.world, '__computaModelReadUI', { configurable: true,
        get: () => trackedValue, set: value => {
          trackedValue = value;
          if (tracked) return;
          tracked = true;
          // Tracking happens in the ordinary fresh loop, immediately before
          // closeOwned. A microtask runs only when its await actually yields.
          queueMicrotask(() => {
            mutated = true;
            if (kind === 'detached') replacement.connected = false;
            if (kind === 'replaced') { replacement.connected = false; x.f.body.append(currentHeader()); }
            if (kind === 'unknown') replacement.values['aria-label'] = 'Model: unknown';
            if (kind === 'mismatch') { replacement.values['aria-label'] = 'Model: Haiku 5.5 High'; replacement.children[0].text = 'Haiku 5.5'; }
            if (kind === 'disabled') replacement.disabled = true;
            if (kind === 'menu') {
              replacement.values['aria-controls'] = 'late-owned-popup'; replacement.values['aria-expanded'] = 'true';
              x.f.body.append(new Element('DIV', { role: 'menu', id: 'late-owned-popup' }));
            }
            if (kind === 'scan_limit') for (let i=0;i<256;i++) x.f.body.append(new Element('BUTTON', {'aria-label':'Unrelated control'}));
            if (kind === 'deadline') Date.now = () => realNow() + 10_000;
          });
        } });
      try {
        x.f.body.append(replacement); x.wake();
        const result = await x.pending;
        expect(tracked).toBe(true); expect(mutated).toBe(true);
        expect(result.error).toBe(kind === 'mismatch' ? 'model_mismatch' : 'model_unverified');
        expect(result.text).toBeUndefined(); expect(replacement.clicks).toBe(0); x.noActions();
        expect(x.f.body.querySelector('[id="late-owned-popup"]')?.events ?? []).toHaveLength(0);
      } finally { Date.now = realNow; }
    }
  });

  test('a saturated trigger scan cannot start or continue the detached-header wait', async () => {
    const fillScan = (f: any) => {
      const noise = new Element('DIV');
      for (let i=0;i<256;i++) noise.append(new Element('BUTTON', {'aria-label':'Unrelated control'}));
      noise.parentElement = f.body; f.body.children.unshift(noise);
    };
    const f = fixture('claude', {userPrompt:'Saturated scan control'}), picker = installObservedModelPicker(f, 'claude', Element);
    picker.selected('Opus 5'); expect((await f.run('inspect', {expectedModelChoice})).error).toBeUndefined();
    picker.trigger.connected = false; fillScan(f);
    const before = await f.run('inspect', {expectedModelChoice});
    expect(before.error).toBe('model_unverified'); expect(before.modelEvidence).toBeUndefined();
    expect(before.modelDiagnostic.readStage).toBe('initial_observation');
    expect(before.modelDiagnostic.lastModelTrigger.triggerScanAtLimit).toBe(true);
    expect(f.delays).toHaveLength(0); expect(f.send.clicks).toBe(0); expect(picker.trigger.clicks).toBe(0);
    const x = await detached(); fillScan(x.f); x.wake();
    const during = await x.pending;
    expect(during.error).toBe('model_unverified'); expect(during.modelEvidence).toBeUndefined();
    expect(during.modelDiagnostic.readStage).toBe('trigger_remount_rejected');
    expect(during.modelDiagnostic.lastModelTrigger.triggerScanAtLimit).toBe(true); x.noActions();
  });

  test('missing, malformed, foreign or unreadable remembered records cannot acquire waiting privilege', async () => {
    for (const allowClaudeModelObservationPending of [false, true]) for (const kind of ['missing', 'primitive', 'extra_key', 'node_missing', 'node_forged', 'owner', 'document', 'url', 'node_getter', 'record_getter']) {
      const f = fixture('claude', { userPrompt: 'Record scope control' }), picker = installObservedModelPicker(f, 'claude', Element);
      picker.selected('Opus 5'); expect((await f.run('inspect', { expectedModelChoice })).error).toBeUndefined();
      if (allowClaudeModelObservationPending) emptyShell(f);
      picker.trigger.connected = false;
      const record = f.world.__computaClaudeLastModelTrigger;
      if (kind === 'missing') delete f.world.__computaClaudeLastModelTrigger;
      if (kind === 'primitive') f.world.__computaClaudeLastModelTrigger = 'private poison';
      if (kind === 'extra_key') record.unrecognized = true;
      if (kind === 'node_missing') delete record.node;
      if (kind === 'node_forged') record.node = { isConnected: false };
      if (kind === 'owner') record.owner = '00000000-0000-4000-8000-000000000009';
      if (kind === 'document') record.document = { URL: f.document.URL };
      if (kind === 'url') record.url += '&foreign';
      if (kind === 'node_getter') Object.defineProperty(record, 'node', { get: () => { throw new Error('private getter'); } });
      if (kind === 'record_getter') Object.defineProperty(f.world, '__computaClaudeLastModelTrigger', { get: () => { throw new Error('private getter'); } });
      const result = await f.run('inspect', { expectedModelChoice, allowClaudeModelObservationPending });
      expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
      expect(result.claudeModelObservationPending).toBeUndefined();
      expect(f.delays).toHaveLength(0); expect(f.send.clicks).toBe(0); expect(picker.trigger.clicks).toBe(0);
    }
  });

  test('absence before Send or during selection and final verification does not acquire a new waiting privilege', async () => {
    for (const action of ['inspect', 'verifyModel', 'prepare', 'selectModel']) {
      const f = fixture('claude'), picker = installObservedModelPicker(f, 'claude', Element);
      picker.selected('Opus 5'); picker.trigger.connected = false;
      const result = await f.run(action, { expectedModelChoice, modelChoice: expectedModelChoice });
      expect(result.error === 'model_unverified' || result.pending === true).toBe(true);
      expect(f.delays).toHaveLength(0); expect(f.send.clicks).toBe(0);
    }
    const f = fixture('claude', { userPrompt: 'Final guard control' }), picker = installObservedModelPicker(f, 'claude', Element);
    picker.selected('Opus 5'); let removed = false;
    f.window.webkit.messageHandlers.computaModelDiagnostic = { postMessage: ({ phase }: any) => {
      if (phase === 'final_model_guard') { picker.trigger.connected = false; removed = true; }
    } };
    const result = await f.run('inspect', { expectedModelChoice, operationID });
    expect(removed).toBe(true); expect(result.error).toBe('model_unverified');
    expect(f.delays).toHaveLength(0); expect(f.send.clicks).toBe(0);
  });
});


describe('Claude early user-count failure diagnostics', () => {
  const diagnostic = (result: any) => {
    expect(result.error).toBe('conversation_changed'); expect(result.detail).toBe('user_count');
    expect(result.text).toBeUndefined(); expect(result.firstUserVerified).toBeUndefined();
    expect(result.modelEvidence).toBeUndefined();
    const value = JSON.parse(result.debugStructure);
    const keys = ['expectedCounts', 'kind', 'provider', 'userCount', 'userCountSaturated'];
    if (value.kind === 'claude_missing_user_v1') keys.push('priorRoot', 'warningHook');
    expect(Object.keys(value).sort()).toEqual(keys.sort());
    expect(result.debugStructure.length).toBeLessThan(256);
    return value;
  };
  test('zero and duplicate counts are captured at the unchanged guard, including a hidden sibling', async () => {
    for (const count of [0, 2]) {
      const f = fixture('claude', { userPrompt: 'PRIVATE_USER_COUNT_BODY' });
      expect((await f.run()).firstUserVerified).toBe(true);
      if (count === 0) {
        f.messages.children = f.messages.children.filter(node => !node.contains(f.userRoot!));
        f.userRoot!.connected = false;
      }
      else f.messages.append(new Element('DIV', { 'data-testid': 'user-message', hidden: '' }, 'PRIVATE_DUPLICATE_BODY'));
      const original = f.document.querySelectorAll; let userReads = 0;
      f.document.querySelectorAll = (selector: string) => { if (selector === '[data-testid="user-message"]') userReads++; return original(selector); };
      Object.defineProperty(f.userRoot!, 'innerText', { get: () => { throw new Error('No body read allowed on count failure'); } });
      const result = await f.run('inspect');
      expect(diagnostic(result)).toEqual({ kind: count === 0 ? 'claude_missing_user_v1' : 'claude_user_count_v1',
        provider: 'claude', userCount: count, userCountSaturated: false, expectedCounts: [1],
        ...(count === 0 ? { priorRoot: 'detached', warningHook: 'none' } : {}) });
      expect(userReads).toBe(1);
      expect(result.debugStructure).not.toContain('PRIVATE_');
      expect(f.send.clicks).toBe(0); expect(f.composer.events).toHaveLength(0); expect(f.toggle.clicks).toBe(0);
    }
  });
  test('lost marker and warning-hook shape stay diagnostic, without scanning any page text or performing actions', async () => {
    for (const kind of ['plain', 'warning', 'authored', 'lost-user', 'duplicate', 'hidden', 'outside', 'weak-gone', 'wrong-digest', 'wrong-marker', 'reader-error']) {
      const f = fixture('claude', { userPrompt: 'PRIVATE_ROOT_BODY' });
      expect((await f.run()).firstUserVerified).toBe(true);
      const root = f.userRoot!, warning = new Element('DIV', {'data-testid': 'asl3-stop-warning'});
      delete root.values['data-testid'];
      if (kind === 'warning' || kind === 'duplicate' || kind === 'hidden') f.body.append(warning);
      if (kind === 'authored') f.answer.append(warning);
      if (kind === 'lost-user') root.append(warning);
      if (kind === 'duplicate') f.body.append(warning.cloneNode(true));
      if (kind === 'hidden') warning.values.hidden = '';
      if (kind === 'outside') f.messages.children = f.messages.children.filter(node => !node.contains(root));
      if (kind === 'weak-gone') f.world.__computaModelFirstProof.diagnosticRoot = {deref: () => undefined};
      for (const node of [root, warning]) {
        for (const name of ['innerText', 'textContent']) Object.defineProperty(node, name, {get: () => {
          throw new Error('PRIVATE_TEXT_WAS_READ');
        }});
      }
      if (kind === 'reader-error') {
        const original = f.document.querySelectorAll;
        f.document.querySelectorAll = (selector: string) => {
          if (selector.includes('asl3-stop-warning')) throw new Error('PRIVATE_EXCEPTION');
          return original(selector);
        };
      }
      const overrides = kind === 'wrong-digest' ? {expectedFirstUserFingerprint: 'f'.repeat(64)}
        : kind === 'wrong-marker' ? {expectedFirstUserMarker: 'PRIVATE_MARKER'} : {};
      const result = await f.run('inspect', overrides), packet = diagnostic(result);
      if (['wrong-digest','wrong-marker','reader-error'].includes(kind)) expect(packet.kind).toBe('claude_user_count_v1');
      else {
        expect(packet.priorRoot).toBe(kind === 'outside' ? 'outside_tree' : kind === 'weak-gone' ? 'unavailable' : 'marker_lost');
        expect(packet.warningHook).toBe(kind === 'warning' ? 'single_visible' : kind === 'duplicate' ? 'ambiguous'
          : ['authored','lost-user','hidden','weak-gone'].includes(kind) ? 'unverified' : 'none');
      }
      expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.answerComplete).toBeUndefined();
      expect(result.temporary).toBeUndefined(); expect(result.stopped).toBeUndefined();
      expect(f.send.clicks).toBe(0); expect(f.toggle.clicks).toBe(0); expect(f.composer.events).toHaveLength(0);
    }
  });
  test('nested user markers retain deduplication and allowed pending counts produce no failure diagnostic', async () => {
    const bound = fixture('claude', { userPrompt: 'Bounded synthetic count fixture' });
    const before = await bound.run();
    bound.userRoot!.append(new Element('DIV', { 'data-testid': 'user-message' }));
    const nested = await bound.run();
    expect(nested.firstUserFingerprint).toBe(before.firstUserFingerprint); expect(nested.userCount).toBe(1);
    expect(nested.error).toBeUndefined(); expect(nested.debugStructure).toBe('');
    const fresh = fixture('claude');
    const pending = await fresh.run('inspect', { expectedUserCounts: [0, 1] });
    expect(pending.error).toBeUndefined(); expect(pending.userCount).toBe(0); expect(pending.debugStructure).toBe('');
    expect(bound.send.clicks).toBe(0); expect(fresh.send.clicks).toBe(0);
  });
  test('malformed or unbounded expected-count inputs are unknown without copying them', async () => {
    for (const expectedUserCounts of [undefined, 'PRIVATE_EXPECTED', [true], ['PRIVATE_EXPECTED'], [1.5], [-1], [1001], [1, 2, 3, 4]]) {
      const f = fixture('claude'); const result = await f.run('inspect', { expectedUserCounts });
      expect(diagnostic(result)).toEqual({ kind: 'claude_user_count_v1', provider: 'claude', userCount: 0,
        userCountSaturated: false, expectedCounts: null });
      expect(result.debugStructure).not.toContain('PRIVATE_'); expect(f.send.clicks).toBe(0);
    }
    const f = fixture('claude');
    expect(diagnostic(await f.run('inspect', { expectedUserCounts: [] })).expectedCounts).toEqual([]);
  });
  test('large observed counts explicitly saturate instead of presenting the cap as exact', async () => {
    const f = fixture('claude');
    for (let i = 0; i < 1001; i++) f.messages.append(new Element('DIV', { 'data-testid': 'user-message' }));
    expect(diagnostic(await f.run())).toEqual({ kind: 'claude_user_count_v1', provider: 'claude', userCount: 1000,
      userCountSaturated: true, expectedCounts: [0] });
    expect(f.send.clicks).toBe(0);
  });
  test('a throwing diagnostic input preserves the same rejection without leaking the exception', async () => {
    const f = fixture('claude'); const expectedUserCounts = [1];
    expectedUserCounts.every = () => { throw new Error('PRIVATE_DIAGNOSTIC_EXCEPTION'); };
    expect(await f.run('inspect', { expectedUserCounts })).toEqual({ error: 'conversation_changed', detail: 'user_count' });
    expect(f.send.clicks).toBe(0);
  });
});

describe('native-turn Haiku 5.5 Incognito pilot', () => {
  const choice = { key: 'Haiku 5.5', label: 'Haiku 5.5' };
  const marker = '0949270b-f2a5-4ee0-8440-39ba7a4e4595';
  const second = 'Full input with matched tool output.\n\nComputa session marker: ' + marker;
  const pin = (sequence: number, value: string) => ({
    sequence, fingerprint: new Bun.CryptoHasher('sha256').update(value.normalize('NFC').trim()).digest('hex'),
  });
  function setup() {
    const f = fixture('claude'), picker = installObservedModelPicker(f, 'claude', Element);
    picker.selected(choice.label);
    const proofs = [pin(1, outbound), pin(2, second)];
    function ordered(node: Element) {
      Object.defineProperty(node, 'compareDocumentPosition', { value(other: Element) {
        const elements = f.html.descendants();
        return elements.includes(node) && elements.includes(other) && elements.indexOf(other) > elements.indexOf(node) ? 4 : 2;
      } });
    }
    f.send.onClick = () => {
      const root = f.appendUser(f.composer.innerText); ordered(root); f.composer.replaceChildren();
    };
    function answer(ordinal: number) {
      const article = ordinal === 1 ? f.article : f.article.cloneNode(true);
      const body = article.querySelector('[data-perf-reply-text]')!;
      body.text = ordinal === 1 ? '{"type":"message","text":"first"}' : '{"type":"message","text":"second"}';
      ordered(body); f.messages.append(article);
    }
    async function run(action: string, seq: number, users: number, extra: Record<string, unknown> = {}) {
      const editor = ['insert','submit','sendReady'].includes(action);
      const pins = proofs.slice(0, editor && action !== 'submit' ? seq - 1 : seq);
      return await f.run(action, { claudeRetainedTurn: true, expectedModelChoice: choice,
        expectedUserCounts: [users], expectedSubmissionProofs: pins,
        submissionSequence: seq, submissionMarker: seq === 1 ? firstMarker : marker,
        ...(editor ? {prompt: seq === 1 ? outbound : second} : {}), ...extra });
    }
    async function submitFirst() {
      expect(await run('insert', 1, 0)).toMatchObject({inserted: true});
      expect(await run('sendReady', 1, 0)).toMatchObject({sendReady: true});
      expect(await run('submit', 1, 0)).toMatchObject({submitted: true});
      answer(1);
      expect(await run('inspect', 1, 1)).toMatchObject({submissionProof: proofs[0], answerComplete: true});
    }
    return { f, picker, proofs, run, answer, submitFirst };
  }
  test('two single Sends append separate exact users and scoped completed replies', async () => {
    const { f, proofs, run, answer, submitFirst } = setup();
    await submitFirst();
    expect(await run('insert', 2, 1)).toMatchObject({inserted:true, submissionProof:proofs[0]});
    expect(await run('sendReady', 2, 1)).toMatchObject({sendReady:true});
    expect(await run('submit', 2, 1)).toMatchObject({submitted:true});
    answer(2);
    expect(await run('inspect', 2, 2)).toMatchObject({submissionProof:proofs[1], responseCount:2, answerComplete:true});
    expect((await run('submit', 2, 2)).error).toBeDefined();
    expect(f.send.clicks).toBe(2);
  });
  test('native uppercase marker and WebKit block spacing still require an exact literal editor', async () => {
    for (const suffix of ['', '\n', '\n\n']) {
      const { f, run } = setup(), upper = firstMarker.toUpperCase();
      const input = {submissionMarker:upper, expectedFirstUserMarker:upper, prompt:prompt + '\n\nComputa session marker: ' + upper};
      expect(await run('insert', 1, 0, input)).toMatchObject({inserted:true});
      Object.defineProperty(f.composer, 'innerText', {get: () => input.prompt + suffix});
      expect(await run('sendReady', 1, 0, input)).toMatchObject({sendReady:true});
      f.composer.children[0].append(new Element('#text', {}, '\n'));
      expect((await run('sendReady', 1, 0, input)).error).toBeDefined();
      expect(f.send.clicks).toBe(0);
    }
  });
  function providerAutoParagraph(f: ReturnType<typeof fixture>) {
    const paragraph = f.composer.children[0];
    const attributeFacts = Object.getOwnPropertyDescriptor(Element.prototype, 'attributes')!.get!;
    paragraph.values.dir = 'auto';
    Object.defineProperty(paragraph, 'attributes', {configurable:true, get: () =>
      attributeFacts.call(paragraph).map((attribute: object) => ({...attribute, namespaceURI:null}))});
    for (const node of [paragraph, ...paragraph.children.filter(child => child.tagName === 'BR')]) {
      Object.defineProperty(node, 'namespaceURI', {configurable:true, value:'http://www.w3.org/1999/xhtml'});
      Object.defineProperty(node, 'checkVisibility', {configurable:true, value:() => true});
    }
    return paragraph;
  }
  test('retained Haiku accepts the single auto-direction paragraph only with the complete original literal draft', async () => {
    const {f, run, answer, proofs} = setup();
    expect((await run('insert',1,0)).inserted).toBe(true);
    const p = providerAutoParagraph(f);
    expect(p.children.map(n => n.tagName === 'BR' ? '\n' : n.text).join('')).toBe(outbound);
    expect((await run('sendReady',1,0)).sendReady).toBe(true);
    expect((await run('submit',1,0)).submitted).toBe(true);
    answer(1);
    expect(await run('inspect',1,1)).toMatchObject({submissionProof:proofs[0], answerComplete:true});
    expect((await run('submit',1,1)).submitted).not.toBe(true);
    expect(f.send.clicks).toBe(1);
  });
  test('retained Haiku refuses altered direction, visibility, markup and fake rendered matches at readiness and submit', async () => {
    for (const boundary of ['sendReady','submit']) {
      for (const change of ['rtl','ltr','AUTO','empty','extraAttribute','foreignP','namespacedDir','hiddenP','hiddenBR',
        'foreignBR','control','multiP','NBSP','appendedBreak','literalSubstitution','renderedSubstitution']) {
        const {f,run}=setup();
        expect((await run('insert',1,0)).inserted).toBe(true);
        const p=providerAutoParagraph(f);
        Object.defineProperty(f.composer,'innerText',{configurable:true,get:()=>outbound});
        if (boundary==='submit') expect((await run('sendReady',1,0)).sendReady).toBe(true);
        const br=p.children.find(n => n.tagName==='BR')!;
        if (['rtl','ltr','AUTO','empty'].includes(change)) p.values.dir=change==='empty'?'':change;
        if (change==='extraAttribute') p.values.title='auto';
        if (change==='foreignP' || change==='foreignBR') Object.defineProperty(change==='foreignP'?p:br,'namespaceURI',{value:'urn:fixture'});
        if (change==='namespacedDir') Object.defineProperty(p,'attributes',{get:()=>[{name:'dir',value:'auto',namespaceURI:'urn:fixture'}]});
        if (change==='hiddenP' || change==='hiddenBR') Object.defineProperty(change==='hiddenP'?p:br,'checkVisibility',{value:()=>false});
        if (change==='control') p.append(new Element('BUTTON'));
        if (change==='multiP') f.composer.append(new Element('P',{},'another paragraph'));
        if (change==='NBSP') {
          const n=p.children.find(n=>n.text.includes('\u00a0'))!;
          n.text=n.text.replace('\u00a0',' ');
        }
        if (change==='appendedBreak') p.append(new Element('BR'));
        if (change==='literalSubstitution') p.children[0].text='wrong draft';
        if (change==='renderedSubstitution') Object.defineProperty(f.composer,'innerText',{get:()=>outbound+'x'});
        expect((await run(boundary,1,0)).error).toBeDefined();
        expect(f.send.clicks).toBe(0);
      }
    }
  });
  test('only the first retained readiness rejection exposes the fixed editor reason', async () => {
    for (const sequence of [1, 2]) {
      const { f, run, submitFirst } = setup();
      if (sequence === 2) await submitFirst();
      expect(await run('insert', sequence, sequence - 1)).toMatchObject({inserted:true});
      f.composer.children[0].values['data-example'] = 'private attribute value';
      const failure = await run('sendReady', sequence, sequence - 1);
      expect(failure).toMatchObject({error:'conversation_changed', detail:'submission_message'});
      expect(failure.haikuFirstReadyReason).toBe(sequence === 1 ? 'editor_paragraph' : undefined);
      expect(JSON.stringify(failure)).not.toContain('private attribute value');
      expect((await run('submit', sequence, sequence - 1)).haikuFirstReadyReason).toBeUndefined();
      expect(f.send.clicks).toBe(sequence - 1);
    }
  });
  test('model-only verification cannot bind a newly rendered second user; inspection binds it once', async () => {
    const { f, proofs, run, answer, submitFirst } = setup();
    await submitFirst();
    expect(await run('insert', 2, 1)).toMatchObject({inserted:true});
    expect(await run('sendReady', 2, 1)).toMatchObject({sendReady:true});
    expect(await run('submit', 2, 1)).toMatchObject({submitted:true});
    answer(2);
    expect(await run('verifyModel', 2, 2)).toMatchObject({error:'conversation_changed', detail:'submission_message'});
    expect(await run('inspect', 2, 2)).toMatchObject({submissionProof:proofs[1], answerComplete:true});
    expect(f.send.clicks).toBe(2);
  });
  test('native cleanup suppresses answer authority and can close an exactly owned yielded turn', async () => {
    const { f, proofs, run, submitFirst } = setup();
    await submitFirst();
    const cleanup = await run('inspect', 1, 1, {expectedModelChoice: null, claudeRetainedCleanup: true});
    expect(cleanup).toMatchObject({submissionProof: proofs[0], answerComplete:false, text:'', temporary:true});
    f.answer.text += ' altered';
    expect((await run('inspect', 1, 1, {expectedModelChoice: null, claudeRetainedCleanup: true})).error).toBeDefined();
    expect(f.send.clicks).toBe(1);
  });
  test('losing the prior answer during the second submit ownership digest prevents the click', async () => {
    const { f, run, submitFirst } = setup();
    await submitFirst(); expect(await run('insert', 2, 1)).toMatchObject({inserted:true});
    expect(await run('sendReady', 2, 1)).toMatchObject({sendReady:true});
    f.onDigest(() => { f.answer.text = 'changed during proof'; });
    expect((await run('submit', 2, 1)).error).toBeDefined();
    expect(f.send.clicks).toBe(1);
  });
  test('an extra hidden assistant and a collision of native submission markers fail closed', async () => {
    const { f, run, submitFirst } = setup();
    await submitFirst();
    expect((await run('insert', 2, 1, {submissionMarker:firstMarker, prompt:outbound})).error).toBeDefined();
    const foreign = new Element('DIV', {'data-testid':'assistant-message', hidden:''}); f.messages.append(foreign);
    expect((await run('insert', 2, 1)).error).toBeDefined();
    expect(f.send.clicks).toBe(1);
  });
  for (const mutation of ['lost owner','changed model','same-label picker remounted','lost Incognito','changed answer','replaced answer','changed user','wrong digest','wrong draft']) {
    test('refuses the next Send after ' + mutation, async () => {
      const { f, picker, proofs, run, submitFirst } = setup();
      await submitFirst(); expect(await run('insert', 2, 1)).toMatchObject({inserted:true});
      expect(await run('sendReady', 2, 1)).toMatchObject({sendReady:true});
      if (mutation === 'lost owner') f.world.__computaModelOwner = firstMarker;
      if (mutation === 'changed model') picker.selected('Sonnet 5.5');
      if (mutation === 'same-label picker remounted') {
        const trigger = picker.trigger, parent = trigger.parentElement!, next = trigger.cloneNode(true);
        const pos = parent.children.indexOf(trigger);
        expect(pos).toBeGreaterThanOrEqual(0);
        parent.children[pos] = next; next.parentElement = parent; trigger.parentElement = null; trigger.connected = false;
        // The selector still displays the requested name on a different physical control.
        expect(next.getAttribute('aria-label')).toBe(trigger.getAttribute('aria-label'));
      }
      if (mutation === 'lost Incognito') f.temporary(false);
      if (mutation === 'changed answer') f.answer.text += ' altered';
      if (mutation === 'replaced answer') f.response.replaceChildren(f.answer.cloneNode(true));
      if (mutation === 'changed user') f.userBody!.text += ' altered';
      if (mutation === 'wrong digest') proofs[0].fingerprint = proofs[1].fingerprint;
      if (mutation === 'wrong draft') f.composer.replaceChildren(new Element('#text', {}, second + ' altered'));
      expect((await run('submit', 2, 1)).error).toBeDefined();
      expect(f.send.clicks).toBe(1);
    });
  }
});

import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import manifest from "./manifest.json";
import { fixtureResponse } from "./serve";

const read = (name: string) => readFile(join(import.meta.dir, name), "utf8");
const browserPages = [...new Set(manifest.tasks.flatMap(task => [...(task.initialPages ?? []),
  ...("supportPages" in task ? task.supportPages ?? [] : [])]))];
const visibleMarkup = (html: string) => html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "");

describe("synthetic lookup fixture integrity (not a model evaluation)", () => {
  test("each deterministic task has separate oracle files and values", async () => {
    expect(new Set(manifest.tasks.map(task => task.id)).size).toBe(manifest.tasks.length);
    expect(Object.keys(manifest.oracles).sort()).toEqual(manifest.tasks.map(task => task.id).sort());
    for (const task of manifest.tasks) {
      const oracle = manifest.oracles[task.id as keyof typeof manifest.oracles];
      expect(task.prompt.length).toBeGreaterThan(30);
      expect(oracle.requiredValues.length).toBeGreaterThan(0);
      const content = (await Promise.all(oracle.sourceFiles.map(read))).join("\n");
      for (const value of oracle.requiredValues) expect(content).toContain(value);
    }
  });

  test("exact title has a near-match distractor; document decoys occupy distinct structures", async () => {
    const actual = await read("archive.html"), sidebar = await read("sidebar.html");
    expect(actual).toContain("<title>Copper Atlas - Archive index</title>");
    expect(sidebar).toContain("<title>Copper Atlas - Archive index - Draft</title>");
    const phrase = "17 field samples accepted on 16 October 2032";
    expect(sidebar.match(/<aside\b[\s\S]*?<\/aside>/)?.[0]).toContain(phrase);
    expect(sidebar.match(/<main\b[\s\S]*?<\/main>/)?.[0]).not.toContain(phrase);
    const toolbar = await read("toolbar.html");
    expect(toolbar.match(/<main\b[\s\S]*?<\/main>/)?.[0]).toContain('role="toolbar"');
    expect(toolbar.match(/<button\b[\s\S]*?<\/button>/)?.[0]).toContain(phrase);
    expect(toolbar.match(/<article\b[\s\S]*?<\/article>/)?.[0]).not.toContain(phrase);
    expect((await read("document.html")).match(/<article\b[\s\S]*?<\/article>/)?.[0])
      .toContain(manifest.oracles["document-content"].supportingExcerpt);
  });

  test("detail answer differs from preview and landmark-free text remains present", async () => {
    const email = await read("email.html");
    const preview = email.match(/<aside\b[\s\S]*?<\/aside>/)?.[0] ?? "";
    const body = email.match(/<article\b[\s\S]*?<\/article>/)?.[0] ?? "";
    for (const value of manifest.oracles["email-details"].contradictedPreviewValues) {
      expect(preview).toContain(value); expect(body).not.toContain(value);
    }
    for (const value of manifest.oracles["email-details"].requiredValues) expect(body).toContain(value);
    const unmarked = await read("no-landmarks.html");
    expect(unmarked).not.toMatch(/<(?:main|article|nav|aside)\b|role="(?:main|article|navigation|complementary)"/i);
    expect(unmarked).toContain(manifest.oracles["absent-landmarks"].supportingExcerpt);
  });

  test("long answer is beyond 512 characters of a single uninterrupted text node", async () => {
    const html = await read("long-field.html");
    const field = html.match(/<p id="long-record">([^<]+)<\/p>/)?.[1] ?? "";
    expect(field.indexOf(manifest.oracles["long-field"].supportingExcerpt)).toBeGreaterThan(512);
    expect(field.slice(0, 512)).not.toContain("LARK-7392");
  });

  test("continued answer requires field slices without overflowing the retained field", async () => {
    const html = await read("continued-field.html");
    const oracle = manifest.oracles["continued-field"];
    const field = html.match(/<p id="continued-record">([^<]+)<\/p>/)?.[1] ?? "";
    const at = field.indexOf(oracle.supportingExcerpt);
    expect(at).toBeGreaterThan(0);
    const prefixBytes = Buffer.byteLength(field.slice(0, at), "utf8");
    const fieldBytes = Buffer.byteLength(field, "utf8");
    expect(prefixBytes).toBeGreaterThan(oracle.minimumAnswerUTF8Offset);
    expect(fieldBytes).toBeLessThan(oracle.maximumRetainedFieldUTF8Bytes);
    expect(fieldBytes).toBeGreaterThan(2 * oracle.expectedFieldFragmentUTF8Limit);
    expect(field.slice(0, oracle.expectedFieldFragmentUTF8Limit)).not.toContain(oracle.requiredValues[0]);
    expect(field.slice(at)).toBe(oracle.supportingExcerpt);
    expect(html.match(/<title>([^<]+)<\/title>/)?.[1]).not.toContain(oracle.requiredValues[0]);
    expect(html.match(/<h1>([^<]+)<\/h1>/)?.[1]).not.toContain(oracle.requiredValues[0]);
    // Keep one text node and standard unnamed ancestors. No ancestor ARIA
    // name or duplicate hidden/source-only answer substitutes for the body.
    expect(html).not.toMatch(/<script\b|aria-label(?:ledby)?=|<span\b|hidden\b/);
    expect(html.match(new RegExp(oracle.requiredValues[0], "g"))).toHaveLength(1);
    expect(html).toContain('<main><article><h1>Hazel batch record</h1><p id="continued-record">');
  });

  test("virtualized record is absent initially and replaces earlier rows after bounded local paging", async () => {
    const html = await read("virtualized.html");
    const target = manifest.oracles["virtualized-records"].requiredValues[0];
    expect(visibleMarkup(html)).not.toContain(target);
    let click: (() => void) | undefined;
    const list = { rows: ["Amber Kite: 12 boxes", "Birch Pebble: 31 boxes"], replaceChildren(...items: { textContent: string }[]) { this.rows = items.map(item => item.textContent); } };
    const status = { textContent: "" };
    const button = { disabled: false, addEventListener(event: string, callback: () => void) { expect(event).toBe("click"); click = callback; } };
    const nodes = { "mounted-records": list, "page-status": status, "next-page": button };
    const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1] ?? "";
    runInNewContext(script, { document: {
      getElementById: (id: keyof typeof nodes) => nodes[id],
      createElement: (tag: string) => { expect(tag).toBe("li"); return { textContent: "" }; },
    } });
    expect(click).toBeDefined();
    click!(); expect(list.rows).not.toContain(target); expect(button.disabled).toBe(false);
    click!(); expect(list.rows).toContain(target); expect(list.rows.length).toBe(2);
    expect(list.rows).not.toContain("Amber Kite: 12 boxes");
    expect(status.textContent).toContain("5-6 of 6"); expect(button.disabled).toBe(true);
    click!(); expect(list.rows).toContain(target); expect(list.rows.length).toBe(2);
  });

  test("pages are self-contained and the server hides evaluator files and rejects writes", async () => {
    for (const name of browserPages) {
      const html = await read(name);
      expect(html).not.toMatch(/https?:\/\/|\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|localStorage|sessionStorage|indexedDB)\b|sendBeacon|serviceWorker|document\.cookie|<form\b/i);
      expect(html).not.toMatch(/\bsrc\s*=/i);
      for (const link of html.matchAll(/\bhref="([^"]+)"/g)) expect(browserPages).toContain(link[1]);
      const response = fixtureResponse(new Request(`http://127.0.0.1:8765/${name}`));
      expect(response.status).toBe(200); expect(await response.text()).toBe(html);
      expect(response.headers.get("Content-Security-Policy")).toContain("connect-src 'none'");
    }
    for (const path of ["manifest.json", "serve.ts", "fixtures.test.ts", "README.md", "native-read.txt", "../manifest.json", "%6danifest.json"]) {
      expect(fixtureResponse(new Request(`http://127.0.0.1:8765/${path}`)).status).toBe(404);
    }
    expect(fixtureResponse(new Request("http://127.0.0.1:8765/document.html", { method: "POST" })).status).toBe(405);
    expect(await fixtureResponse(new Request("http://127.0.0.1:8765/document.html", { method: "HEAD" })).text()).toBe("");
  });

  test("native fixture remains an explicitly pending native-app gate", () => {
    expect(manifest.tasks.find(task => task.id === "native-read")?.surface).toBe("native");
    expect(manifest.oracles["native-read"].evaluationStatus).toBe("pending_native_app_read");
  });
});


describe("held-out search discovery fixture (inert DOM, not browser/model validation)", () => {
  const script = (html: string) => html.match(/<script>([\s\S]*?)<\/script>/)?.[1] ?? "";
  class Node {
    textContent = "";
    value = "";
    hidden = false;
    open = false;
    attrs: Record<string, string> = {};
    children: Node[] = [];
    events: Record<string, () => void> = {};
    setAttribute(key: string, value: string) { this.attrs[key] = value; }
    removeAttribute(key: string) { delete this.attrs[key]; }
    append(node: Node) { this.children.push(node); }
    addEventListener(event: string, callback: () => void) { this.events[event] = callback; }
    showModal() { this.open = true; }
    close() { this.open = false; this.events.close?.(); }
  }
  const documentFor = (nodes: Record<string, Node>) => ({ getElementById: (id: string) => nodes[id], createElement: () => new Node() });

  test("home and search expose generic affordances without target facts or a prefilled query", async () => {
    const home = await read("meridian-home.html"), search = await read("meridian-search.html");
    const task = manifest.tasks.find(task => task.id === "search-discovery")!;
    expect(task.initialPages).toEqual(["meridian-home.html"]);
    expect(task.prompt).not.toMatch(/search|click|type|r17|29|November|meridian-.*html/i);
    expect(home).toContain('<a href="meridian-search.html">Search records</a>');
    expect(home).not.toContain("Juniper Veil");
    for (const value of manifest.oracles["search-discovery"].requiredValues) {
      expect(home).not.toContain(value); expect(search).not.toContain(value);
    }
    expect(search).toContain('type="search" autocomplete="off" value=""');
    expect(visibleMarkup(await read("meridian-results.html"))).not.toContain("Juniper Veil");
    expect(visibleMarkup(await read("meridian-record.html"))).not.toContain("29 crates");
  });

  test("query entry reveals an encoded observed results link but does not submit or reveal content", async () => {
    const nodes = { "record-query": new Node(), "show-results": new Node(), "query-status": new Node() };
    runInNewContext(script(await read("meridian-search.html")), { document: documentFor(nodes) });
    nodes["record-query"].value = "Juniper Veil"; nodes["record-query"].events.input();
    expect(nodes["show-results"].attrs.href).toBe("meridian-results.html?q=Juniper%20Veil");
    expect(nodes["show-results"].hidden).toBe(false);
    expect(nodes["query-status"].textContent).toContain("Open results");
    expect(JSON.stringify(nodes)).not.toContain("29 crates");
    nodes["record-query"].value = 'C++ & "rare"'; nodes["record-query"].events.input();
    expect(new URL(nodes["show-results"].attrs.href, "http://fixture.invalid/").searchParams.get("q")).toBe('C++ & "rare"');
    nodes["record-query"].value = "   "; nodes["record-query"].events.input();
    expect(nodes["show-results"].hidden).toBe(true); expect(nodes["show-results"].attrs.href).toBeUndefined();
  });

  test("results depend on the submitted query; metadata precedes separate record content", async () => {
    const source = script(await read("meridian-results.html"));
    const render = (query: string) => {
      const nodes = { "displayed-query": new Node(), "results-status": new Node(), "result-list": new Node() };
      runInNewContext(source, { document: documentFor(nodes), location: { search: "?q=" + encodeURIComponent(query) }, URLSearchParams });
      return nodes;
    };
    const empty = render("not in this collection");
    expect(empty["result-list"].children).toHaveLength(0);
    expect(empty["results-status"].textContent).toBe("No results found.");
    const broad = render("Juniper"); expect(broad["result-list"].children).toHaveLength(2);
    const exact = render("Juniper Veil survey return");
    expect(exact["result-list"].children).toHaveLength(1);
    const row = exact["result-list"].children[0];
    expect(row.attrs["aria-label"]).toBe("Juniper Veil survey return");
    expect(row.children[0].attrs.href).toBe("meridian-record.html?entry=r17");
    expect(JSON.stringify(exact)).not.toContain("29 crates");
    const nodes = { "record-title": new Node(), "record-body": new Node() };
    runInNewContext(script(await read("meridian-record.html")), { document: documentFor(nodes), location: { search: "?entry=r17" }, URLSearchParams });
    expect(nodes["record-body"].textContent).toBe(manifest.oracles["search-discovery"].supportingExcerpt);
    expect(nodes["record-title"].textContent).toBe(manifest.oracles["search-discovery"].recordTitle);
    const invalid = { "record-title": new Node(), "record-body": new Node() };
    runInNewContext(script(await read("meridian-record.html")), { document: documentFor(invalid), location: { search: "?entry=__proto__" }, URLSearchParams });
    expect(invalid["record-body"].textContent).toBe("");
  });

  test("dialog discovery starts with a closed generic dialog and no facts or interaction hints", async () => {
    const task = manifest.tasks.find(task => task.id === "dialog-search-discovery")!;
    const home = await read("lumen-home.html"), results = await read("lumen-results.html");
    expect(task.initialPages).toEqual(["lumen-home.html"]);
    expect(task.prompt).not.toMatch(/search|dialog|click|type|l24|42|February|lumen-.*html/i);
    expect(home).toContain('aria-haspopup="dialog" aria-controls="record-search-dialog" aria-expanded="false">Search records</button>');
    expect(home).toContain('<dialog id="record-search-dialog" aria-labelledby="search-title">');
    expect(home).not.toMatch(/<dialog\b[^>]*\bopen(?:\s|=|>)/);
    expect(home).not.toContain("Orchid Basin");
    expect(home).not.toMatch(/\blocation\b|history\.|lumen-record\.html/);
    expect(home).toContain('type="search" autocomplete="off" value=""');
    for (const value of manifest.oracles["dialog-search-discovery"].requiredValues) {
      expect(home).not.toContain(value); expect(results).not.toContain(value);
    }
    expect(visibleMarkup(await read("lumen-record.html"))).not.toContain("42 bundles");
  });

  test("same-document dialog and query controls change only bounded local state", async () => {
    const nodes = { "open-search": new Node(), "record-search-dialog": new Node(), "close-search": new Node(),
      "record-query": new Node(), "show-results": new Node(), "query-status": new Node() };
    runInNewContext(script(await read("lumen-home.html")), { document: documentFor(nodes) });
    expect(nodes["record-search-dialog"].open).toBe(false);
    nodes["open-search"].events.click();
    expect(nodes["record-search-dialog"].open).toBe(true);
    expect(nodes["open-search"].attrs["aria-expanded"]).toBe("true");
    nodes["record-query"].value = "Orchid Basin"; nodes["record-query"].events.input();
    expect(nodes["show-results"].attrs.href).toBe("lumen-results.html?q=Orchid%20Basin");
    expect(nodes["show-results"].hidden).toBe(false);
    expect(JSON.stringify(nodes)).not.toContain("42 bundles");
    nodes["record-query"].value = 'C++ & "rare"'; nodes["record-query"].events.input();
    expect(new URL(nodes["show-results"].attrs.href, "http://fixture.invalid/").searchParams.get("q")).toBe('C++ & "rare"');
    nodes["record-query"].value = "   "; nodes["record-query"].events.input();
    expect(nodes["show-results"].hidden).toBe(true); expect(nodes["show-results"].attrs.href).toBeUndefined();
    nodes["close-search"].events.click();
    expect(nodes["record-search-dialog"].open).toBe(false);
    expect(nodes["open-search"].attrs["aria-expanded"]).toBe("false");
  });

  test("dialog task results depend on the query and only the selected record body supports the facts", async () => {
    const source = script(await read("lumen-results.html"));
    const render = (query: string) => {
      const nodes = { "displayed-query": new Node(), "results-status": new Node(), "result-list": new Node() };
      runInNewContext(source, { document: documentFor(nodes), location: { search: "?q=" + encodeURIComponent(query) }, URLSearchParams });
      return nodes;
    };
    expect(render("")["result-list"].children).toHaveLength(0);
    expect(render("not in this collection")["results-status"].textContent).toBe("No results found.");
    expect(render("Orchid")["result-list"].children).toHaveLength(2);
    const exact = render("Orchid Basin intake note");
    expect(exact["result-list"].children).toHaveLength(1);
    const row = exact["result-list"].children[0];
    expect(row.attrs["aria-label"]).toBe("Orchid Basin intake note");
    expect(row.children[0].attrs.href).toBe("lumen-record.html?entry=l24");
    expect(JSON.stringify(exact)).not.toContain("42 bundles");
    const nodes = { "record-title": new Node(), "record-body": new Node() };
    runInNewContext(script(await read("lumen-record.html")), { document: documentFor(nodes), location: { search: "?entry=l24" }, URLSearchParams });
    expect(nodes["record-body"].textContent).toBe(manifest.oracles["dialog-search-discovery"].supportingExcerpt);
    expect(nodes["record-title"].textContent).toBe(manifest.oracles["dialog-search-discovery"].recordTitle);
    const invalid = { "record-title": new Node(), "record-body": new Node() };
    runInNewContext(script(await read("lumen-record.html")), { document: documentFor(invalid), location: { search: "?entry=__proto__" }, URLSearchParams });
    expect(invalid["record-body"].textContent).toBe("");
  });
});

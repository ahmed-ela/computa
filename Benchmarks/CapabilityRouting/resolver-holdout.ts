// Independently authored holdout. A runner must send only { prompt, apps } to
// the resolver; IDs and expectedBundleID are evaluation metadata, never input.
export type ResolverHoldoutFixture = {
  readonly id: string;
  readonly prompt: string;
  readonly apps: readonly { readonly name: string; readonly bundle_id: string }[];
  readonly expectedBundleID: string | null;
};

export const resolverHoldoutFixtures = [
  {
    id: "hold-remote-session-name",
    prompt: "In Vela View, inspect the remote session named Maple Port and tell me which folder is highlighted there.",
    apps: [
      { name: "Maple Port", bundle_id: "test.maple.port" },
      { name: "Vela View", bundle_id: "test.vela.view" },
      { name: "Pebble Pad", bundle_id: "test.pebble.pad" },
    ],
    expectedBundleID: "test.vela.view",
  },
  {
    id: "hold-guest-browser-name",
    prompt: "Use Kestrel Virtual Desk to check the Sable Browser window inside the guest. Read the visible build number from that browser, not from a browser on this Mac.",
    apps: [
      { name: "Sable Browser", bundle_id: "test.sable.browser" },
      { name: "Birch Ledger", bundle_id: "test.birch.ledger" },
      { name: "Kestrel Virtual Desk", bundle_id: "test.kestrel.virtualdesk" },
    ],
    expectedBundleID: "test.kestrel.virtualdesk",
  },
  {
    id: "hold-document-name",
    prompt: "Read footnote four in Lumen Notes, the document I have open in Tern Reader.",
    apps: [
      { name: "Tern Reader", bundle_id: "test.tern.reader" },
      { name: "Lumen Notes", bundle_id: "test.lumen.notes" },
      { name: "Fennel Clock", bundle_id: "test.fennel.clock" },
    ],
    expectedBundleID: "test.tern.reader",
  },
  {
    id: "hold-local-browser",
    prompt: "In Quill Browser on this Mac, read the title of the tab that is already selected. Leave its page unchanged.",
    apps: [
      { name: "Cairn Viewer", bundle_id: "test.cairn.viewer" },
      { name: "Quill Browser", bundle_id: "test.quill.browser" },
      { name: "Nettle Terminal", bundle_id: "test.nettle.terminal" },
    ],
    expectedBundleID: "test.quill.browser",
  },
  {
    id: "hold-two-possible-viewers",
    prompt: "Read the status banner in my shared-workstation viewer. I cannot remember which of my two viewer apps contains that session.",
    apps: [
      { name: "Morrow View", bundle_id: "test.morrow.view" },
      { name: "Clover Calculator", bundle_id: "test.clover.calculator" },
      { name: "Runnel View", bundle_id: "test.runnel.view" },
    ],
    expectedBundleID: null,
  },
  {
    id: "hold-named-host-missing",
    prompt: "Use Ardent View to inspect the remote session called Cinder Box and report its selected volume.",
    apps: [
      { name: "Cinder Box", bundle_id: "test.cinder.box" },
      { name: "Wren Viewer", bundle_id: "test.wren.viewer" },
      { name: "Mica Mail", bundle_id: "test.mica.mail" },
    ],
    expectedBundleID: null,
  },
  {
    id: "hold-no-host-evidence",
    prompt: "Tell me whether the delivery grid has a warning beside the violet row. I do not know which app it belongs to.",
    apps: [
      { name: "Sorrel Desk", bundle_id: "test.sorrel.desk" },
      { name: "Flint Board", bundle_id: "test.flint.board" },
      { name: "Aster Panel", bundle_id: "test.aster.panel" },
    ],
    expectedBundleID: null,
  },
  {
    id: "hold-rendered-canvas",
    prompt: "Inspect the amber marker on the raster canvas shown in Moss Draft. The open drawing is called Corbel Map; tell me the number painted next to that marker.",
    apps: [
      { name: "Reed Recorder", bundle_id: "test.reed.recorder" },
      { name: "Corbel Map", bundle_id: "test.corbel.map" },
      { name: "Moss Draft", bundle_id: "test.moss.draft" },
    ],
    expectedBundleID: "test.moss.draft",
  },
] as const satisfies readonly ResolverHoldoutFixture[];

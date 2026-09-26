// Frozen before inference; these are experimental, not shipping instructions.
export const candidates = {
  baseline: "",
  inspect: "Tools act through the bound app, including remote desktops or canvases displayed inside it. Before claiming a UI task unsupported, open and observe the relevant app. If AX omits content, capture it. Status/apps alone do not establish inability; report only observed blockers.",
  boundary: "Tools act through the bound app, including remote desktops or canvases displayed inside it. Before claiming a UI task unsupported, open and observe the relevant app. If AX omits content, capture it. Status/apps alone do not establish inability; report only observed blockers. Keep input bound to the app displaying the requested content; opening a similarly named local app does not operate an app displayed inside another session. Stop at observed permission, authentication, or policy barriers; do not bypass them.",
} as const;
export type Arm = keyof typeof candidates;

const elements = Object.fromEntries(["status","pair","resume","forget","web-cleanup-warning"].map(id => [id, document.getElementById(id)]));
async function refresh(action = "status") {
  const response = await chrome.runtime.sendMessage({action});
  if (!response?.ok) { elements.status.textContent = "Open Computa to finish connecting."; return; }
  for (const [id, attributes] of Object.entries(response.result.view || {})) {
    const element = elements[id];
    if (!element) continue;
    for (const [key, value] of Object.entries(attributes)) element[key] = value;
  }
}
for (const id of ["pair","resume","forget"]) elements[id].addEventListener("click", () => refresh(id));
void refresh();

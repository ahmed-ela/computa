const status = document.getElementById("status");
const pair = document.getElementById("pair");
const resume = document.getElementById("resume");
const forget = document.getElementById("forget");

async function refresh(action = "status") {
  for (const button of [pair, resume, forget]) button.disabled = true;
  try {
    const response = await chrome.runtime.sendMessage({ action });
    if (!response?.ok) throw new Error(response?.error ?? "Open Macrouse to finish connecting.");
    const state = response.result;
    status.textContent = action === "pair" ? "Confirm the pairing in Macrouse."
      : !state.paired ? "Not paired" : state.suspended ? "Access paused"
      : state.connected ? "Connected to Macrouse" : "Paired · waiting for Macrouse";
    pair.hidden = state.paired;
    resume.hidden = !state.paired || (state.connected && !state.suspended);
    forget.hidden = !state.paired;
  } catch (error) { status.textContent = error.message; }
  finally { for (const button of [pair, resume, forget]) button.disabled = false; }
}
pair.addEventListener("click", () => refresh("pair"));
resume.addEventListener("click", () => refresh("resume"));
forget.addEventListener("click", () => refresh("forget"));
void refresh();

// Original Responses receipts use strings for text-only output and typed
// content arrays for image-bearing output. Neither shape is a summary.
export function receiptText(output: unknown): string | null {
  if (typeof output === "string") return output;
  if (!Array.isArray(output)) return null;
  if (output.some(c => !c || typeof c !== "object" || !["input_text", "input_image"].includes(c.type))) return null;
  const texts = output.filter(c => c.type === "input_text");
  if (texts.some(c => typeof c.text !== "string")) return null;
  return texts.map(c => c.text).join("\n");
}

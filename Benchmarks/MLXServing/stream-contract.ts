export type Event = { type: string; [key: string]: any };

export class SSEDecoder {
  pending = "";
  push(text: string): Event[] {
    this.pending = (this.pending + text).replace(/\r\n/g, "\n");
    if (this.pending.length > 2 * 1024 * 1024) throw new Error("SSE frame exceeds bound");
    const events: Event[] = [];
    let end: number;
    while ((end = this.pending.indexOf("\n\n")) >= 0) {
      const frame = this.pending.slice(0, end);
      this.pending = this.pending.slice(end + 2);
      const data = frame.split("\n").filter(line => line.startsWith("data:"))
        .map(line => line.slice(5).trimStart()).join("\n");
      if (!data || data === "[DONE]") continue;
      const value = JSON.parse(data);
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid SSE JSON");
      if (typeof value.type !== "string") {
        if (value.error) events.push({ type: "provider.error", error: value.error });
        else throw new Error("SSE JSON missing event type");
      } else events.push(value);
    }
    return events;
  }
  finish() { if (this.pending.trim()) throw new Error("Truncated SSE frame"); }
}

export function completed(events: Event[], model: string) {
  const errors = events.filter(e => ["error", "provider.error", "response.failed"].includes(e.type));
  if (errors.length) throw new Error(`Provider stream error (${errors[0].type})`);
  const endings = events.filter(e => e.type === "response.completed");
  if (endings.length !== 1) throw new Error(`Expected exactly one completed event; got ${endings.length}`);
  const response = endings[0].response;
  if (response?.status !== "completed" || response.error || response.incomplete_details || response.model !== model
      || !Array.isArray(response.output)) throw new Error("Invalid completed response");
  const usage = response.usage;
  if (!usage || !Number.isInteger(usage.input_tokens) || !Number.isInteger(usage.output_tokens)
      || usage.input_tokens < 1 || usage.output_tokens < 1
      || usage.total_tokens !== usage.input_tokens + usage.output_tokens) throw new Error("Invalid token usage");
  const created = events.filter(e => e.type === "response.created");
  if (created.length !== 1 || created[0].response?.id !== response.id) throw new Error("Response identity mismatch");
  return response;
}

export function finalText(response: any) {
  return response.output.filter((item: any) => item.type === "message" && item.role === "assistant")
    .flatMap((item: any) => item.content ?? []).filter((part: any) => part.type === "output_text")
    .map((part: any) => part.text).join("");
}

export function consistentText(events: Event[], response: any) {
  const deltas = events.filter(e => e.type === "response.output_text.delta").map(e => e.delta).join("");
  if (deltas !== finalText(response)) throw new Error("Output deltas/final text differ");
  return deltas;
}

export function exactText(events: Event[], response: any, expected: string) {
  if (consistentText(events, response).trim() !== expected) throw new Error("Output text differs from exact oracle");
  if (response.output.some((item: any) => item.type === "function_call")) throw new Error("Unexpected function call");
}

export function functionCall(events: Event[], response: any, name: string, argumentsJSON: string) {
  const calls = response.output.filter((item: any) => item.type === "function_call");
  if (calls.length !== 1) throw new Error(`Expected one function call; got ${calls.length}`);
  const call = calls[0];
  if (call.name !== name || typeof call.call_id !== "string" || !call.call_id || typeof call.id !== "string" || !call.id
      || JSON.stringify(JSON.parse(call.arguments)) !== argumentsJSON) throw new Error("Function identity/arguments mismatch");
  const matching = (type: string) => events.map((e, index) => ({ e, index }))
    .filter(({ e }) => e.type === type && (e.item?.id === call.id || e.item_id === call.id));
  const added = matching("response.output_item.added"), args = matching("response.function_call_arguments.done"), done = matching("response.output_item.done");
  if (added.length !== 1 || args.length !== 1 || done.length !== 1
      || !(added[0].index < args[0].index && args[0].index < done[0].index)
      || done[0].e.item.call_id !== call.call_id || done[0].e.item.arguments !== call.arguments
      || (args[0].e.arguments ?? args[0].e.item?.arguments) !== call.arguments) throw new Error("Function lifecycle/call ID mismatch");
  return call;
}

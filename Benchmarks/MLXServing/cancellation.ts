import type { Event } from "./stream-contract";

export type CancelAt = "none" | "first_public_text" | "response_created" | "delayed_after_created";
export const DELAYED_CANCELLATION_MS = 250;

export function delayedCancellationReached(events: Event[], mode: CancelAt): boolean {
  return mode === "delayed_after_created" && events.some(event => event.type === "response.created");
}

export function cancellationReached(events: Event[], mode: CancelAt): boolean {
  if (mode === "response_created") return events.some(event => event.type === "response.created");
  return mode === "first_public_text"
    && events.some(event => event.type === "response.output_text.delta" && typeof event.delta === "string" && event.delta.length > 0);
}

export function assertEarlyCancellation(events: Event[], cancelled: boolean) {
  const created = events.filter(event => event.type === "response.created");
  if (!cancelled || created.length !== 1 || typeof created[0].response?.id !== "string" || !created[0].response.id) {
    throw new Error("Early cancellation did not observe exactly one response start");
  }
  if (events.some(event => event.type === "response.output_text.delta" && event.delta)) {
    throw new Error("Public text arrived before early disconnect; prefill cancellation was not established");
  }
  if (events.some(event => ["response.completed", "response.failed", "response.incomplete"].includes(event.type))) {
    throw new Error("Response ended before early disconnect");
  }
}

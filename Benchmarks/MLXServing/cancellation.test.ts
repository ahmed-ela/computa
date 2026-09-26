import { expect, test } from "bun:test";
import { assertEarlyCancellation, cancellationReached, delayedCancellationReached, DELAYED_CANCELLATION_MS } from "./cancellation";

const created = { type: "response.created", response: { id: "resp_test" } };
const text = { type: "response.output_text.delta", delta: "answer" };

test("early cancellation observes response creation without waiting for model output", () => {
  expect(cancellationReached([{ type: "response.in_progress" }], "response_created")).toBe(false);
  expect(cancellationReached([created], "response_created")).toBe(true);
  expect(cancellationReached([created], "first_public_text")).toBe(false);
  expect(cancellationReached([text], "first_public_text")).toBe(true);
  expect(cancellationReached([created, text], "none")).toBe(false);
  expect(() => assertEarlyCancellation([created], true)).not.toThrow();
});

test("early gate rejects coalesced public text, terminal, absent or duplicate starts", () => {
  for (const events of [[], [created, created], [created, text],
    [created, { type: "response.completed" }], [created, { type: "response.failed" }]]) {
    expect(() => assertEarlyCancellation(events, true)).toThrow();
  }
  expect(() => assertEarlyCancellation([created], false)).toThrow();
  expect(() => assertEarlyCancellation([{ type: "response.created", response: {} }], true)).toThrow();
});

test("delayed probe has its own creation trigger and never requests immediate cancellation", () => {
  expect(DELAYED_CANCELLATION_MS).toBe(250);
  expect(cancellationReached([created], "delayed_after_created")).toBe(false);
  expect(cancellationReached([text], "delayed_after_created")).toBe(false);
  expect(delayedCancellationReached([created], "delayed_after_created")).toBe(true);
  expect(delayedCancellationReached([text], "delayed_after_created")).toBe(false);
  expect(delayedCancellationReached([created], "response_created")).toBe(false);
});

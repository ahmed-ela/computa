import { expect, test } from "bun:test";
import { receiptText } from "./receipt-text";
test("original native snapshot string is preserved", () => {
  const text = "AXSNAPSHOT id=observed\n0 role=AXWindow label=Locked";
  expect(receiptText(text)).toBe(text);
});
test("image-bearing content includes only literal text, never image data", () => {
  expect(receiptText([{ type: "input_text", text: "WINDOW_CAPTURE" },
    { type: "input_image", image_url: "data:image/png;base64,SECRET" }])).toBe("WINDOW_CAPTURE");
  expect(receiptText({ text: "invented" })).toBeNull();
});

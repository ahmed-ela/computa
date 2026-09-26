import { describe, expect, test } from "bun:test";
import { assessResponse, parseOptions } from "./runner-support";

describe("serial perception runner options", () => {
  test("bounded budget and one exact case", () => {
    expect(parseOptions([])).toEqual({ maxOutputTokens: 1024, caseID: null });
    expect(parseOptions(["--max-output-tokens=4096", "--case=host-locked-browser"]))
      .toEqual({ maxOutputTokens: 4096, caseID: "host-locked-browser" });
  });
  test("rejects ambiguous and unbounded options", () => {
    for (const args of [["--max-output-tokens=4097"], ["--max-output-tokens=04096"], ["--case=../x"],
      ["--case=a", "--case=b"], ["--unknown=true"], ["--case", "a"]]) {
      expect(() => parseOptions(args)).toThrow();
    }
  });
});

describe("reasoning censoring is not visual accuracy", () => {
  const expected = { visible: "browser", left: null, right: null };
  const base = { status: "completed", incomplete_details: null, output: [{ type: "reasoning" }],
    usage: { output_tokens: 1023, output_tokens_details: { reasoning_tokens: 1023 } } };
  test("completed with only reasoning at cap is budget censored", () => {
    expect(assessResponse(base, expected, 1024).outcome).toBe("budget_censored");
    expect(assessResponse(base, expected, 1024).valid).toBe(false);
  });
  test("absence below cap is not assumed to be censored", () => {
    expect(assessResponse(base, expected, 4096).outcome).toBe("answer_missing");
  });
  test("valid wrong and valid right answers are perception results", () => {
    const response = (visible: string) => ({ ...base, output: [{ type: "message", role: "assistant",
      content: [{ type: "output_text", text: JSON.stringify({ ...expected, visible }) }] }] });
    expect(assessResponse(response("browser"), expected, 1024).outcome).toBe("correct");
    expect(assessResponse(response("login"), expected, 1024).outcome).toBe("perception_error");
  });
  test("malformed output stays invalid rather than becoming a perception error", () => {
    expect(assessResponse({ ...base, output: [{ type: "message", role: "assistant",
      content: [{ type: "output_text", text: "browser" }] }] }, expected, 1024).outcome).toBe("invalid_answer");
  });
});

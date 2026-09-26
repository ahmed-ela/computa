export function parseOptions(args: string[]) {
  let maxOutputTokens = 1024;
  let caseID: string | null = null;
  const seen = new Set<string>();
  for (const arg of args) {
    const match = /^(--max-output-tokens|--case)=(.+)$/.exec(arg);
    if (!match || seen.has(match[1])) throw new Error("Invalid or repeated benchmark option");
    seen.add(match[1]);
    if (match[1] === "--max-output-tokens") {
      if (!["1024", "2048", "4096"].includes(match[2])) throw new Error("Output budget must be 1024, 2048, or 4096");
      maxOutputTokens = Number(match[2]);
    } else {
      if (!/^[a-z0-9-]+$/.test(match[2])) throw new Error("Invalid case ID");
      caseID = match[2];
    }
  }
  return { maxOutputTokens, caseID };
}

export function assessResponse(result: any, expected: any, maxOutputTokens: number) {
  const text = result.output.filter((m: any) => m.type === "message" && m.role === "assistant")
    .flatMap((m: any) => m.content ?? []).filter((c: any) => c.type === "output_text").map((c: any) => c.text).join("");
  let answer: any = null;
  try { answer = JSON.parse(text); } catch { /* Preserve malformed output separately from perception errors. */ }
  const valid = Boolean(result.status === "completed" && !result.incomplete_details && answer && !Array.isArray(answer)
    && Object.keys(answer).sort().join(",") === "left,right,visible"
    && ["browser", "login", "error", "desktop", "document", "unknown"].includes(answer.visible)
    && [answer.left, answer.right].every(v => v === null || typeof v === "string")
    && result.output.every((m: any) => m.type === "reasoning" || (m.type === "message" && m.role === "assistant")));
  const passed = valid && answer.visible === expected.visible && answer.left === expected.left && answer.right === expected.right;
  const outputTokens = result.usage?.output_tokens;
  const reasoningTokens = result.usage?.output_tokens_details?.reasoning_tokens;
  const reasoningOnly = !text.trim() && result.output.some((m: any) => m.type === "reasoning")
    && result.output.every((m: any) => m.type === "reasoning" || (m.type === "message" && m.role === "assistant"));
  // LM Studio has returned status=completed at the generation ceiling. Keep
  // observed token counts, not that status alone, in the censoring decision.
  const budgetCensored = reasoningOnly && (result.incomplete_details?.reason === "max_output_tokens"
    || (Number.isInteger(outputTokens) && outputTokens >= maxOutputTokens - 1
      && reasoningTokens === outputTokens));
  const outcome = budgetCensored ? "budget_censored" : !text.trim() ? "answer_missing"
    : !valid ? "invalid_answer" : passed ? "correct" : "perception_error";
  return { answer, valid, passed, outcome, reasoningOnly, textCharacters: text.length };
}

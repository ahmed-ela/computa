// The answer contract is a single JSON object whose values are strings or null.
// JSON.parse alone silently overwrites duplicate keys, potentially converting a
// contradictory answer into an exact match. Decode keys before checking them,
// and reject other value types rather than extracting or repairing an answer.
function parseAnswer(text: string): Record<string, string | null> {
  if (text.length > 65_536) throw new Error("answer_too_large");
  let index = 0;
  const skipWhitespace = () => { while (/[\x20\t\r\n]/.test(text[index] ?? "")) index++; };
  const string = (): string => {
    if (text[index] !== '"') throw new Error("expected_string");
    const start = index++;
    while (index < text.length) {
      const character = text[index++];
      if (character === "\\") { index++; continue; }
      if (character === '"') {
        // Native decoding validates control characters and all JSON escapes.
        return JSON.parse(text.slice(start, index));
      }
    }
    throw new Error("unterminated_string");
  };
  const answer: Record<string, string | null> = Object.create(null);
  skipWhitespace();
  if (text[index++] !== "{") throw new Error("expected_object");
  skipWhitespace();
  if (text[index] !== "}") {
    while (true) {
      const key = string();
      if (Object.hasOwn(answer, key)) throw new Error("duplicate_key");
      skipWhitespace();
      if (text[index++] !== ":") throw new Error("expected_colon");
      skipWhitespace();
      if (text[index] === '"') answer[key] = string();
      else if (text.slice(index, index + 4) === "null") { answer[key] = null; index += 4; }
      else throw new Error("expected_string_or_null");
      skipWhitespace();
      if (text[index] === "}") break;
      if (text[index++] !== ",") throw new Error("expected_comma");
      skipWhitespace();
    }
  }
  index++;
  skipWhitespace();
  if (index !== text.length) throw new Error("trailing_content");
  return answer;
}

export function scoreAnswer(text: string, expected: Record<string, string | null>) {
  let answer: Record<string, string | null>;
  try { answer = parseAnswer(text); } catch {
    return { valid: false, exact: false, correct: 0, unsupported: 0, omitted: Object.keys(expected).length, extra: 0 };
  }
  let correct = 0, unsupported = 0, omitted = 0;
  for (const [key, value] of Object.entries(expected)) {
    if (Object.hasOwn(answer, key) && answer[key] === value) correct++;
    else if (!Object.hasOwn(answer, key) || answer[key] === null) omitted++;
    else unsupported++;
  }
  const extra = Object.keys(answer).filter(key => !Object.hasOwn(expected, key)).length;
  return { valid: true, exact: correct === Object.keys(expected).length && extra === 0, correct, unsupported, omitted, extra };
}

import { expect, test } from "bun:test";
import { scoreAnswer } from "./score";
test("strict JSON, no extraction or answer repair", () => {
  expect(scoreAnswer('The answer is {"A":"Paid"}', { A: "Paid" }).valid).toBe(false);
  expect(scoreAnswer('```json\n{"A":"Paid"}\n```', { A: "Paid" }).valid).toBe(false);
  expect(scoreAnswer('[]', { A: "Paid" }).valid).toBe(false);
});
test("separate unsupported associations, omissions, and correct abstentions", () => {
  expect(scoreAnswer('{"A":"Due","B":null,"C":null,"D":"Invented"}', {A:"Paid",B:"Due",C:null}))
    .toEqual({valid:true,exact:false,correct:1,unsupported:1,omitted:1,extra:1});
  expect(scoreAnswer('{"A":"Paid","B":null}', {A:"Paid",B:null}).exact).toBe(true);
  expect(scoreAnswer('{"A":"Paid"}', {A:"Paid",B:null}).exact).toBe(false);
});
test("reject duplicate decoded keys instead of accepting the last association", () => {
  for (const answer of [
    '{"A":"Wrong","A":"Paid"}',
    '{"A":"Paid","A":"Paid"}',
    '{"A":null,"A":"Paid"}',
    '{"A":"Wrong","\\u0041":"Paid"}',
    '{"\\u0041":"Wrong","A":"Paid"}',
    '{"A":"Paid","extra":null,"extra":null}',
  ]) expect(scoreAnswer(answer, {A:"Paid"}).valid).toBe(false);
});
test("reject nonprimitive values and malformed JSON without extracting an answer", () => {
  for (const answer of [
    '{"A":1}', '{"A":true}', '{"A":[]}', '{"A":{"value":"Paid"}}',
    '{"A":"Paid",}', '{"A":"Paid"}{}', '{"A":"Paid"', '{"A":nullx}',
    '{"A":"bad\\q"}', '{"A":"bad\nline"}', '{"A":"bad\\u00ZZ"}',
    '{"A":"Paid","extra":false}', '\u00a0{"A":"Paid"}',
  ]) expect(scoreAnswer(answer, {A:"Paid"}).valid).toBe(false);
});
test("decode escaped names and values exactly without normalizing them", () => {
  expect(scoreAnswer(' \t\r\n{ "\\u0041" : "P\\u0061id", "B": null }\n', {A:"Paid",B:null}).exact).toBe(true);
  const expected = {'quoted"key':'backslash\\ then "quote" and \nnewline', '\u2603':'\ud83d\ude80'};
  expect(scoreAnswer(JSON.stringify(expected), expected).exact).toBe(true);
  expect(scoreAnswer('{"A":" Paid "}', {A:"Paid"}).unsupported).toBe(1);
});
test("prototype-like keys remain ordinary own answer fields", () => {
  const expected = JSON.parse('{"__proto__":"Observed","constructor":null}');
  expect(scoreAnswer('{"__proto__":"Observed","constructor":null}', expected).exact).toBe(true);
  expect(scoreAnswer('{"__proto__":"Wrong","__proto__":"Observed"}', expected).valid).toBe(false);
});
test("bound answer parsing and keep empty objects as omissions", () => {
  expect(scoreAnswer('{"A":"' + 'x'.repeat(65_536) + '"}', {A:"Paid"}).valid).toBe(false);
  expect(scoreAnswer('{}', {A:"Paid"})).toEqual({valid:true,exact:false,correct:0,unsupported:0,omitted:1,extra:0});
});

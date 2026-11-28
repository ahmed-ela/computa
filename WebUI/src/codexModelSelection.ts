export type CodexModelState = {current: string | null; live: boolean};
export type CodexModelIntent =
  | {kind: 'follow'}
  | {kind: 'next'; model: string; expected: string | null};

export function codexModelReady(intent: CodexModelIntent, state?: CodexModelState): boolean {
  if (!state) return false;
  return intent.kind === 'follow' || state.current === intent.expected;
}

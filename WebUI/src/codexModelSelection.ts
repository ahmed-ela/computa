export type CodexModelState = {current: string | null; live: boolean};
export type CodexModelIntent =
  | {kind: 'follow'}
  | {kind: 'switching' | 'handoff' | 'unconfirmed' | 'bound'; model: string};

export function observeCodexModel(intent: CodexModelIntent, state: CodexModelState): CodexModelIntent {
  if ((intent.kind === 'handoff' || intent.kind === 'unconfirmed') && state.live && state.current === intent.model) {
    return {kind:'bound', model:intent.model};
  }
  return intent;
}

export function codexModelReady(intent: CodexModelIntent, state?: CodexModelState): boolean {
  return intent.kind === 'follow' || (intent.kind === 'bound' && state?.live === true && state.current === intent.model);
}

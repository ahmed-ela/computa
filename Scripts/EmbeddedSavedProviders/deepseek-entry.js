// Workspace composition only. Native has no mode-selection proof case yet.
try {
  const actions = ['inspect', 'discoverModes', 'selectMode', 'verifyMode', 'prepare', 'insert', 'sendReady', 'submit', 'stop',
    'deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
  const c = computaProviderCore(input, 'deepseek', 'https://chat.deepseek.com', actions);
  return await computaSavedConversation(input, c, computaDeepSeekDOM(c), {
    stateKey: '__computaDeepSeekSavedSessionV1', origin: 'https://chat.deepseek.com', selectionKind: 'mode', initialModeHandoff: true
  });
} catch (error) {
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}

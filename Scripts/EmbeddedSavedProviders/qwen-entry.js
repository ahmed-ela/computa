// Standalone composition; native catalog admission is separate from this adapter.
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'verifyModel', 'prepare', 'insert', 'sendReady', 'submit', 'stop',
    'deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
  const c = computaProviderCore(input, 'qwen', 'https://chat.qwen.ai', actions);
  return await computaSavedConversation(input, c, computaQwenDOM(c), {
    stateKey: '__computaQwenSavedSessionV1', origin: 'https://chat.qwen.ai', initialProvisionalRoute: true, initialResponseIdentity: true,
    firstEmptyContainerChoice: { key: 'Qwen3.8-Max', label: 'Qwen3.8-Max' },
    deferDisplayUntilAnswer: ['Qwen3.7-Plus', 'Qwen3.8-Max'].map(label => ({ key: label, label }))
  });
} catch (error) {
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}

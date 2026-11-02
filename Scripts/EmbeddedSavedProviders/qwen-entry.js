// Standalone composition; not registered or exposed by the native catalog yet.
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'verifyModel', 'prepare', 'insert', 'sendReady', 'submit', 'stop',
    'deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
  const c = computaProviderCore(input, 'qwen', 'https://chat.qwen.ai', actions);
  return await computaSavedConversation(input, c, computaQwenDOM(c), {
    stateKey: '__computaQwenSavedSessionV1', origin: 'https://chat.qwen.ai'
  });
} catch (error) {
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}

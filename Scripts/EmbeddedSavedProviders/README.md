# Saved-conversation website adapters

These sources compose Qwen and DeepSeek's standalone WebKit resources. The
common engine owns submission and deletion claims, exact first-message binding,
route checks, and initial readiness. Each DOM driver supplies observed website
controls and response structure. DeepSeek's Chat/DeepThink selection proves a
website mode with Search off; it does not identify a backend model.

Edit the common engine or the relevant DOM/entry source here, then regenerate:

```sh
bun Scripts/embedded-saved-provider-resources.ts --write
bun Scripts/embedded-saved-provider-resources.ts --check
bun test Scripts/embedded-saved-provider-resources.test.ts Scripts/embedded-saved-initial-readiness.test.ts Scripts/embedded-qwen-dom.test.ts Scripts/embedded-qwen-adapter.test.ts Scripts/embedded-deepseek-dom.test.ts Scripts/embedded-deepseek-adapter.test.ts
```

The generator resolves all paths relative to its own file and validates syntax
without executing an adapter. Its default is `--check`; only `--write` changes
the two generated resources. Both include the exact shared prefix from
`Scripts/embedded-provider-core.js`. Kimi and Groq retain their existing adapter
bodies and are outside this generator's write scope.

The fixtures use synthetic IDs, prompts and answers. They exercise selector,
ownership, asynchronous readiness, response-source rejection and once-only
cleanup behavior. They do not establish live website reliability. In particular,
DeepSeek's final-control observation still needs a live streaming-negative
comparison. Native and installed-app gates remain separate, and these sources
do not enable either provider in the public catalog.

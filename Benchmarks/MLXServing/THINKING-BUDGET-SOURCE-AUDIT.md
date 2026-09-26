# Installed MLX-VLM thinking-budget path

Read-only source audit, 2026-09-25. This is **not a live inference result**. No
package, environment, model weights or serving process was modified for this
inspection.

The installed `mlx-vlm` 0.7.1 package under the existing VisualGrounding virtual
environment does carry `MLX_VLM_THINKING_BUDGET` into the continuous-batching
path. It is not merely a CLI argument which batching drops:

1. `server/generation.py:221` reads the environment default.
2. `server/request_normalization.py:233` places the request field or default in
   `GenerationArguments.thinking_budget`.
3. `server/generation.py:1170` creates a per-request `ThinkingBudgetCriteria`,
   and `:1556` resolves the start/end tokens plus whether the prompt already
   opened the thinking section.
4. `server/generation.py:1814` passes the criteria into `batch_gen.insert`.
5. `generate/ar.py:1446` invokes it per generated token and reads the forced
   next-token ID; the batch sampler substitutes that ID.
6. `utils.py:2737` triggers when the thinking count is **greater than** the
   budget, then forces a newline and the closing-thinking token in sequence.

Thus a budget of 512 is a forced thinking-section closure with a small token
overshoot, **not** a strict 512 total-output-token limit or guarantee of an
accurate/public answer. The total generation allowance still applies. Explicit
`thinking_budget` in a request takes precedence over the environment default;
the owned request boundary must reject or constrain overrides if 512 is a
runtime invariant. Disabling reasoning changes this path's applicability.

The live guarded-server gates must still prove that this particular Qwen
processor's thinking tokens are correctly detected and that public output
arrives. Static wiring alone cannot establish task quality or latency.

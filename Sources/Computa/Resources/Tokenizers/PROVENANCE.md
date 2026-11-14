# OpenAI ordinary-text tokenization data

`o200k_base.tiktoken` is the unchanged official OpenAI mergeable-rank table used
by `o200k_base` and `o200k_harmony`. The app uses ordinary-text tokenization;
literal special-token strings remain ordinary text. It does not add Harmony
message framing or predict website-injected text or output-token reservations.

- Source: https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken
- SHA-256: `446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d`
- Bytes: 3,613,922
- Reference implementation: OpenAI `tiktoken` 0.12.0, `tiktoken_ext/openai_public.py`
- Reference: https://github.com/openai/tiktoken/blob/0.12.0/tiktoken_ext/openai_public.py
- The adjacent LICENSE is copied from that pinned official wheel (MIT).

The resource was copied from an existing verified local cache; app startup
never downloads it. Its exact hash, row count, rank order, unique byte sequences
and complete single-byte coverage are checked before use. Swift implements
adjacent byte-pair merges with a bounded input and a minimum-priority queue.
Parity fixtures are generated offline using `o200k_harmony.encode_ordinary`
from the pinned implementation, with no provider requests.

`o200k_unicode_categories.json` is a compact reference for the six disjoint
Unicode category classes used by that pattern. It was generated offline by
calling the same pinned **Rust CoreBPE** kernel with a complete single-byte
vocabulary and each category-only regex over every valid Unicode scalar. The
returned bytes identify exactly the kernel's matched scalars; Python's `regex`
Unicode tables are not used as an authority.

- SHA-256: `86f2980973d70d7be8458a22ae8961633d353f77a6f6a548cdb5ea10eebaf282`
- Bytes: 35,159; nonoverlapping scalar ranges: 2,363
- The eight contraction case-fold sets were derived through the same kernel
  over all valid scalars. They are ASCII pairs plus `S`, `s`, `ſ` for `s`.
  The Swift pattern spells these sets explicitly instead of relying on ICU's
  case-insensitive matching version.

ICU may assign a new script or formerly unassigned scalar to a different
category than the pinned kernel. Before counting non-ASCII text, the counter
compares ICU's six category spans against this reference. A mismatch produces
`unicodeCategoryMismatch`, not a token estimate. Common multilingual text and
new-script boundaries are covered by the checked-in offline parity corpus.
This is a pinned, tested body tokenizer, not a claim that every provider/model
uses these ranks or that every future ICU version is equivalent. The 256 KiB
UTF-8 input bound, bounded resource reads and uncached heap-based merges also
apply to adversarial text; rejected inputs are never truncated.


# Qwen3.8-27B ordinary-text tokenization data

`qwen38_27b.bpe` contains the exact ordered merge pairs and initial byte-token
IDs derived from Qwen's tokenizer. It is used only for Groq's exact concrete
model ID `qwen/qwen3.8-27b`; GPT-OSS keeps its existing counter and unrecognized
models keep conservative byte admission. No account limit is inferred from a
model's context window. The existing 6,000-body-token limit and 2,000-token
website/output reserve are unchanged.

- Official model binding: https://console.groq.com/docs/model/qwen/qwen3.8-27b
- Published API rate summary: https://console.groq.com/docs/rate-limits (8K free-tier
  TPM for this model; account-specific and website accounting can differ).
- Source: https://huggingface.co/Qwen/Qwen3.8-27B/resolve/366a23fd246985933964e9d21ac63eb3a93190ab/tokenizer.json
- Upstream tokenizer SHA-256: `0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3`
- Derived merge bytes: 2,972,084; SHA-256: `aa63aeccd2e3fb859f833668cab09e4dded9727ac39e2ba3f61473ab82c5c5d3`
- Vocabulary entries: 248,044; ordered merge rules: 247,587.
- The adjacent `LICENSE.Qwen` is the upstream Apache 2.0 license.

Qwen uses NFC normalization, its own Unicode pretokenizer, and ranked-pair BPE.
Counting follows that normalization without modifying the outgoing prompt.
Literal added-special-token spellings remain ordinary text; no chat template or
hidden website framing is included. The merge table must retain both operands:
some rules refer to later-ranked products, and a concatenated-vocabulary
approximation is not interchangeable with these pair rules. Ties select the
leftmost pair, and every newly adjacent pair is reconsidered.

`qwen38_unicode_categories.json` records four Unicode classes from pinned
Hugging Face `tokenizers` 0.22.1 (its Rust/Oniguruma implementation), using every
valid Unicode scalar. SHA-256: `d8e75a39fcbe309c6ea801446570b8a80b0067a14945e0c5d30d868cb1dcdac9`;
17,798 bytes and 1,152 disjoint ranges. A current ICU category disagreement
fails closed. Case-folded contraction letters are explicit. NFC and token-count
parity cover decomposed text, multilingual input, whitespace, controls, literal
special-token spellings, deterministic randomized strings and merge samples.

`Scripts/generate-qwen-body-token-fixtures.py --tokenizer-json PATH` regenerates
the merge table, categories and 598 public parity fixtures offline from that
exact source file and reference-library version. It performs no downloads.
Resources are bundled, hash-checked and bounded before use; startup performs no
network request. User input and results are not cached. Unknown or corrupted
resources, unsupported Unicode categories, cancellation or oversized input do
not return an estimated count. This is local ordinary-text admission, not proof
of provider-side token accounting or an account-wide quota guarantee.

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

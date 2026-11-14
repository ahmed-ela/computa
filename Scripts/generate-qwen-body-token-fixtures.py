"""Offline derived resources from the hash-pinned Qwen tokenizer, no network."""
import argparse, hashlib, json, random, struct
import tokenizers
assert tokenizers.__version__ == "0.22.1", "Use the pinned reference tokenizer version"
from pathlib import Path
from tokenizers import Tokenizer, Regex
from tokenizers.pre_tokenizers import Split

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tokenizer-json', type=Path, required=True)
args = parser.parse_args()
raw = args.tokenizer_json.read_bytes()
assert hashlib.sha256(raw).hexdigest() == '0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3'
doc = json.loads(raw)
assert doc['normalizer'] == {'type': 'NFC'}
assert doc['model']['type'] == 'BPE' and doc['model']['dropout'] is None
assert not doc['model']['byte_fallback'] and not doc['model']['ignore_merges']
model = doc['model']; vocab = model['vocab']; merges = model['merges']
byte_values = list(range(33, 127)) + list(range(161, 173)) + list(range(174, 256))
unicode_values = byte_values[:]
for byte in range(256):
    if byte not in byte_values:
        byte_values.append(byte); unicode_values.append(256 + len(unicode_values) - 188)
# ByteLevel uses the standard GPT-2 reversible byte alphabet.
assert len(byte_values) == len(set(byte_values)) == 256
mapping = dict(zip(byte_values, map(chr, unicode_values)))
initial = [vocab[mapping[byte]] for byte in range(256)]
assert len(set(initial)) == 256
records = []; available = set(initial); pairs = set()
for left, right in [x.split(' ') if isinstance(x, str) else x for x in merges]:
    a, b, output = vocab[left], vocab[right], vocab[left + right]
    # Some upstream merge operands are produced by later-ranked rules. Preserve
    # the exact pair table; do not impose a tiktoken-style vocabulary ordering.
    assert 0 <= a < len(vocab) and 0 <= b < len(vocab) and output not in available and (a, b) not in pairs
    pairs.add((a, b)); available.add(output); records.append((a, b, output))
data = b'CQWBPE1\0' + struct.pack('<II', len(vocab), len(records))
data += struct.pack('<256I', *initial)
data += b''.join(struct.pack('<III', *row) for row in records)
resources = ROOT / 'Sources/Computa/Resources/Tokenizers'
(resources / 'qwen38_27b.bpe').write_bytes(data)

# Obtain Unicode classes from the pinned HF Rust/Oniguruma implementation,
# never from Python regex or the current macOS ICU as its own reference.
scalars = [x for x in range(0x110000) if not 0xD800 <= x <= 0xDFFF]
all_text = ''.join(map(chr, scalars)); classes = bytearray(len(scalars))
patterns = [r'\p{L}+', r'\p{M}+', r'\p{N}+', r'\s+']
for category, pattern in enumerate(patterns, 1):
    for _, (start, end) in Split(Regex(pattern), 'removed', invert=True).pre_tokenize_str(all_text):
        assert not any(classes[start:end])
        classes[start:end] = bytes([category]) * (end - start)
ranges = []
for scalar, category in zip(scalars, classes):
    if category:
        if ranges and ranges[-1][1] + 1 == scalar and ranges[-1][2] == category:
            ranges[-1][1] = scalar
        else: ranges.append([scalar, scalar, category])
unicode_data = json.dumps({'schemaVersion': 1, 'patterns': patterns, 'ranges': ranges}, separators=(',', ':')).encode()
(resources / 'qwen38_unicode_categories.json').write_bytes(unicode_data)

# Count ordinary body text, matching the existing GPT-OSS policy: added special
# strings are ordinary text; no role framing or template is inserted.
ordinary = json.loads(raw); ordinary['added_tokens'] = []
counter = Tokenizer.from_str(json.dumps(ordinary))
texts = ['', 'hi', 'Hello world!', '1–4 unique inventory names', 'é e\u0301 Å A\u030a',
         'العربية 中文 日本語 हिन्दी', '👩🏽\u200d💻 🧭 🇺🇸', '<|im_start|>user\nhi<|im_end|>',
         '\r\n\n\t  ', "'s 'S 'ſ 't 'RE 've 'll 'd", 'a\u0344b\u0f73',
         '\u0000\u0001\u007f\u0085', '1234567890' * 150, 'x' * 4096,
         ' ' * 8192, '\n' * 4096, '\u0301' * 500]
random.seed(399)
alphabet = 'abcXYZ123 \t\n{}[]:"\\😀é\u0301中文العربيةſ'
texts += [''.join(random.choice(alphabet) for _ in range(n)) for n in range(1, 600, 7)]
# Exercise every merge product as isolated text where it decodes to UTF-8.
inverse = {v: k for k, v in mapping.items()}
merge_samples = []
for index in range(0, len(merges), 499):
    pair = merges[index].split(' ') if isinstance(merges[index], str) else merges[index]
    try: merge_samples.append(bytes(inverse[c] for c in ''.join(pair)).decode('utf-8'))
    except UnicodeDecodeError: pass
texts += merge_samples
parity = {'schemaVersion': 1, 'reference': 'tokenizers 0.22.1; Qwen3.8-27B pinned tokenizer; ordinary text',
          'rows': [{'text': text, 'count': len(counter.encode(text, add_special_tokens=False).ids),
                    'nfc': counter.normalizer.normalize_str(text)} for text in texts]}
fixtures = ROOT / 'Tests/Fixtures'; fixtures.mkdir(exist_ok=True, parents=True)
(fixtures / 'QwenBodyTokenParity.json').write_text(json.dumps(parity, ensure_ascii=False, indent=2) + '\n')
manifest = {'upstreamSHA256': hashlib.sha256(raw).hexdigest(), 'model': 'Qwen/Qwen3.8-27B',
            'revision': '366a23fd246985933964e9d21ac63eb3a93190ab', 'vocabularyCount': len(vocab),
            'mergeCount': len(records), 'unicodeRanges': len(ranges), 'parityCases': len(texts),
            'files': {f.name: {'bytes': f.stat().st_size, 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()}
                      for f in [resources / 'qwen38_27b.bpe', resources / 'qwen38_unicode_categories.json', fixtures / 'QwenBodyTokenParity.json']}}
print(json.dumps(manifest, indent=2))

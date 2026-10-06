The Rust tensor architectures follow the MIT-licensed MLX-VLM implementations:
- https://github.com/Blaizzy/mlx-vlm/tree/main/mlx_vlm/models/florence2
- https://github.com/Blaizzy/mlx-vlm/tree/main/mlx_vlm/models/qwen2_vl
- https://github.com/Blaizzy/mlx-vlm/tree/main/mlx_vlm/models/qwen3_vl

Model source revisions and converted artifact SHA-256 identities are frozen in
model-manifest.json, copied byte-for-byte from Computa's baseline manifest.

owl-system.txt freezes the baseline's task-independent GUI-Owl native prompt and
capability overlay, preserving JSON field insertion order and whitespace. Its
SHA-256 is adefe76b20adbedf89cf8d96cab0a91a0c870ae9ef736770e161861d730ae607.
The baseline protocol source SHA-256 was
3866f875eb654442a751b73f55a3a119f63ff2621de6b7b411789830a5c18bf4.
Publisher prompt provenance:
https://github.com/X-PLUG/MobileAgent/blob/11cea575561fb7800b5fb6b6cafa56f7a91de11f/Mobile-Agent-v3.5/computer_use/utils.py

Image RGB bicubic preparation follows Pillow's separable antialiased resampler,
including 22-bit fixed-point coefficient rounding and clipping after each pass.
https://github.com/python-pillow/Pillow/blob/main/src/libImaging/Resample.c

No Python source, interpreter or remotely supplied model code is executed by
these modules. All weight loading uses local, verified files. Full-weight
numerical/output qualification requires the pinned converted artifacts; small
synthetic architecture tests do not establish real model quality.

florence-fixtures.json freezes synthetic outputs from the locally installed
MLX-VLM Florence2 spatial/channel DaViT blocks and BART encoder/cached decoder.
It records the package version and SHA-256 of its three reference source files.
Rust tests load these numerical fixtures without invoking a Python interpreter.
The padded spatial grid covers window partitioning, while two decoder steps
cover both self-attention accumulation and cached encoder cross-attention.

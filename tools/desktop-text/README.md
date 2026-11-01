# Local language and entity worker

This layer implements the non-generative text-analysis backend. It identifies
language with the fixed fastText `lid.176.ftz` classifier, distinguishes Chinese
writing forms using pinned OpenCC character sets, and optionally runs a fixed
multilingual BERT entity model. It emits original person/organization/place
spans, never generated or translated names. Application actions, model
installation and automatic/progress/retry integration remain dependent work.

The compact language model and unchanged original Google BERT vocabulary are
bundled next to the helper. Their exact sizes/SHA256 are verified before use.
Entity weights stay separate: the optional definition in
`Core/Sources/ClipboardCore/Resources/DesktopLocalEntityModel.json` fixes the
ONNX Community artifact, immutable revision, publisher LFS digest and AFL-3.0
license. User installation must present that license and obtain acceptance;
the definition records this requirement. No application download or acceptance
flow is implemented or implicitly enabled by this backend layer.

Build on Linux x64/arm64 or Windows x64 with CMake 3.22+, C/C++17 and Python:

```sh
python tools/desktop-text/build-worker.py --output build/text-worker --cache build/text-sdk
```

Normal builds download only public build/language/tokenizer resources and
attribution. An explicit development/CI flag downloads entity test weights to
the content-addressed cache and exercises the actual model:

```sh
python tools/desktop-text/build-worker.py --output build/text-worker --cache build/text-sdk --download-test-model
```

The builder never copies entity weights into its output or an application.
It retains complete fastText, language-model, OpenCC, tokenizer, BERT, entity
model/converter, Unicode/SHA256 and ONNX Runtime notices and provenance.
Language model bytes are unchanged and retain CC-BY-SA-3.0 attribution; the
original vocabulary is byte-identical to the entity model's vocabulary and
comes from the Apache-2.0 Google BERT distribution.

The worker takes exactly `text`, `task` and `model` through private JSON pipes.
`task` must be `enrichment`; `model: null` runs language identification alone.
Paths/content never enter worker arguments or diagnostics. Model input is a
fixed-size/digest verified in-memory buffer, without runtime external model
files, custom operators, GPU providers or telemetry. Small bundled resources
resolve from the actual executable, independently of the working directory.
Local regular files, final-handle validation and digest checks reject alternate
files, links, FIFOs and corrupted resources. Parent cancellation kills/reaps
only the owned worker. Native limits are 2 GiB, 15 CPU seconds, 512 BERT tokens,
two inference threads and a 20-second parent wall deadline.

Cased BERT normalization/WordPiece preserve original UTF-8 offsets and treat
literal special-token text as ordinary input. Fourteen committed vectors come
from the independent Hugging Face tokenizer 0.22.1 with the pinned tokenizer
JSON; they cover CJK/Korean, accents, controls, private/rare characters, literal
special tokens, unknown words and truncation. `tokenizer-reference-check` is a
test-only executable and must never be packaged.

The actual model has a nine-class head, including DATE labels not described in
the older model card. The runtime validates that exact class map and emits
only PER/ORG/LOC at confidence 0.7 or above, at most five source spans. It omits
incomplete final names after token truncation. Core independently validates
metadata/grounding and localizes the language name. A missing/unknown language
or absent entity output retains the established bounded text fallback; that
fallback does not claim an entity was recognized.

`check-worker.py` checks all tokenizer vectors, seven language/writing-form
fixtures, refusal/tamper cases and optional real entities. The Swift fixture
uses explicit `CLIPBOARD_TEST_TEXT_WORKER` and `CLIPBOARD_TEST_ENTITY_MODEL`
paths to test the complete private-pipe adapter. Default unit tests skip that
real-model fixture; native Core CI explicitly configures and runs it.
All fixtures use synthetic content. These checks establish implementation
behavior, not identical accuracy to Apple's NaturalLanguage models.

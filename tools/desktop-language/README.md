# Offline language worker

This layer adds the portable service contract, a CPU-only llama.cpp worker and
its Swift private-pipe adapter. It does not enable a new application action or
download weights on startup. Explicit model installation, dedicated trained
language/entity tagging and UI/automatic scheduling are dependent work. The
existing desktop excerpt action keeps its current meaning.

`Core/Sources/ClipboardCore/Resources/DesktopLocalLanguageModel.json` is the
single model definition. It fixes the publisher repository, immutable revision,
filename, byte count, SHA256, license and model-card URLs. `upstream.json` fixes
the SDK archive and attribution notices. The SDK archive digest is independently
computed over the official pinned source archive, not a release signature.

The selected weights are Unsloth's Q4_K_M GGUF quantization of
[Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507),
not an official Qwen GGUF release. Verification matches the quantizer's fixed
LFS digest; it does not assert equivalence to the original full-precision
weights. Both the original-model and quantizer cards are retained alongside
the complete Apache-2.0 license.

Build on native Linux x64/arm64 or Windows x64 with CMake 3.22+, a C/C++17 compiler and Python:

```sh
python tools/desktop-language/build-worker.py --output build/language-worker --cache build/language-sdk
```

Normal builds obtain only SDK sources/notices. To explicitly download public
test weights into the development cache and run real inference checks:

```sh
python tools/desktop-language/build-worker.py --output build/language-worker --cache build/language-sdk --download-test-model
python tools/desktop-language/check-quality.py --executable build/language-worker/clipboard-language-worker --model build/language-sdk/FIRST_16_SHA256_CHARACTERS-MODEL_FILENAME_FROM_MANIFEST --output build/language-quality.json
```

Windows uses `clipboard-language-worker.exe`. Each cached download name starts
with the first 16 characters of its pinned SHA256, followed by `-` and its filename;
changing revisions cannot accidentally reuse a different notice/model file.
Weights are never copied into
the output directory or an application package. Cached artifacts are streamed
through the same size/digest verification on every build; the verified archive
also restores changed SDK files without invalidating unchanged build inputs.
The output includes SDK, model and dependency attribution and provenance.

Requests contain a local model path, bounded text, task and response language
only through an owned private pipe. There is no server, subprocess tool use,
GPU backend, dynamic backend loading or HTTP client in the worker. Content and
paths never enter process arguments or diagnostics. The worker verifies the
model's type/size/SHA256 using the same open file passed into the SDK. Source
text is tokenized without interpreting model control tokens. Context, output,
thread count, process memory, CPU time and parent wall time are bounded. Core
refuses sensitive/concealed items before reading payloads or copied files;
file summaries receive only the first extracted body, without filenames.

`check-worker.py` checks the real binary's protocol, rejection paths, Unicode
model paths and one actual summary. The Swift integration test runs real
inference only with explicit `CLIPBOARD_TEST_LANGUAGE_WORKER` and
`CLIPBOARD_TEST_LANGUAGE_MODEL` fixture paths. Separate pipe tests cover
cancellation, timeout, Unicode requests and response-task mismatch. The native
Windows/Linux Core CI step configures the real fixture rather than relying on
the default skipped integration test.

`check-quality.py` uses committed synthetic fixtures and saves only their
generated sentences for review. Its concept checks catch known language and
main-event regressions; a passing keyword check does not prove factual accuracy.
Review the saved sentences against the fixtures, including newly added facts.
The smaller 0.6B/1.7B candidates produced fabricated/common-noun entities and
incorrect multilingual summaries. Generative entity extraction is therefore
excluded; it is not a substitute for a trained tagger or the Mac baseline.

Native verification failures report a fixed check stage, completed-check count,
optional worker exit code and stderr byte count only. Worker exit stages 3/6/7/
8/9/10 identify resource limits, model open, digest, SDK load, generation and
serialization; malformed requests still fail without content diagnostics. No
model path, input text, generated text or network exception enters this report.
Windows CMake cache values use forward slashes so drive paths cannot become
CMake string escapes. Linux x64 failure in run 41255422473 requires the new
stage evidence before a specific inference repair can be claimed.

The optional x64 generative worker requires AVX2, FMA, F16C and OS-managed
XMM/YMM state. Its baseline-ISA entry point checks CPU/OS support before SDK
initialization and returns fixed exit 11 on unsupported processors. The main
application and language/entity baseline do not acquire this requirement.
GGML x64 kernels use those fixed features, with host-native flags, AVX512,
dynamic backends and GPU acceleration still disabled. ARM64 keeps its existing
kernel configuration. A small native CPU-feature regression covers each missing
feature/state bit. The original scalar-only x64 build hit SIGXCPU in native CI;
the 4 GiB, 120-second CPU and 90-second parent limits remain unchanged. Native
x64 timing and multilingual quality must pass before accepting this candidate.

The x64 feature guard also checks the associated BMI1/BMI2, POPCNT, LZCNT,
MOVBE and SSE feature bits, since [MSVC /arch:AVX2](https://learn.microsoft.com/en-us/cpp/build/reference/arch-x64)
can emit associated scalar instructions as well as vector instructions. No
AVX2 compilation flag is applied to the entry point or capability check.

Linux x64 CI additionally runs `check-cpu-guard.py` through QEMU's Nehalem CPU
profile and requires exit 11 with empty output before opening any model. This
checks the linked executable's startup path, including static initializers;
it is emulated evidence, not physical older-CPU acceptance.

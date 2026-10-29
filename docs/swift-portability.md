# Swift core portability experiment

Date: 2026-10-29 (Asia/Shanghai). Base: `b4ac516`. Branch: `codex/verify-swift-cross-platform`.

## Finding

The existing Swift business core can run on Linux after isolating Apple-only
implementations and supplying portable hashing and logging backends. Rewriting
business logic in Rust is not a prerequisite. This experiment does not establish
Windows support or deliver a Windows/Linux desktop application.

## Evidence

| Check | Environment | Result |
| --- | --- | --- |
| Original source obstruction | Linux arm64, Swift 6.1.3 | Original WorkspaceProvider fails with `no such module 'AppKit'` |
| Original Core baseline | macOS arm64, Swift 6.4 | 150 tests, 1 existing Keychain skip, zero failures |
| Modified Core | macOS arm64, Swift 6.4 | 153 tests, 1 existing Keychain skip, zero failures |
| Modified Core | Ubuntu 22.04 arm64 container, Swift 6.1.3 | 133 tests, zero failures |
| Complete macOS application | Local Xcode, Debug | Build succeeded; application was not launched |
| Synthetic rich-types scenario | macOS and Linux arm64 | Five checks passed on each platform |
| Windows | No Windows runner available locally | Not executed; branch-scoped workflow prepared |

Linux's test total is intentionally smaller: seven test files containing 23
Apple-specific tests are compiled only on macOS. Linux runs 127 existing core
tests plus six portability tests; macOS runs the original 150 plus three shared
portability tests. The Linux run does not use replacement fake implementations
of the real store, blob storage, filtering, hashing, or search.

The suite covers JSON/blob round trips, deduplication, searching, capacity,
pinning, import, corruption recovery and sensitive-item exclusion from disk.
New checks cover standard SHA-256 vectors, Unicode/space-containing storage
paths and repeated flushes, the Foundation-only writer contract, rich-text
payload preservation without a decoder, and private-by-default log interpolation.

## Minimal changes

- Keep the existing `ClipboardCore` target and its actual sources; no rewritten
  copy of the business core or final module split is introduced.
- Guard the macOS clipboard, hotkey, credentials, image encoder implementations
  and their platform-specific tests with `#if os(macOS)`.
- Declare `PasteboardWriting` and its errors independently of AppKit. Keep the
  `WorkspaceProvider` protocol and stub available on all tested platforms.
- Link KeyboardShortcuts only for macOS. Use CryptoKit on macOS and the pinned
  official `swift-crypto` 3.12.3 package's `Crypto` product on Linux/Windows.
- Retain OSLog on macOS. Supply a validation-only stderr backend elsewhere;
  interpolated values are redacted unless explicitly public.
- Preserve RTF/HTML payload bytes on Linux. When no plain-text sidecar is present,
  the preview remains empty until a platform decoder is implemented. This is an
  explicit functionality gap, not equivalent rich-text preview support.

The model still uses Apple UTI strings and source bundle identifiers. A future
platform adapter must normalize native formats and supply platform source IDs.
Sensitive-item persistence tests accept an already marked `RawClipItem`; they
**do not prove native sensitive-content detection on Windows or Linux**.

## Reproduce

On macOS, Linux, or Windows with Swift installed, from the repository root:

```sh
swift --version
swift test --package-path Core
swift run --package-path Core scenario-runner rich-types
```

On macOS, also build the existing application:

```sh
just build
```

Linux container reproduction (POSIX shell, source mounted read-only):

```sh
docker run --rm \
  --mount "type=bind,source=$PWD,target=/workspace,readonly" \
  --workdir /workspace \
  swift@sha256:0a58f05d6c3d3ab48d3cc6f72202fce9bdda52f79f1f6e581c018fa70a590c67 \
  bash -lc '
    set -euo pipefail
    mkdir -p /tmp/clipboard-core
    tar -C /workspace/Core --exclude=.build --exclude=.swiftpm -cf - . |
      tar -C /tmp/clipboard-core -xf -
    swift test --package-path /tmp/clipboard-core
    swift run --package-path /tmp/clipboard-core scenario-runner rich-types
  '
```

The tested image is `swift:6.1.3-jammy` on arm64. This is not a Linux x86_64
result. Host tests used Swift 6.4 on macOS 27.0.1. No oldest-macOS runtime test
was performed.

The GitHub Actions workflow, `.github/workflows/swift-portability.yml`,
runs only on pushes of `codex/verify-swift-cross-platform` (or manual dispatch
after GitHub registers the workflow on the default branch). It prepares Ubuntu
22.04 and Windows Server 2022 x64 with Swift 6.1.3, runs Core
unit tests and the synthetic scenario, and uploads xUnit results. Only Core and
workflow changes trigger push runs; report-only updates do not rerun tests.
The first remote run is pending; its Windows job and toolchain installation
are not yet verified. A native Windows
Swift installation can execute the same three commands directly. No Windows
build success is claimed before that run finishes.

The container copies package sources into disposable storage before building.
This permits SwiftPM to maintain its lockfile without writing to the host. Xcode
can add its app-level Sparkle pin to `Core/Package.resolved`; the saved Core
lockfile contains only Core dependencies.

The lockfile resolves transitive `swift-asn1` 1.7.3 (tools version 6.1). The
experiment therefore uses Swift 6.1+; compatibility with the project's original
Swift 5.9 toolchain requires a separate dependency-resolution check before merge.
The pinned crypto version is an experiment dependency, not a final dependency
policy.

Full local command logs are retained under ignored `build/portability/` in the
worktree. They contain test fixtures rather than the user's clipboard history.

## Remaining work

1. Run the prepared tests on native Windows and handle any compiler/Foundation
   differences. This is the next portability gate.
2. Split Apple adapters into a separate target if the experiment is adopted;
   make hotkey interfaces independent of KeyboardShortcuts types.
3. Implement native clipboard capture/writeback and validate native format,
   source-app and sensitivity metadata. Preserve the existing no-automatic-paste
   and sensitive-memory-only rules.
4. Select a UI and implement tray, focus/input-method behavior, hotkeys,
   credential storage, startup, OCR and distribution for each platform.
5. Test Linux X11 and specific Wayland desktop environments separately. A
   headless core container test makes no claim about desktop integration.

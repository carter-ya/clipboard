# Mac-aligned desktop interface

The Windows/Linux GTK application follows the approved Mac layout with a 760 × 520 preferred window, a 56% history column and 7 logical pixels of row padding. The existing macOS application is unchanged.

## Behavior

- Search and recording/hide/settings controls sit above a persistent left-list/right-preview layout. The list and preview scroll independently. Image height follows the mapped window height with space reserved for metadata and controls; it has no fixed upper cap.
- All/Pinned and all six content filters retain their existing counts and behavior. Type controls use two rows below 1200 logical pixels to keep translated names readable. Source filtering remains available through the filter button.
- Copy, pin, delete and applicable analysis actions stay available in the preview footer, with native accessible names and tooltips. Rows use content-type symbols; the selected image appears in the main preview.
- General, Shortcuts, AI, Privacy and Data organize the existing settings. All pages stay mounted while preferences is open. Inactive native page containers are hidden, including the inspection wrapper, so they cannot intercept scrolling or accessibility navigation. Selecting an already active category is a no-op.
- Styling is installed once per process. Theme and selection changes toggle scoped CSS classes. Application-owned Cairo vectors use GTK colors and need no optional SVG loader or system icon theme.

## Verification

Native Linux checks run in private Docker/Xvfb/DBus sessions with synthetic history. No local host keyboard or clipboard is used. Evidence is collected under the ignored `dist/desktop-macos-parity-ui` directory.

Local evidence on 2026-11-03:

- Linux application release build passed with the pinned offline dependencies.
- Broad native smoke: 146/146 checks passed, including original payload copy, seven languages, archive round trips, startup reconciliation, AI consent/connection/retry, updates and sensitive preview revocation. This run preceded the final filter-width and image-sizing/accessibility corrections; the final image/layout probes cover those corrections.
- Native model-settings controls: 8/8 passed, including real pointer scrolling, license gates, import chooser cancellation and passive verification without downloads.
- Final image checks use a 360 × 960 synthetic PNG in both 760 × 520 and 640 × 480 windows and require nonzero, portrait-shaped bounds inside the scroll viewport. Final layout checks passed 19/19 at each of display scales 1 and 2; results are recorded alongside screenshots.
- Core desktop localization: 3/3 tests passed. Actual search-submit/backend-update, content-save ordering, sensitive-analysis revocation, and 96 native-state authorization cases passed. Swift formatting, Python compilation, PowerShell parsing/helper resolution and workflow lint passed.

Windows compilation and native accessibility/image/navigation checks run in the ordinary PR workflow using the existing debug build and stable dependency caches. Linux screenshots do not establish Windows rendering, real IME composition, physical mixed-DPI behavior or sleep/wake acceptance.

The native probes navigate the five settings categories without removing existing assertions. Regression coverage includes native editor identity and unsaved drafts across pages/languages, visible controls at compact sizes, pointer-operated scrolling to model controls, source filtering, and original clipboard payloads. Windows preview checks identify the actual image by its accessible name so decorative icons cannot satisfy the image assertion.

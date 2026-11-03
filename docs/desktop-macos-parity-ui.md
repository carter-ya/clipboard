# Mac-aligned desktop interface

The Windows/Linux GTK application follows the approved Mac layout with a 760 × 520 preferred window, a 56% history column and 7 logical pixels of row padding. The existing macOS application is unchanged.

## Behavior

- A 44px search surface contains the native editor and trailing Settings action. Recording/hide/source controls sit in the status bar below a persistent left-list/right-preview layout. The list and preview scroll independently. Image height follows the mapped window height with space reserved for metadata and controls; it has no fixed upper cap.
- All/Pinned and all six content filters retain their existing counts and behavior. Gray All/Pinned segments use a white selected surface. Compact icon type controls fit one row from 740 logical pixels in Chinese and use two rows below 1200 in other languages; multi-digit counts increase the breakpoint so chips stay readable; accessible names remain complete. Source filtering remains available through the filter button.
- Copy, pin and delete are available in the native preview menu; quick Copy and applicable analysis actions remain in the footer. Rows use tinted type-symbol tiles and compact relative dates. The selected image row reuses the already decoded preview texture; other rows do not trigger background image decoding. The exact timestamp remains in preview metadata. Relative dates update with history refresh, without polling. The pinned SwiftCrossUI List contributes 6px vertical/8px horizontal padding; the row adds only 1px/2px to reach the approved 7px/10px total (54px content row).
- General, Shortcuts, AI, Privacy and Data organize the existing settings. All pages stay mounted while preferences is open. Inactive native page containers are hidden, including the inspection wrapper, so they cannot intercept scrolling or accessibility navigation. Selecting an already active category is a no-op. General appearance and language use native menus in label/control form rows.
- Styling is installed once per process. Theme and selection changes toggle scoped CSS classes. Application-owned Cairo vectors use GTK colors and need no optional SVG loader or system icon theme.

## Verification

Native Linux checks run in private Docker/Xvfb/DBus sessions with synthetic history. No local host keyboard or clipboard is used. Evidence is collected under the ignored `dist/desktop-macos-parity-ui` directory.

Initial implementation evidence on 2026-11-03 (before the visual-fidelity follow-up):

- Linux application release build passed with the pinned offline dependencies.
- Broad native smoke: 146/146 checks passed, including original payload copy, seven languages, archive round trips, startup reconciliation, AI consent/connection/retry, updates and sensitive preview revocation. This run preceded the final filter-width and image-sizing/accessibility corrections; the final image/layout probes cover those corrections.
- Native model-settings controls: 8/8 passed, including real pointer scrolling, license gates, import chooser cancellation and passive verification without downloads.
- Final image checks use a 360 × 960 synthetic PNG in both 760 × 520 and 640 × 480 windows and require nonzero, portrait-shaped bounds inside the scroll viewport. Final layout checks passed 19/19 at each of display scales 1 and 2; results are recorded alongside screenshots.
- Core desktop localization: 3/3 tests passed. Actual search-submit/backend-update, content-save ordering, sensitive-analysis revocation, and 96 native-state authorization cases passed. Swift formatting, Python compilation, PowerShell parsing/helper resolution and workflow lint passed.

Windows compilation and native accessibility/image/navigation checks run in the ordinary PR workflow using the existing debug build and stable dependency caches. Linux screenshots do not establish Windows rendering, real IME composition, physical mixed-DPI behavior or sleep/wake acceptance.

The native probes navigate the five settings categories without removing existing assertions. Regression coverage includes native editor identity and unsaved drafts across pages/languages, visible controls at compact sizes, pointer-operated scrolling to model controls, source filtering, and original clipboard payloads. Windows preview checks identify the actual image by its accessible name so decorative icons cannot satisfy the image assertion.

## Visual fidelity follow-up

The initial Linux screenshot reproduced the column structure but not the approved visual hierarchy. The follow-up corrects search height, segment colors, icon tiles, selected thumbnail, row dates, preview metadata/menu, image captions and General form alignment. `create-design-fixtures.py` creates the reference five records and a public three-color PNG in a new private profile; `capture-linux-design.py` captures the actual application in light/dark modes and exercises native menu copy and theme selection. These are application screenshots, not the HTML mock.

GTK 4.6 AT-SPI reports a popup's anchor origin as its window origin. The layout probe correlates the popup size with the unique mapped X11 surface owned by the test process, then preserves each accessible child's local offset for the bounds assertion. The native menu uses GTK end alignment with no hard-coded offsets. Actual pointer copy/readback is still required in the compact window, and Wayland keeps the persistent quick-copy button for its real input-serial test.

Follow-up results on 2026-11-03:

- Native Linux functional smoke: 146/146; native model controls: 8/8. These cover the native menus and page/form changes; final caption localization, dropdown arrows, multi-digit filter sizing and total row padding were then checked by the focused probes below.
- Final release build passed. Final layout probes pass 20/20 at both scales 1 and 2, including a 54px actual row, original mouse Copy/readback, native menu bounds, portrait image geometry and retained editors/drafts.
- The final public design capture passes all three checks: five-record rendered history, menu Copy with byte-for-byte original PNG readback, and native theme/settings navigation. Two consecutive equal content frames are required before saving a settled screenshot; comparison excludes the header’s blinking native caret, while the saved screenshot includes the entire window. The final capture also verifies that the footer count retains nonempty native bounds after Copy. Light/dark history, the open menu and General settings are retained under `dist/desktop-macos-parity-ui/fidelity-followup`.
- Core presentation/localization: 10/10. Search submit, save-validation order, sensitive-analysis revocation and all 96 IME-state authorization cases pass; Swift formatting, Python compilation and Windows probe syntax/helper resolution pass.

Hosted Windows verification belongs to the updated PR head. The older head's green CI does not validate these follow-up changes.

Reproduce the design capture inside the Linux test container (the output directory must be private test data):

```sh
dbus-run-session -- xvfb-run -a -s '-screen 0 2560x1600x24' \
  python3 tools/desktop-ui/capture-linux-design.py \
  --executable Desktop/.build/release/ClipboardDesktop \
  --output /tmp/clipboard-design-capture
```

Use a display large enough for the logical test window multiplied by `GDK_SCALE`; the 960×640 layout probe at scale 2 requires at least 1920×1280 physical pixels. The capture requires ImageMagick, X11 tools, Openbox and AT-SPI from the existing Linux fixture image. It records only synthetic public data. OS window decorations, fonts and popup shadows remain platform-dependent; these screenshots do not promise pixel-for-pixel identity with macOS.

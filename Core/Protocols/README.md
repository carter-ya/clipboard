# Vendored Wayland protocol

`wlr-data-control-unstable-v1.xml` comes from swaywm/wlr-protocols at commit
`b010a03648b88d143236de193bddbfea0c08bc84` (the license is retained in the XML
and generated sources).

Source: https://github.com/swaywm/wlr-protocols/blob/b010a03648b88d143236de193bddbfea0c08bc84/unstable/wlr-data-control-unstable-v1.xml

SHA-256: `5ac39552975b28d0ea42f636a79b7fc8e2d1fcfa31cbe173f549bd4b044ae2de`.

Generate the private C client code with Wayland scanner 1.20.0:

```sh
wayland-scanner client-header Core/Protocols/wlr-data-control-unstable-v1.xml Core/Sources/CDesktopClipboard/wayland-protocols/wlr-data-control-unstable-v1-client-protocol.h
wayland-scanner private-code Core/Protocols/wlr-data-control-unstable-v1.xml Core/Sources/CDesktopClipboard/wayland-protocols/wlr-data-control-unstable-v1-protocol.c
```

Wrap the generated `.c` file in `#if defined(__linux__)` / `#endif`, so other
platforms do not compile Wayland declarations. The generated header is private.
No scanner is required on end-user machines or Windows/macOS builders.

The adapter uses the first advertised seat and its normal clipboard. It does
not observe or replace the primary selection. It binds at most protocol v2 and
requires the compositor to advertise wlr data control; this is not an XWayland
fallback. Source application identity is not supplied by this protocol.

The private pointer-only UI test fixture uses `wlr-virtual-pointer-unstable-v1.xml`
from the same upstream commit in `tools/desktop-ui/protocols/`, with its original
license. It creates no keyboard device and is never part of the application.

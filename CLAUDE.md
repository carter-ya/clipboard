# Clipboard

macOS 剪贴板历史应用。项目规格的权威来源是 [`harness.json`](./harness.json) —— 任何改动前先读。

## 快速上手

```bash
just gen     # 用 XcodeGen 生成 .xcodeproj
just build   # 冷编译
just run     # 启动 App（菜单栏会出现图标）
just test    # 运行 Core 的单元测试
just test-windows # 在桌面会话运行原生窗口回归（仅合成测试内容）
just test-window-runner # 无界面验证测试并发隔离／中断清理
just lint    # swift-format 检查
just logs    # 流式查看 os.Logger 输出（subsystem com.clipboard.app）
just reset   # 清除本地历史数据（~/Library/Application Support/Clipboard）
just clean   # 清理 build 与生成的 .xcodeproj
```

## 结构

- `Core/` —— `ClipboardCore` Swift Package：所有业务逻辑，可独立测试
- `App/` —— macOS App target：菜单栏外壳 + 装配层，不含业务逻辑
- `project.yml` —— XcodeGen 源；`.xcodeproj` 每次 `just gen` 生成，**不提交**
- `harness.json` —— 项目单一事实源，任何偏离都要在同一次提交中更新
- `docs/release-notes/<ver>/<lang>.html` —— Sparkle 弹窗里的多语言 release notes，发版前 7 份（en / zh-Hans / zh-Hant / ja / ko / de / es）必须齐全；`just release-notes-check VERSION` 本地预演，CI 也会卡

## 约定摘要

完整约定见 `harness.json` 的 `harness.conventions` / `guardrails`。要点：

- 业务逻辑留在 `ClipboardCore`；UI 层通过协议依赖 Core，装配点在 `App/AppWiring.swift`
- 日志统一走 `os.Logger`（subsystem `com.clipboard.app`）；禁止 `print()`
- 不合成键盘事件（不用 CGEvent / AppleScript / Accessibility）——选中条目只写剪贴板，用户自行 `Cmd+V`
- 不启用 App Sandbox；不上 Mac App Store
- 敏感条目仅驻留内存、绝不落盘（JSON / blobs/ / 导出 / 日志正文均不明文出现）
- 三队列分工：`monitor_queue`（轮询与过滤）/ `store_queue`（哈希与持久化）/ `main_queue`（UI）
- 界面最低兼容 macOS 13；macOS 26+ 两窗统一使用单层 regular 原生磨砂玻璃，旧系统回退 popover / behindWindow。设置玻璃贯穿标题栏与正文，正文约束到系统 contentLayoutGuide，不手工写标题栏高度。禁止整块实色背景遮住材质；辅助功能可回退实色。正常外观不叠加窗口描边，仅提高对比度时保留辅助轮廓。历史面板保持无标题栏的 nonactivating panel，不为淡化边缘改成 titled/fullSizeContentView 或改变 safe area；S89 外框试验已因用户报告输入回归撤回。macOS 26+ 只将历史玻璃向外扩展 1pt 并用圆角 viewport 裁掉细边，前景反向补偿、保持坐标和尺寸不变；隐藏时连同材质释放裁切层。隐藏窗口释放界面、材质、约束和显示设置监听；不添加逐行玻璃、循环动画或 UI 轮询。
- 设置交接到历史面板时，先卸载设置内容，等历史面板关闭后再恢复 accessory；返回设置时取消这次恢复，避免切换后台状态撤销搜索焦点。保留系统输入框及其输入法行为；面板显示完成或成为 key 时，在布局后明确设置搜索框为第一响应者，已在编辑时不重复设置。搜索面板 becomesKeyOnlyIfNeeded=false，确保设置交接后无需先点击控件才能接管键盘。不添加延迟抢焦点或重试轮询。焦点验收必须区分程序内 insertText 与真实快捷键后的键盘交接，不能只凭前者宣称后者通过。

- 新会话在显示前完成屏幕尺寸、列表重置、搜索框布局和 initialFirstResponder 设置；自动聚焦由 AppKit 窗口显示／成为 key 的路径负责，不再叠加 SwiftUI onAppear 聚焦。保留 FocusState 的 Cmd+F／清空操作。主面板禁用默认出现动画，不添加延迟聚焦重试，保留玻璃材质。

- “通用 → 外观”提供跟随系统／浅色／深色，默认跟随系统。外观选择器使用固定原生段宽及独立布局容器，避免重复点击、切页或主题变化改变长度；点击已选设置页不重复发布导航变化。偏好保存后直接设置 NSApplication.appearance，启动时提前恢复；不重启 Monitor、不增加轮询。辅助功能实色背景在 effectiveAppearance 改变时刷新颜色。

- 偏好设置优先使用可见历史面板所在屏幕（关闭面板前捕获），没有主面板则用鼠标所在屏幕。同屏保留位置、跨屏居中，并限制在目标屏幕可见区内；不添加屏幕轮询。

- 开机启动状态在每次显示设置、可见设置窗口恢复／成为 key、应用取消隐藏／重新激活时与系统同步。用独立可观察状态刷新该开关，保留页面、原生输入控件和草稿；保存其他选项时合并最新启动状态。同步只读取登录项并更新偏好，不触发注册或重启 Monitor，不增加轮询。

- 历史面板以 760×520 为首选尺寸，逐次唤醒按目标屏幕可见区收缩宽高，SwiftUI 前景填满实际窗口，返回宽屏恢复首选尺寸。隐藏应用或最小化设置时卸载材质、约束和显示选项监听；历史面板另暂停键盘／外部点击监听。临时隐藏保留托管视图的编辑状态，恢复时挂载单层材质；真正关闭仍清空界面。隐藏和恢复不触发剪贴板提交，不增加轮询。

- 主窗口按住 ⌘ 在类型标签和“全部／置顶”按钮内用快捷键替换数量，松开恢复数量；悬停也可查看。复用可见窗口的本地按键监听观察 flagsChanged，原样传递事件，失去焦点或隐藏时清理状态。提示预留固定布局、不增加轮询或持续动画。

- AI 工具栏入口按用户要求作为持续推广效果：偏好设置可见时，不论当前页签／悬停状态，52×32pt 范围内保持金色大星稳定，七颗小星（包括左上两颗）以不同周期和起始相位柔和浮现、轻微上飘、消失；每次只有一个亮度峰值，不做主星摆动或整组同步呼吸。此为循环装饰动画的唯一例外；不增加定时器、粒子发射器或逐帧 AppKit／SwiftUI 重绘。隐藏、最小化、完全遮挡或关闭时移除动画；减少动态效果开启时显示静态金色图标。主星按图标区域中心对齐。AI 原生文字／留白的普通点击在设置可见时通过单个本地鼠标监听转交同一个按钮；Control 点击原样交回 AppKit，不触发切页；图标保留原生跟踪，拖出、失焦、跨窗口或丢失鼠标松开事件后取消跟踪。隐藏／最小化／关闭／完全遮挡时释放该监听，不添加全局监听或轮询。其余工具栏与窗口焦点仍使用原生行为。

- 原生窗口测试使用合成内容；退出前切回 accessory 并给 Dock 留出处理时间。测试入口 exec Python 监督进程，同一用户的原生窗口测试通过持有文件锁排队（锁文件不删除）；每次在 build/window-regressions/run-*/ 内独立生成应用和 results.json。直接启动并持有子进程及独立进程组，不扫描全局进程列表。构建失败、SIGINT／SIGTERM 和 120 秒测试超时只清理本次子进程及应用，锁保留到清理结束，结果留在各自目录；不能删除旧运行目录、清理真实 Clipboard 或重置 Dock。just test-window-runner 用无界面的隔离子进程覆盖这些边界。

- GitHub 发版正文将 CHANGELOG 对应版本段落注入模板中唯一的 `<!-- RELEASE_NOTES -->` 标记，缺失说明即失败。下载和校验说明分别列出 arm64／x86_64 文件名；校验文件第二列含 `dist/`，直接比对哈希。发布前的准备不提前写入尚未生成签名的 appcast 条目；正式更新条目由现有 CI 生成发布。

## Slice 节奏

见 `harness.json` 的 `slices[]` 与 `slice_rhythm`。每个 slice 以绿色、可运行、可提交的状态结束。

## Cross-platform desktop delivery

- Windows/Linux implementation is authorized through the stacked PR plan in `harness.json.cross_platform_delivery`, based on main `2fd2a97`. Preserve the existing macOS product and its macOS 13 minimum. System dependencies belong in platform adapters; shared business contracts stay portable.
- macOS keeps OSLog and CryptoKit; the non-Apple desktop uses a private-by-default stderr logger and Swift Crypto. Native clipboard, hotkey, credentials and rich-text preview adapters remain separate work.
- `.github/workflows/swift-portability.yml` runs Core tests and synthetic scenarios on Ubuntu/Windows plus Core/application regression on macOS for PRs, main changes and manual runs. Results and limitations belong in `docs/swift-portability.md` and `harness.json`.

- Cross-platform delivery uses stacked PRs: each layer targets the preceding branch, with implementation and native-test evidence. Do not mark untested keyboard/IME/DPI or unsupported Wayland capabilities as complete. The WinUI accessibility crash reproduced in the prior experiment must be resolved before accepting Windows UI controls.

- Native text clipboard adapters live in `DesktopClipboard` plus a C system shim. Windows uses Unicode clipboard APIs; Linux X11 uses XFixes notifications and an event-driven selection owner. The legacy text-only adapter rejects Wayland; the rich adapter uses native wlr data control in CP7, with GTK copy-only fallback on restricted compositors. Native tests exchange synthetic text with an independent process in the CI clipboard or isolated Xvfb; no user desktop clipboard is used locally.

- `Desktop/` is the Windows/Linux SwiftCrossUI application package. It explicitly uses GtkBackend; Windows GTK must include AccessKit and pass native UI Automation controls. The historical WinUI crash is not accepted as a successful port. Normal launches never seed sample history; only --smoke-root may inject synthetic fixtures. Keep GTK/Win32/X11 dependencies out of portable Core contracts.

- Desktop shell adapters use Windows tray/hotkey APIs or Linux SNI/dbusmenu/X11. Single-instance ownership is acquired before opening a profile; activation IPC carries no clipboard data. GTK hidden editors preserve drafts without adding UI polling. Persisted recording-on-start is distinct from runtime pause. Native shell tests use private Xvfb/DBus sessions and synthetic profile identities.

- Desktop rich capture uses Core RichClipboardAccess and a native adapter. Resolve blob bytes/decode images off UI; sensitive previews stay hidden. Desktop history archives are bounded, self-contained JSON (not macOS ZIP), exclude sensitive items and reject external blob references. Source IDs come from clipboard owner metadata, never the foreground app. INCR transfer timers exist only while outgoing transfers are active.

- DesktopServices owns OS credential/startup/OCR and bounded AI transport adapters. No plaintext credential fallback, keys in JSON or payloads in command arguments. Explicit remote/image/automatic opt-ins are separate; sensitive/concealed items fail before resolution or networking. Linux service tests run on a fresh DBus session with private keyring/config directories; Windows uses distinct synthetic credential/startup identities. GTK theme and language updates must preserve editors and require no UI polling.

- Wayland capture requires wlr data control and the first advertised seat. It has no source-app identity or primary-selection capture. Global shortcuts use the desktop portal, restore only previously approved bindings, and require an explicit settings action for new permission. Never bypass restricted capture through RemoteDesktop permissions. Preserve one-shot activation tokens only in memory. Tests own their compositor/DBus session; the fallback UI test creates only a private mouse device, never a keyboard. Real portal keyboard focus/IME remains unverified.
- The pinned SwiftCrossUI GTK main-loop patch releases one-shot callback contexts and prevents zero-delay timeouts from starving AccessKit idle actions. Keep native accessibility focus/button checks as hard gates; a visible tree alone is insufficient.

- CP8 preview packages bundle Swift runtime plus notices, record file hashes, and install per user. Linux declares Ubuntu 22.04 native runtime dependencies; Windows includes a verified GTK/DLL closure and uses the GUI subsystem. Keep installed bundles locked while running, preserve history/credentials through upgrade and uninstall, and remove only owned shortcuts/startup entries/files. Package probes use private profiles and a runtime-only Linux image or isolated Windows Actions runner. Virtual scale/lifecycle evidence does not close physical IME/DPI/focus gates.
- The pinned GTK AccessKit patch handles editable SetValue with native sensitivity/editability checks and schedules accessibility input at default priority. Optional CI diagnostics contain action/target IDs only, never text. UI Automation clients run MTA; native focus/action success remains required.

- GTK archive sources retain LF; normalize reviewed patch input before applying it on Windows, and include the patch/helper in runtime cache keys. Do not normalize unrelated source files.

- Desktop installation/startup paths resolve the actual main executable, not argv[0], which can be a bare PATH command. The installed Linux probe launches through its private command entry.
- The pinned GTK label patch emits accessible text removal/insertion notifications when contents change, so equal-sized updates invalidate cached text runs. Keep baseline Counter: 0 → 1 and 3 → 1 search-result checks; no UI polling or renderer-independent flush is needed.

- Installed Windows OCR validation temporarily hides/restores only its isolated CI build resource bundles, so SwiftPM absolute build-path fallbacks cannot mask missing packaged scripts.
- Native UI probes wait for exact restored editor values after asynchronous view reconstruction, retaining the bounded timeout and value assertion. Failure diagnostics expose lengths/control metadata, never text contents.

- Plain GTK text inputs expose their actual GtkEditable value rather than aggregating decorative/placeholder children. Password/protected widgets must never enter this plaintext-value override.

- Installed Windows lifecycle probes bound repeated private hide/reopen cycles and record process private bytes/handles after warmup, keeping physical focus/IME and multi-day soak gates separate.
- Windows GTK keeps one AccessKit root/subclassing adapter per native GdkSurface across hide/reopen, rebuilds the tree on reuse, and releases it with that surface. Recreating adapters for a surviving HWND causes an abort. Hidden editor preservation and lifecycle/resource checks remain hard gates.

- A surviving Windows HWND keeps its accessible root node ID across hide/reopen; rebuilding descendant contexts must not invalidate UIA window references.

- Surviving Windows widgets keep their accessible node IDs through context recreation. Their identity records use weak root references and are released with the widget; reparenting to another root receives a new ID.

- Desktop primary item actions remain outside the history scroll viewport at every width. Wide layouts must keep Copy/Pin/Delete visible too; preview content must not own a duplicate action toolbar.
- Windows rich UI tests pause after each capture before Copy, then require a new clipboard revision and a fresh status transition before checking native format bytes. An old Copied label or the fixture peer owning identical bytes cannot acknowledge a new asynchronous Copy.

- Native Windows probes wait for the matching image/file preview and enabled button before invoking once. Equal result counts do not acknowledge a filter change; never retry an already submitted mutation.

- OCR replacement waits for the native image preview before deleting the old image; an equal one-item count from the previous File filter is not proof of selection.

- Installer fixtures read an absent startup value as null through the registry key API; preserve the refusal of existing normal registrations. Cache compiled UI dependencies after a successful optimized build, before installation checks, and repair Windows tracked links on exact or fallback cache restores.

- Responsive headers keep one HStack and one headerActions subtree. Change only the title branch; hidden zero-size geometry must not replace live Hide/Settings/recording buttons or retire their accessibility IDs.
- X11 selection requestors may disappear before a reply. The clipboard adapter recovers BadWindow only on registered private connections and delegates other connections/errors to the prior host handler. The portability workflow permanently exercises cancelled requests and registry cleanup in private Xvfb.

- Native X11 shortcut dispatch must require an acquired registration and exact configured keyboard modifiers. Ignore Caps Lock and the discovered Num Lock mask, retain held-key suppression, and test the native dispatcher directly without synthesizing keyboard input.

- Automatic desktop analysis uses the bounded ID-only serial scheduler; a busy manual action must not discard inserted clips. Recheck live settings and the current item when dequeuing, exclude sensitive/concealed or already analyzed clips, report overflow, and cancel/clear work on shutdown. Keep manual duplicate actions guarded.

- Wayland activation tokens belong to immutable shell events. Copy the borrowed native callback string into its matching showHistory event; unrelated or delayed actions must not consume a shared token slot. Keep the delayed-consumer, two-distinct-activations portal regression.
- Every whole-settings save, including appearance and language, must await the same MainActor FIFO save gate before reading the latest settings, retain its lease through persistence and in-memory update, and release it with defer. Do not drop rapid presentation actions or restore stale AI/privacy opt-outs. Pending writers must skip work during shutdown.

- CP1–CP8 are preview foundations. Follow `cross_platform_delivery.functional_parity` for remaining Mac-equivalent development. A successful desktop Copy must immediately promote the item through Core and refresh, including when capture is paused; do not rely on recapture. Native UI probes verify ordering and independent readback using private fixtures.

- Plain-text desktop previews use a 64 KiB UTF-8 display budget and show a truncation notice. End on a Unicode scalar boundary; never truncate the stored payload or Copy. Keep the long Chinese/emoji native capture-and-full-readback regression. Rich-only parser limits remain separately tracked.

- Native Windows text readback tests must expect CF_UNICODETEXT CRLF, matching the writer normalization. Keep full-content comparison and fresh clipboard revision checks; do not weaken them to a suffix-only match. Linux UTF-8 readback remains byte-exact.

- Wayland receive pipes must keep the descriptor sent to an external producer blocking. Apply O_NONBLOCK only to the local reader, retain CLOEXEC, and test the actual helper with a complete large transfer from an independent blocking writer.

- Sensitive desktop previews require an explicit reveal for the selected item and presentation. Revoke on selection change, settings handoff, native unmap and shutdown; reject late preview results by generation and invalidate their loaded-ID cache. Sensitive decoding has no blob root, creates no preview files, and never changes sensitivity or AI/OCR gates. Synthetic sensitive fixtures require both --smoke-root and --smoke-sensitive. Suppress screenshots, content-bearing errors and accessibility-text diagnostics throughout that probe phase.

- Desktop All/Pinned counts use the current query/source match before kind filtering; type counts use the active tab before kind filtering. Project these together in portable Core so empty kind results do not erase library totals. Keep the legacy Mixed filter, single-line fixed-width count badges and readable two-row type controls below 1100 logical pixels. Native probes load a synthetic persisted mixed record and verify pin/query scope.
- Sensitive Windows failures may record fixed stage IDs, numeric bounds and known-control presence, with no content values or screenshots. Compare native filter identities across one hide only; settings legitimately recreates the history view. Debug compilation caches use their own manifest/pin/patch key and are saved after both debug products compile, before native UI gates; optimized artifacts retain a separate success-only cache key.

- Rich-only desktop display previews use the same 64 KiB UTF-8 budget as plain text and expose parser/source-budget truncation too. Keep plain rendering, bounded parsing and legacy row/analysis limits; Copy must retain the complete original HTML/RTF bytes. Native probes check the notice and independent full-format readback from synthetic persisted records.

# Clipboard

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md)

一款 macOS 菜单栏剪贴板历史工具。所有数据保存在本地，不联网、不同步、不追踪；敏感条目只驻留内存，绝不落盘。

## 功能

- 全局快捷键召唤历史面板（默认未绑定，首次启动会提示设置）
- 文本 / 富文本 / 图片 / 文件四种条目类型，带缩略图预览
- 按 kind 过滤 + 全文搜索（图片 OCR 结果也可搜）
- 敏感内容识别（密码、金融卡号等）：仅缓存、不写盘、不导出
- 按源应用屏蔽（bundle ID 黑名单）
- AI 摘要：Vision OCR + NaturalLanguage 实体识别，macOS 26+ 可选用 Apple Foundation Models
- 多语言界面：English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Sparkle 自动更新（零 Apple 签名，通过 EdDSA 校验）

## 系统要求

macOS 13 Ventura 或更高。Apple Silicon 与 Intel 均支持；Foundation Models 摘要需要 macOS 26+ 且设备开启 Apple Intelligence。

## 安装

### 一键脚本（推荐）

```bash
curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
```

脚本会：拉最新 DMG → 校验 SHA-256 → 如 Clipboard 正在运行先让它退出 → 拷到 `/Applications/` → `xattr -cr` 清掉 Gatekeeper 隔离标记。完成后从 Launchpad / Spotlight 启动即可。

### 手动从 GitHub Release 下载

1. 到 [Releases 页面](https://github.com/carter-ya/clipboard/releases/latest) 下载对应你 Mac 芯片的 DMG：Apple Silicon 选 `Clipboard-<version>-arm64.dmg`，Intel 选 `Clipboard-<version>-x86_64.dmg`（左上角 Apple 菜单 → 关于本机 可查看芯片）
2. 双击挂载，把 `Clipboard.app` 拖进 `Applications/`
3. **去掉 Gatekeeper 隔离标记**（本项目未走 Apple Developer ID 签名与公证）：

    ```bash
    xattr -cr /Applications/Clipboard.app
    ```

4. 双击启动。首次启动会弹引导窗口要你设置全局快捷键（推荐 `⌃⌥⌘V` 或 `⌘⇧V`）。

> 如果跳过步骤 3，macOS 会弹"无法验证开发者"并拒绝打开。在 **系统设置 → 隐私与安全性** 里可以手动点"仍要打开"，但 `xattr -cr` 更快。

### 校验下载

每个 DMG 都带同名 `.sha256` 文件。把 DMG 和 `.sha256` 下到同目录后比对哈希：

```bash
# <arch> 取 arm64（Apple Silicon）或 x86_64（Intel）
shasum -a 256 Clipboard-<version>-<arch>.dmg
cat Clipboard-<version>-<arch>.dmg.sha256
# 两行首段哈希应一致
```

（`.sha256` 的第二列是打包时的仓库相对路径 `dist/...`，所以不能直接 `shasum -c`。）

## 使用

- **⌃⌥⌘V**（或你设置的快捷键）：打开 / 关闭历史面板
- **↑ / ↓**：在条目间移动
- **⏎**：选中条目写回剪贴板，关闭面板；接着你自己按 `⌘V` 粘贴（Clipboard 不合成键盘事件）
- **⌘F**：跳到搜索框
- **⌘,**：打开 Preferences
- **面板内右键条目**：Pin / Delete
- **Pin 的条目**永远不会被容量上限淘汰

## 隐私

- 所有历史数据保存在 `~/Library/Application Support/Clipboard/`
- **敏感条目**（被 macOS 标记为 `NSPasteboardTypeConcealed`，如密码管理器里的密码）只在内存中缓存，退出即清空；不会出现在 `history.json`、`blobs/`、导出包或日志正文里
- 不联网、不发送遥测、不分析
- 可按源应用 bundle ID 屏蔽（例如永远不记录密码管理器的内容）

## 自动更新

内置 Sparkle（独立于 Apple 签名体系，通过 EdDSA 校验更新包）。Preferences → General → Updates 里可以手动触发检查，或在 Scheduled Check Interval（默认 24 小时）触发时自动检查。

## 开发

### 前置依赖

```bash
brew install just xcodegen swift-format
```

Xcode 15+（建议 16）。

### 常用命令

```bash
just gen       # 从 project.yml 生成 .xcodeproj（未提交）
just build     # 冷编译 Debug
just run       # 启动（菜单栏不显示图标，LSUIElement=true）
just test      # 运行 Core 的 85 条单测
just lint      # swift-format 检查
just fmt       # swift-format 格式化
just logs      # 流式查看 os.Logger 输出（subsystem com.clipboard.app）
just reset     # 清除本地历史数据
just package   # 打两架构 Release DMG（arm64 + x86_64）+ SHA256 到 dist/
just clean     # 清理 build 与生成物
```

### 打包流程

```bash
just package
# → dist/Clipboard-<version>-arm64.dmg  (+ .sha256)
# → dist/Clipboard-<version>-x86_64.dmg (+ .sha256)
```

### 项目结构

- `Core/` —— `ClipboardCore` Swift Package：所有业务逻辑，可独立测试
- `App/` —— macOS App target：菜单栏外壳 + 装配层，不含业务逻辑
- `project.yml` —— XcodeGen 源；`.xcodeproj` 每次 `just gen` 生成，**不提交**
- `harness.json` —— 项目单一事实源，任何偏离都要在同一次提交中同步更新

### 发布流程（维护者）

1. 在 `CHANGELOG.md` 顶部新增 `## [x.y.z] - YYYY-MM-DD` 条目
2. 把 `project.yml` 的 `MARKETING_VERSION` 改成 `x.y.z`，`CURRENT_PROJECT_VERSION` 自增
3. `git commit -am "release: x.y.z"`
4. `git tag -a vx.y.z -m "x.y.z"`
5. `git push && git push --tags` —— GitHub Actions 跑 `release.yml`：打两架构 DMG（arm64 + x86_64）、各用 Sparkle 私钥签名、创建 Release 挂两个 DMG + `.sha256` + 按架构的 `appcast-item-<arch>.xml`，并把两段 appcast 片段打进 workflow 的 Step Summary
6. 随后 `release.yml` 会自动把刷新后的 appcast 提交到 `main`——按架构的 `appcast-arm64.xml` / `appcast-x86_64.xml`，外加供老（≤1.0.4）安装继续轮询的融合 `appcast.xml`——无需手动粘贴。（GitHub Pages 重新发布后 Sparkle 才能看到新版。）

**首次发布前**必须做的一次性配置：

1. `just build` 一次（触发 SPM 首次拉取 Sparkle）
2. `just sparkle-keys` 生成 EdDSA 密钥对 —— 默认把私钥写进本机 Keychain，公钥打印到 stdout
3. 把输出的公钥（一串 base64）填进 `project.yml` 与 `App/Info.plist` **两处**的 `SUPublicEDKey` 字段（替换占位符 `REPLACE_WITH_BASE64_EDKEY`）。XcodeGen 每次 `just gen` 会用 `project.yml` 覆盖 `Info.plist` 同名键，漏改 `project.yml` 那一侧 `just gen` 后会被打回占位
4. 导出私钥以便放进 CI secret：`just sparkle-keys -x sparkle_ed_priv.key`（`-x` 透传给 `generate_keys`），`cat sparkle_ed_priv.key` 拷内容到密码管理器，**立即 `rm sparkle_ed_priv.key`**
5. 在 GitHub 仓库 Settings → Secrets → Actions 新增 `SPARKLE_PRIVATE_KEY`，粘贴刚导出的私钥 base64 内容
6. 当前 owner 为 `carter-ya`；fork 后需全局替换为你自己的 GitHub 用户名 / 组织名：`project.yml` 的 `SU_FEED_URL` 默认值、`Justfile` `package` recipe 里的按架构 feed URL、`docs/appcast.xml` / `docs/appcast-arm64.xml` / `docs/appcast-x86_64.xml`、`docs/install.sh` 的 `REPO` 与 header 注释里的 URL、`CHANGELOG.md` 链接定义、所有 `README*.md` 安装段落里的 install.sh URL、`harness.json` 的 `project.distribution`
7. 启用 GitHub Pages：Settings → Pages → Source `Deploy from a branch` → Branch `main` → `/docs` → Save；appcast 会挂在 `https://carter-ya.github.io/clipboard/appcast.xml`
8. `just clean && just package` **重新打包** —— 之前 `dist/` 里的 DMG 带的是占位值，绝不能上传

### 硬约束（给贡献者）

- 业务逻辑留在 `ClipboardCore`；UI 层通过协议依赖 Core
- 日志统一走 `os.Logger`（subsystem `com.clipboard.app`）；禁止 `print()`
- 不合成键盘事件（不用 CGEvent / AppleScript / Accessibility）——选中条目只写剪贴板，用户自行 `⌘V`
- 不启用 App Sandbox；不上 Mac App Store
- 敏感条目仅驻留内存、绝不落盘
- 三队列分工：`monitor_queue`（轮询与过滤）/ `store_queue`（哈希与持久化）/ `main_queue`（UI）

完整约定见 `harness.json`。

## 许可

TBD（首发前确定）。

<!-- Rendered title comes from `gh release create --title`. Keep this file as body only. -->

## What's new

<!-- RELEASE_NOTES -->

## Download

按 Mac 的芯片选择下载（Apple 菜单 → 关于本机可查看）：

| Mac | 安装包 | SHA-256 校验文件 |
| --- | --- | --- |
| Apple Silicon（M 系列，arm64） | [Clipboard-X.Y.Z-arm64.dmg](https://github.com/carter-ya/clipboard/releases/download/vX.Y.Z/Clipboard-X.Y.Z-arm64.dmg) | [arm64.sha256](https://github.com/carter-ya/clipboard/releases/download/vX.Y.Z/Clipboard-X.Y.Z-arm64.dmg.sha256) |
| Intel（x86_64） | [Clipboard-X.Y.Z-x86_64.dmg](https://github.com/carter-ya/clipboard/releases/download/vX.Y.Z/Clipboard-X.Y.Z-x86_64.dmg) | [x86_64.sha256](https://github.com/carter-ya/clipboard/releases/download/vX.Y.Z/Clipboard-X.Y.Z-x86_64.dmg.sha256) |

## Install

1. 下载与你的 Mac 芯片对应的 DMG
2. 挂载后把 `Clipboard.app` 拖进 `/Applications/`
3. **去掉 Gatekeeper 隔离标记**：

   ```bash
   xattr -cr /Applications/Clipboard.app
   ```

4. 启动；首次运行会提示设置全局快捷键

老用户会通过 Sparkle 自动收到本次更新，无需重复上述步骤。

## Verify

将安装包和同名 `.sha256` 文件下载到同一目录，按芯片运行对应的一组命令；两行输出的首段哈希应一致。

Apple Silicon：

```bash
shasum -a 256 Clipboard-X.Y.Z-arm64.dmg
cat Clipboard-X.Y.Z-arm64.dmg.sha256
```

Intel：

```bash
shasum -a 256 Clipboard-X.Y.Z-x86_64.dmg
cat Clipboard-X.Y.Z-x86_64.dmg.sha256
```

校验文件中的文件路径可能包含打包目录 `dist/`，因此这里直接比对哈希。

## System requirements

macOS 13 Ventura 或更高，支持 Apple Silicon 与 Intel。Liquid Glass 需要 macOS 26 或更高；旧系统使用兼容外观。

<!--
发版前检查清单（人工过一遍，CI 会在少东西时失败）：
1. project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION 已更新
2. CHANGELOG.md 在 [X.Y.Z] 下面写好了本版本变更
3. docs/release-notes/X.Y.Z/{en,zh-Hans,zh-Hant,ja,ko,de,es}.html 七份齐全
   —— `just release-notes-check X.Y.Z` 验证
4. git tag vX.Y.Z && git push origin vX.Y.Z 触发 CI
-->


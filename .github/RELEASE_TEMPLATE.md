<!-- Rendered title comes from `gh release create --title`. Keep this file as body only. -->

## What's new

<!-- 从 CHANGELOG.md 对应版本条目复制过来 -->

## Install

1. 下载下方 Assets 里的 `Clipboard-X.Y.Z.dmg`
2. 挂载后把 `Clipboard.app` 拖进 `/Applications/`
3. **去掉 Gatekeeper 隔离标记**：

   ```bash
   xattr -cr /Applications/Clipboard.app
   ```

4. 启动；首次运行会提示设置全局快捷键

老用户会通过 Sparkle 自动收到本次更新，无需重复上述步骤。

## Verify

```bash
shasum -a 256 -c Clipboard-X.Y.Z.dmg.sha256
```

## System requirements

macOS 13 Ventura 或更高。

<!--
发版前检查清单（人工过一遍，CI 会在少东西时失败）：
1. project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION 已更新
2. CHANGELOG.md 在 [X.Y.Z] 下面写好了本版本变更
3. docs/release-notes/X.Y.Z/{en,zh-Hans,zh-Hant,ja,ko,de,es}.html 七份齐全
   —— `just release-notes-check X.Y.Z` 验证
4. git tag vX.Y.Z && git push origin vX.Y.Z 触发 CI
-->


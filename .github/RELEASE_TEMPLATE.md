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

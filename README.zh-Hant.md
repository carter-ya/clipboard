# Clipboard

[English](README.md) · [简体中文](README.zh-Hans.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md)

一款 macOS 選單列剪貼簿歷史工具。所有資料保存在本機，不連網、不同步、不追蹤；敏感條目只駐留記憶體，絕不寫入磁碟。

## 功能

- 全域快捷鍵召喚歷史面板（預設未綁定，首次啟動會提示設定）
- 文字 / 豐富文字 / 圖片 / 檔案四種條目類型，附縮圖預覽
- 按 kind 篩選 + 全文搜尋（圖片的 OCR 結果也可搜尋）
- 敏感內容識別（密碼、金融卡號等）：僅快取、不寫盤、不匯出
- 按來源 App 封鎖（bundle ID 黑名單）
- AI 摘要：Vision OCR + NaturalLanguage 實體識別，macOS 26+ 可選用 Apple Foundation Models
- 多語系介面：English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Sparkle 自動更新（零 Apple 簽章，透過 EdDSA 校驗）

## 系統需求

macOS 13 Ventura 或以上。Apple Silicon 與 Intel 皆支援；Foundation Models 摘要需要 macOS 26+ 且裝置已開啟 Apple Intelligence。

## 安裝

### 一鍵指令稿（推薦）

```bash
curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
```

指令稿會：抓取最新 DMG → 校驗 SHA-256 → 如 Clipboard 正在執行先讓它退出 → 複製到 `/Applications/` → 執行 `xattr -cr` 清除 Gatekeeper 隔離標記。完成後從 Launchpad / Spotlight 啟動即可。

### 手動從 GitHub Release 下載

1. 到 [Releases 頁面](https://github.com/carter-ya/clipboard/releases/latest) 下載對應你 Mac 晶片的 DMG：Apple Silicon 選 `Clipboard-<version>-arm64.dmg`，Intel 選 `Clipboard-<version>-x86_64.dmg`（左上角 Apple 選單 → 關於這台 Mac 可查看晶片）
2. 連按兩下掛載，把 `Clipboard.app` 拖進 `Applications/`
3. **清除 Gatekeeper 隔離標記**（本專案未走 Apple Developer ID 簽章與公證）：

    ```bash
    xattr -cr /Applications/Clipboard.app
    ```

4. 連按兩下啟動。首次啟動會彈出引導視窗要你設定全域快捷鍵（建議 `⌃⌥⌘V` 或 `⌘⇧V`）。

> 若跳過步驟 3，macOS 會彈出「無法驗證開發者」並拒絕開啟。在 **系統設定 → 隱私權與安全性** 內可手動點「仍然打開」，但 `xattr -cr` 更快。

### 校驗下載內容

每個 DMG 都附同名 `.sha256` 檔案。將 DMG 和 `.sha256` 下載至同一目錄後比對雜湊：

```bash
# <arch> 取 arm64（Apple Silicon）或 x86_64（Intel）
shasum -a 256 Clipboard-<version>-<arch>.dmg
cat Clipboard-<version>-<arch>.dmg.sha256
# 兩行的首段雜湊應一致
```

（`.sha256` 的第二欄是打包時的專案相對路徑 `dist/...`，所以不能直接 `shasum -c`。）

## 使用

- **⌃⌥⌘V**（或您設定的快捷鍵）：打開 / 關閉歷史面板
- **↑ / ↓**：在條目間移動
- **⏎**：將選中條目寫回剪貼簿並關閉面板；接著您自行按 `⌘V` 貼上（Clipboard 不會合成鍵盤事件）
- **⌘F**：跳到搜尋框
- **⌘,**：打開偏好設定
- **在面板內右鍵條目**：Pin / Delete
- **Pin 的條目**永遠不會被容量上限淘汰

## 隱私

- 所有歷史資料保存在 `~/Library/Application Support/Clipboard/`
- **敏感條目**（被 macOS 標記為 `NSPasteboardTypeConcealed`，例如密碼管理器中的密碼）僅在記憶體中快取，結束即清空；不會出現在 `history.json`、`blobs/`、匯出包或日誌正文裡
- 不連網、不傳送遙測、不分析
- 可依來源 App bundle ID 封鎖（例如永遠不記錄密碼管理器的內容）

## 自動更新

內建 Sparkle（獨立於 Apple 簽章體系，透過 EdDSA 校驗更新包）。Preferences → General → Updates 可手動觸發檢查，或由 Scheduled Check Interval（預設 24 小時）自動檢查。

## 開發

### 前置依賴

```bash
brew install just xcodegen swift-format
```

Xcode 15+（建議 16）。

### 常用指令

```bash
just gen       # 從 project.yml 產生 .xcodeproj（未提交）
just build     # 冷編譯 Debug
just run       # 啟動（選單列不顯示圖示，LSUIElement=true）
just test      # 執行 Core 的 85 條單元測試
just lint      # swift-format 檢查
just fmt       # swift-format 格式化
just logs      # 串流 os.Logger 輸出（subsystem com.clipboard.app）
just reset     # 清除本機歷史資料
just package   # 打兩架構 Release DMG（arm64 + x86_64）+ SHA256 到 dist/
just clean     # 清理 build 與產生物
```

### 打包流程

```bash
just package
# → dist/Clipboard-<version>-arm64.dmg  (+ .sha256)
# → dist/Clipboard-<version>-x86_64.dmg (+ .sha256)
```

### 專案結構

- `Core/` —— `ClipboardCore` Swift Package：所有商業邏輯，可獨立測試
- `App/` —— macOS App target：選單列外殼 + 組裝層，不含商業邏輯
- `project.yml` —— XcodeGen 原始檔；`.xcodeproj` 每次 `just gen` 產生，**不提交**
- `harness.json` —— 專案唯一事實來源，任何偏離都須在同一次提交中同步更新

### 發布流程（維護者）

1. 在 `CHANGELOG.md` 頂端新增 `## [x.y.z] - YYYY-MM-DD` 條目
2. 將 `project.yml` 的 `MARKETING_VERSION` 改為 `x.y.z`，`CURRENT_PROJECT_VERSION` 遞增
3. `git commit -am "release: x.y.z"`
4. `git tag -a vx.y.z -m "x.y.z"`
5. `git push && git push --tags` —— GitHub Actions 執行 `release.yml`：打兩架構 DMG（arm64 + x86_64）、各以 Sparkle 私鑰簽章、建立 Release 掛兩個 DMG + `.sha256` + 按架構的 `appcast-item-<arch>.xml`，並把兩段 appcast 片段輸出到 workflow 的 Step Summary
6. 隨後 `release.yml` 會自動把刷新後的 appcast 提交到 `main`——按架構的 `appcast-arm64.xml` / `appcast-x86_64.xml`，外加供舊（≤1.0.4）安裝繼續輪詢的融合 `appcast.xml`——無需手動貼上。（GitHub Pages 重新發布後 Sparkle 才能看到新版。）

**首次發布前**必須做的一次性設定：

1. `just build` 一次（觸發 SPM 首次拉取 Sparkle）
2. `just sparkle-keys` 產生 EdDSA 金鑰對 —— 預設將私鑰寫入本機 Keychain，公鑰輸出到 stdout
3. 將輸出的公鑰（一串 base64）填進 `project.yml` 與 `App/Info.plist` **兩處**的 `SUPublicEDKey` 欄位（取代佔位符 `REPLACE_WITH_BASE64_EDKEY`）。XcodeGen 每次 `just gen` 會用 `project.yml` 覆寫 `Info.plist` 同名鍵，漏改 `project.yml` 那一側 `just gen` 後會被打回佔位
4. 匯出私鑰以放進 CI secret：`just sparkle-keys -x sparkle_ed_priv.key`（`-x` 透傳給 `generate_keys`），`cat sparkle_ed_priv.key` 複製內容到密碼管理器，**立即 `rm sparkle_ed_priv.key`**
5. 在 GitHub 儲存庫 Settings → Secrets → Actions 新增 `SPARKLE_PRIVATE_KEY`，貼上剛匯出的私鑰 base64 內容
6. 目前 owner 為 `carter-ya`；fork 後需全域替換為您自己的 GitHub 使用者名稱 / 組織名：`project.yml` 的 `SU_FEED_URL` 預設值、`Justfile` `package` recipe 裡的按架構 feed URL、`docs/appcast.xml` / `docs/appcast-arm64.xml` / `docs/appcast-x86_64.xml`、`docs/install.sh` 的 `REPO` 與 header 註解內的 URL、`CHANGELOG.md` 連結定義、所有 `README*.md` 安裝段落裡的 install.sh URL、`harness.json` 的 `project.distribution`
7. 啟用 GitHub Pages：Settings → Pages → Source `Deploy from a branch` → Branch `main` → `/docs` → Save；appcast 會掛在 `https://carter-ya.github.io/clipboard/appcast.xml`
8. `just clean && just package` **重新打包** —— 之前 `dist/` 裡的 DMG 使用的是佔位值，絕不能上傳

### 硬約束（給貢獻者）

- 商業邏輯留在 `ClipboardCore`；UI 層透過協議依賴 Core
- 日誌統一走 `os.Logger`（subsystem `com.clipboard.app`）；禁止 `print()`
- 不合成鍵盤事件（不用 CGEvent / AppleScript / Accessibility）—— 選中條目只寫剪貼簿，由使用者自行 `⌘V`
- 不啟用 App Sandbox；不上 Mac App Store
- 敏感條目僅駐留記憶體、絕不寫入磁碟
- 三佇列分工：`monitor_queue`（輪詢與篩選）/ `store_queue`（雜湊與持久化）/ `main_queue`（UI）

完整約定見 `harness.json`。

## 授權

TBD（首發前確定）。

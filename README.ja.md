# Clipboard

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · **日本語** · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Español](README.es.md)

macOS のメニューバー常駐型クリップボード履歴ツールです。すべてのデータはローカルに保存され、ネットワーク通信・同期・トラッキングは一切行いません。機密項目はメモリ上にのみ保持され、ディスクには決して書き込まれません。

## 機能

- グローバルショートカットで履歴パネルを呼び出し（デフォルト未割り当て。初回起動時に設定を求められます）
- テキスト / リッチテキスト / 画像 / ファイルの 4 種の項目タイプ、サムネイルプレビュー付き
- kind によるフィルタ + 全文検索（画像の OCR 結果も検索対象）
- 機密コンテンツ検出（パスワード・カード番号など）：キャッシュのみ、永続化もエクスポートもしない
- 送信元アプリ単位のブロック（bundle ID ブラックリスト）
- AI 要約：Vision OCR + NaturalLanguage 固有表現抽出。macOS 26+ では Apple Foundation Models を任意で利用可能
- 多言語 UI：English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Sparkle による自動アップデート（Apple 署名不要、EdDSA で検証）

## システム要件

macOS 13 Ventura 以降。Apple Silicon・Intel の両方をサポート。Foundation Models による要約は macOS 26+ かつ端末で Apple Intelligence が有効な場合のみ利用可能です。

## インストール

### ワンライナースクリプト（推奨）

```bash
curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
```

スクリプトの処理：最新 DMG の取得 → SHA-256 検証 → 起動中の Clipboard があれば終了させる → `/Applications/` にコピー → `xattr -cr` で Gatekeeper 隔離属性を除去。完了後は Launchpad や Spotlight から起動してください。

### GitHub Release から手動インストール

1. [Releases ページ](https://github.com/carter-ya/clipboard/releases/latest) から `Clipboard-<version>.dmg` をダウンロード
2. ダブルクリックでマウントし、`Clipboard.app` を `Applications/` にドラッグ
3. **Gatekeeper の隔離属性を除去**（本プロジェクトは Apple Developer ID 署名・公証を使用していません）：

    ```bash
    xattr -cr /Applications/Clipboard.app
    ```

4. ダブルクリックで起動。初回起動時にグローバルショートカット（`⌃⌥⌘V` または `⌘⇧V` 推奨）を設定するウィザードが表示されます。

> 手順 3 を省くと、macOS は「開発元を確認できません」と表示して開けません。**システム設定 → プライバシーとセキュリティ → このまま開く**でも許可できますが、`xattr -cr` のほうが速いです。

### ダウンロードの検証

各 DMG には同名の `.sha256` ファイルが付属します。DMG と `.sha256` を同じディレクトリに配置し、ハッシュを比較します：

```bash
shasum -a 256 Clipboard-<version>.dmg
cat Clipboard-<version>.dmg.sha256
# 両行の先頭フィールドが一致するはずです
```

（`.sha256` の第 2 列はパッケージング時のリポジトリ相対パス `dist/...` のため、`shasum -c` は直接使用できません。）

## 使い方

- **⌃⌥⌘V**（または設定したショートカット）：履歴パネルの開閉
- **↑ / ↓**：項目間を移動
- **⏎**：選択項目をクリップボードに書き戻してパネルを閉じる。その後ユーザー自身で `⌘V` を押してペースト（Clipboard はキーボードイベントを合成しません）
- **⌘F**：検索ボックスへ移動
- **⌘,**：環境設定を開く
- **パネル内で項目を右クリック**：Pin / Delete
- **Pin した項目**は容量上限による自動削除の対象外

## プライバシー

- すべての履歴データは `~/Library/Application Support/Clipboard/` に保存されます
- **機密項目**（macOS が `NSPasteboardTypeConcealed` としてマークしたもの、例：パスワードマネージャーのパスワード）はメモリにのみキャッシュされ、終了時にクリアされます。`history.json`、`blobs/`、エクスポートアーカイブ、ログ本文には一切現れません
- ネットワーク通信・テレメトリ・アナリティクスなし
- 送信元アプリの bundle ID 単位でブロック可能（例：パスワードマネージャーのコピー内容を常に記録しない）

## 自動アップデート

Sparkle を内蔵（Apple の署名体系に依存せず、アップデートパッケージを EdDSA で検証）。Preferences → General → Updates で手動チェックできるほか、Scheduled Check Interval（デフォルト 24 時間）で自動実行されます。

## 開発

### 前提

```bash
brew install just xcodegen swift-format
```

Xcode 15 以降（16 推奨）。

### 主なコマンド

```bash
just gen       # project.yml から .xcodeproj を生成（コミット対象外）
just build     # Debug のクリーンビルド
just run       # 起動（LSUIElement=true のためメニューバーのみ、Dock アイコンなし）
just test      # Core の 85 件の単体テストを実行
just lint      # swift-format による lint
just fmt       # swift-format による整形
just logs      # os.Logger 出力をストリーム（subsystem com.clipboard.app）
just reset     # ローカル履歴データを削除
just package   # Release DMG + SHA256 を dist/ に生成
just clean     # build 生成物と生成された .xcodeproj を削除
```

### パッケージング

```bash
just package
# → dist/Clipboard-<version>.dmg
# → dist/Clipboard-<version>.dmg.sha256
```

### プロジェクト構成

- `Core/` —— `ClipboardCore` Swift Package：すべてのビジネスロジック、独立してテスト可能
- `App/` —— macOS App ターゲット：メニューバーの外殻と組み立て層。ビジネスロジックは含みません
- `project.yml` —— XcodeGen のソース。`.xcodeproj` は `just gen` のたびに生成され、**コミットしません**
- `harness.json` —— プロジェクト唯一の真実の情報源。逸脱が生じる場合は同一コミット内で同期する必要があります

### リリース手順（メンテナー向け）

1. `CHANGELOG.md` の先頭に `## [x.y.z] - YYYY-MM-DD` のエントリを追加
2. `project.yml` の `MARKETING_VERSION` を `x.y.z` に変更し、`CURRENT_PROJECT_VERSION` をインクリメント
3. `git commit -am "release: x.y.z"`
4. `git tag -a vx.y.z -m "x.y.z"`
5. `git push && git push --tags` —— GitHub Actions が `release.yml` を実行：DMG のビルド、Sparkle 秘密鍵による署名、Release の作成（DMG + `.sha256` + `appcast-item.xml` を添付）、appcast スニペットを workflow の Step Summary に出力
6. **Step Summary の `<item>…</item>` スニペットを `docs/appcast.xml` の `</channel>` の直前に貼り付け**、`git commit -am "appcast: vx.y.z" && git push`（GitHub Pages の反映後、Sparkle が新バージョンを検出）

**初回リリース前**の一度だけ必要な設定：

1. `just build` を一度実行（SPM による Sparkle の初回取得をトリガー）
2. `just sparkle-keys` で EdDSA 鍵ペアを生成 —— 秘密鍵はデフォルトでローカル Keychain に保存され、公開鍵が stdout に出力されます
3. 出力された公開鍵（base64 文字列）を `project.yml` と `App/Info.plist` の **両方**の `SUPublicEDKey` に貼り付け（プレースホルダ `REPLACE_WITH_BASE64_EDKEY` を置換）。XcodeGen は `just gen` のたびに `project.yml` の値で `Info.plist` を上書きするため、`project.yml` 側を忘れると `just gen` 後にプレースホルダに戻ります
4. CI secret 用に秘密鍵をエクスポート：`just sparkle-keys -x sparkle_ed_priv.key`（`-x` は `generate_keys` にそのまま渡されます）。`cat sparkle_ed_priv.key` で中身をパスワードマネージャーへコピーし、**直ちに `rm sparkle_ed_priv.key`**
5. リポジトリの Settings → Secrets → Actions で `SPARKLE_PRIVATE_KEY` を追加し、エクスポートした秘密鍵の base64 内容を貼り付け
6. 現在の owner は `carter-ya`。fork 後は以下すべてをご自身の GitHub ユーザー名 / 組織名にグローバル置換してください：`project.yml` の `SUFeedURL`、`App/Info.plist` の `SUFeedURL`、`docs/appcast.xml`、`docs/install.sh` の `REPO` 定数と header コメントの URL、`CHANGELOG.md` のリンク定義、すべての `README*.md` のインストールセクション内の install.sh URL、`harness.json` の `project.distribution`
7. GitHub Pages を有効化：Settings → Pages → Source `Deploy from a branch` → Branch `main` → `/docs` → Save。appcast は `https://carter-ya.github.io/clipboard/appcast.xml` で公開されます
8. `just clean && just package` で**再パッケージ** —— `dist/` にすでにある DMG はプレースホルダ値でビルドされているので、絶対にアップロードしないでください

### ハード制約（コントリビューター向け）

- ビジネスロジックは `ClipboardCore` に置く。UI 層はプロトコル経由で Core に依存
- ログは `os.Logger`（subsystem `com.clipboard.app`）に統一。`print()` は禁止
- キーボードイベントを合成しない（CGEvent / AppleScript / Accessibility を使わない）—— 項目選択ではクリップボードに書き込むだけで、ユーザーが自分で `⌘V` を押す
- App Sandbox は有効化しない。Mac App Store は配布対象外
- 機密項目はメモリのみ。ディスクへは決して書かない
- 3 キュー分担：`monitor_queue`（ポーリングとフィルタリング）/ `store_queue`（ハッシュと永続化）/ `main_queue`（UI）

完全な規約は `harness.json` を参照してください。

## ライセンス

TBD（初回公開前に決定）。

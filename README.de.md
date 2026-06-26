# Clipboard

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **Deutsch** · [Español](README.es.md)

Ein macOS-Menüleisten-Werkzeug für den Zwischenablage-Verlauf. Alle Daten bleiben lokal — keine Netzwerkverbindung, keine Synchronisation, kein Tracking. Sensible Einträge liegen ausschließlich im Arbeitsspeicher und werden niemals auf die Platte geschrieben.

## Funktionen

- Globales Tastenkürzel öffnet das Verlaufs-Panel (standardmäßig ungebunden; beim ersten Start wirst du zur Einrichtung aufgefordert)
- Vier Eintragstypen — Text / Rich Text / Bild / Datei — mit Vorschau-Miniaturen
- Filter nach Kind + Volltextsuche (OCR-Ergebnisse von Bildern sind ebenfalls durchsuchbar)
- Erkennung sensibler Inhalte (Passwörter, Kreditkartennummern usw.): nur gecacht, niemals persistiert oder exportiert
- Blockieren nach Quell-App (bundle-ID-Blockliste)
- KI-Zusammenfassungen: Vision OCR + NaturalLanguage Entity Recognition; macOS 26+ kann optional Apple Foundation Models nutzen
- Lokalisierte Oberfläche: English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Auto-Update via Sparkle (ohne Apple-Signatur; über EdDSA verifiziert)

## Systemanforderungen

macOS 13 Ventura oder neuer. Apple Silicon und Intel werden beide unterstützt. Foundation-Models-Zusammenfassungen erfordern macOS 26+ und ein Gerät mit aktiviertem Apple Intelligence.

## Installation

### Einzeiler-Skript (empfohlen)

```bash
curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
```

Das Skript lädt die neueste DMG → verifiziert SHA-256 → beendet eine laufende Clipboard-Instanz → kopiert nach `/Applications/` → führt `xattr -cr` aus, um das Gatekeeper-Quarantäne-Attribut zu entfernen. Anschließend über Launchpad oder Spotlight starten.

### Manuelle Installation vom GitHub Release

1. Lade die zum Chip deines Macs passende DMG von der [Releases-Seite](https://github.com/carter-ya/clipboard/releases/latest) herunter: `Clipboard-<version>-arm64.dmg` für Apple Silicon, `Clipboard-<version>-x86_64.dmg` für Intel (Apple-Menü → Über diesen Mac zeigt den Chip)
2. Per Doppelklick mounten und `Clipboard.app` nach `Applications/` ziehen
3. **Gatekeeper-Quarantäne-Attribut entfernen** (dieses Projekt nutzt keine Apple-Developer-ID-Signatur / Notarisierung):

    ```bash
    xattr -cr /Applications/Clipboard.app
    ```

4. Per Doppelklick starten. Beim ersten Start erscheint ein Einrichtungs-Dialog für ein globales Tastenkürzel (empfohlen `⌃⌥⌘V` oder `⌘⇧V`).

> Ohne Schritt 3 verweigert macOS das Öffnen mit „Entwickler kann nicht verifiziert werden“. Du kannst es manuell über **Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen** freigeben, aber `xattr -cr` ist schneller.

### Download prüfen

Zu jeder DMG liegt eine gleichnamige `.sha256`-Datei. DMG und `.sha256` in dasselbe Verzeichnis laden und Hashes vergleichen:

```bash
# <arch> = arm64 (Apple Silicon) oder x86_64 (Intel)
shasum -a 256 Clipboard-<version>-<arch>.dmg
cat Clipboard-<version>-<arch>.dmg.sha256
# Der erste Hash in beiden Zeilen sollte übereinstimmen
```

(Die zweite Spalte der `.sha256`-Datei ist der repo-relative Pfad `dist/...` aus dem Packaging-Schritt, daher funktioniert `shasum -c` nicht direkt.)

## Benutzung

- **⌃⌥⌘V** (oder dein gewähltes Kürzel): Verlaufs-Panel öffnen / schließen
- **↑ / ↓**: zwischen Einträgen navigieren
- **⏎**: gewählten Eintrag zurück in die Zwischenablage schreiben und Panel schließen; danach selbst `⌘V` drücken (Clipboard synthetisiert keine Tastenereignisse)
- **⌘F**: zum Suchfeld springen
- **⌘,**: Einstellungen öffnen
- **Rechtsklick auf einen Eintrag im Panel**: Pin / Delete
- **Angepinnte Einträge** werden nie durch die Kapazitätsgrenze verdrängt

## Datenschutz

- Der gesamte Verlauf liegt unter `~/Library/Application Support/Clipboard/`
- **Sensible Einträge** (alles, was macOS als `NSPasteboardTypeConcealed` markiert, etwa Passwörter aus einem Passwort-Manager) werden ausschließlich im Speicher gehalten und beim Beenden gelöscht; sie erscheinen weder in `history.json`, noch in `blobs/`, Export-Archiven oder Log-Bodies
- Keine Netzwerkverbindung, keine Telemetrie, keine Analytik
- Einträge lassen sich nach Quell-App-bundle-ID blockieren (z. B. niemals aus dem Passwort-Manager kopierte Inhalte aufzeichnen)

## Auto-Update

Mit integriertem Sparkle (unabhängig von Apples Signaturkette; Update-Pakete werden per EdDSA verifiziert). Preferences → General → Updates erlaubt manuelles Prüfen, das Scheduled Check Interval (Standard 24 Stunden) löst automatisch aus.

## Entwicklung

### Voraussetzungen

```bash
brew install just xcodegen swift-format
```

Xcode 15+ (16 empfohlen).

### Häufige Befehle

```bash
just gen       # Erzeugt .xcodeproj aus project.yml (nicht committet)
just build     # Kalter Debug-Build
just run       # Starten (Menüleisten-Shell, kein Dock-Icon wegen LSUIElement=true)
just test      # Führt die 85 Core-Unit-Tests aus
just lint      # swift-format lint
just fmt       # swift-format in-place
just logs      # Stream der os.Logger-Ausgabe (Subsystem com.clipboard.app)
just reset     # Lokale Verlaufsdaten entfernen
just package   # Release-DMGs je Architektur (arm64 + x86_64) + SHA256 nach dist/ bauen
just clean     # Build-Artefakte und generiertes Projekt löschen
```

### Packaging

```bash
just package
# → dist/Clipboard-<version>-arm64.dmg  (+ .sha256)
# → dist/Clipboard-<version>-x86_64.dmg (+ .sha256)
```

### Projektstruktur

- `Core/` — `ClipboardCore` Swift Package: sämtliche Business-Logik, unabhängig testbar
- `App/` — macOS-App-Target: Menüleisten-Shell und Composition Root, keine Business-Logik
- `project.yml` — XcodeGen-Quelle; `.xcodeproj` wird bei jedem `just gen` regeneriert und **nicht committet**
- `harness.json` — Single Source of Truth des Projekts; jede Abweichung muss im selben Commit synchronisiert werden

### Release-Prozess (Maintainer)

1. Oben in `CHANGELOG.md` einen Eintrag `## [x.y.z] - YYYY-MM-DD` einfügen
2. `MARKETING_VERSION` in `project.yml` auf `x.y.z` setzen, `CURRENT_PROJECT_VERSION` inkrementieren
3. `git commit -am "release: x.y.z"`
4. `git tag -a vx.y.z -m "x.y.z"`
5. `git push && git push --tags` — GitHub Actions führt `release.yml` aus: baut beide DMGs je Architektur (arm64 + x86_64), signiert jede mit dem Sparkle-Private-Key, erzeugt ein Release mit beiden DMGs + `.sha256` + architekturspezifischen `appcast-item-<arch>.xml` und schreibt beide appcast-Snippets in die Step Summary des Workflows
6. `release.yml` committet anschließend die aktualisierten appcasts automatisch nach `main` — die architekturspezifischen `appcast-arm64.xml` / `appcast-x86_64.xml` sowie das zusammengeführte `appcast.xml` für ältere (≤1.0.4) Installationen — ein manuelles Einfügen entfällt also. (Sparkle sieht die neue Version erst, nachdem GitHub Pages erneut veröffentlicht hat.)

**Vor dem ersten Release einmalig nötig**:

1. `just build` einmal ausführen (SPM lädt Sparkle erstmalig)
2. `just sparkle-keys` erzeugt ein EdDSA-Schlüsselpaar — der Private Key landet standardmäßig im lokalen Keychain, der Public Key wird auf stdout ausgegeben
3. Public Key (base64-String) in sowohl `project.yml` als auch `App/Info.plist` unter `SUPublicEDKey` eintragen (Platzhalter `REPLACE_WITH_BASE64_EDKEY` ersetzen). XcodeGen überschreibt `Info.plist` bei jedem `just gen` aus `project.yml` — vergisst man die `project.yml`-Seite, wird der Wert beim nächsten `just gen` wieder auf den Platzhalter zurückgesetzt
4. Private Key für das CI-Secret exportieren: `just sparkle-keys -x sparkle_ed_priv.key` (`-x` wird an `generate_keys` durchgereicht); `cat sparkle_ed_priv.key` in einen Passwort-Manager kopieren und **sofort `rm sparkle_ed_priv.key`**
5. Unter Settings → Secrets → Actions das Geheimnis `SPARKLE_PRIVATE_KEY` anlegen und den exportierten base64-Key einfügen
6. Der aktuelle Owner ist `carter-ya`; Forker müssen ihn durch ihren eigenen GitHub-Benutzernamen / Organisationsnamen ersetzen in: `SU_FEED_URL`-Default in `project.yml`, den architekturspezifischen Feed-URLs im `package`-Rezept des `Justfile`, `docs/appcast.xml` / `docs/appcast-arm64.xml` / `docs/appcast-x86_64.xml`, `docs/install.sh` (Konstante `REPO` und URL im Header-Kommentar), `CHANGELOG.md`-Link-Definitionen, Install-Abschnitt jeder `README*.md`-Datei (install.sh-URL) sowie `project.distribution` in `harness.json`
7. GitHub Pages aktivieren: Settings → Pages → Source `Deploy from a branch` → Branch `main` → `/docs` → Save; der appcast liegt dann unter `https://carter-ya.github.io/clipboard/appcast.xml`
8. `just clean && just package` zum **Neubauen** — alle DMGs, die bereits in `dist/` liegen, wurden mit Platzhaltern gebaut und dürfen nicht hochgeladen werden

### Harte Vorgaben (für Contributors)

- Business-Logik bleibt in `ClipboardCore`; die UI-Schicht hängt über Protokolle an Core
- Logging läuft ausschließlich über `os.Logger` (Subsystem `com.clipboard.app`); kein `print()`
- Keine synthetischen Tastenereignisse (kein CGEvent / AppleScript / Accessibility) — Auswählen eines Eintrags schreibt nur in die Zwischenablage; der Nutzer drückt `⌘V` selbst
- App Sandbox ist deaktiviert; Mac App Store ist kein Zielkanal
- Sensible Einträge bleiben nur im Speicher, niemals auf Disk
- Drei-Queue-Disziplin: `monitor_queue` (Polling und Filter) / `store_queue` (Hashing und Persistenz) / `main_queue` (UI)

Die vollständigen Konventionen stehen in `harness.json`.

## Lizenz

TBD (wird vor der ersten öffentlichen Veröffentlichung festgelegt).

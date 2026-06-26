# Clipboard

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · **Español**

Una utilidad de historial del portapapeles residente en la barra de menú de macOS. Todos los datos permanecen en tu equipo: sin red, sin sincronización, sin tracking. Los elementos sensibles viven únicamente en memoria y nunca se escriben en disco.

## Funciones

- Atajo global para invocar el panel de historial (sin asignar por defecto; se solicita configurarlo en el primer arranque)
- Cuatro tipos de elementos — texto / texto enriquecido / imagen / archivo — con previsualización en miniatura
- Filtro por kind + búsqueda de texto completo (los resultados de OCR sobre imágenes también son buscables)
- Detección de contenido sensible (contraseñas, números de tarjeta, etc.): sólo en caché, nunca persistido ni exportado
- Lista de bloqueo por aplicación de origen (bundle ID)
- Resúmenes con IA: Vision OCR + entidades de NaturalLanguage; en macOS 26+ se puede optar por Apple Foundation Models
- Interfaz localizada: English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Auto-actualización con Sparkle (sin firma de Apple; verificada con EdDSA)

## Requisitos del sistema

macOS 13 Ventura o posterior. Se admiten tanto Apple Silicon como Intel; los resúmenes con Foundation Models requieren macOS 26+ y Apple Intelligence habilitado en el dispositivo.

## Instalación

### Script de una línea (recomendado)

```bash
curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
```

El script: descarga la DMG más reciente → verifica SHA-256 → cierra Clipboard si estuviera en ejecución → copia a `/Applications/` → ejecuta `xattr -cr` para eliminar el atributo de cuarentena de Gatekeeper. Luego inícialo desde Launchpad o Spotlight.

### Instalación manual desde GitHub Release

1. Descarga la DMG correspondiente al chip de tu Mac desde la [página de Releases](https://github.com/carter-ya/clipboard/releases/latest): `Clipboard-<version>-arm64.dmg` para Apple Silicon, `Clipboard-<version>-x86_64.dmg` para Intel (menú Apple → Acerca de este Mac muestra el chip)
2. Haz doble clic para montar y arrastra `Clipboard.app` a `Applications/`
3. **Elimina el atributo de cuarentena de Gatekeeper** (este proyecto no usa firma de Apple Developer ID ni notarización):

    ```bash
    xattr -cr /Applications/Clipboard.app
    ```

4. Ábrelo con doble clic. El primer arranque muestra un asistente para configurar un atajo global (se recomienda `⌃⌥⌘V` o `⌘⇧V`).

> Si omites el paso 3, macOS se negará a abrirlo con "no se puede verificar al desarrollador". Puedes autorizarlo manualmente en **Ajustes del sistema → Privacidad y seguridad → Abrir de todos modos**, pero `xattr -cr` es más rápido.

### Verificar la descarga

Cada DMG se acompaña de un archivo `.sha256` homónimo. Descarga ambos al mismo directorio y compara los hashes:

```bash
# <arch> = arm64 (Apple Silicon) o x86_64 (Intel)
shasum -a 256 Clipboard-<version>-<arch>.dmg
cat Clipboard-<version>-<arch>.dmg.sha256
# El primer campo de ambas líneas debe coincidir
```

(La segunda columna del `.sha256` es la ruta relativa al repositorio `dist/...` usada al empaquetar, por lo que `shasum -c` no puede usarse directamente.)

## Uso

- **⌃⌥⌘V** (o el atajo que configures): abrir / cerrar el panel de historial
- **↑ / ↓**: moverse entre elementos
- **⏎**: escribir el elemento seleccionado de vuelta al portapapeles y cerrar el panel; después pulsa tú mismo `⌘V` para pegar (Clipboard no sintetiza eventos de teclado)
- **⌘F**: saltar al campo de búsqueda
- **⌘,**: abrir Preferencias
- **Clic derecho sobre un elemento del panel**: Pin / Delete
- **Los elementos fijados** nunca son descartados por el límite de capacidad

## Privacidad

- Todo el historial se guarda en `~/Library/Application Support/Clipboard/`
- **Los elementos sensibles** (cualquier cosa que macOS marque como `NSPasteboardTypeConcealed`, por ejemplo contraseñas de un gestor de contraseñas) sólo se almacenan en memoria y se borran al salir; nunca aparecen en `history.json`, `blobs/`, paquetes de exportación ni en el cuerpo de los logs
- Sin red, sin telemetría, sin analítica
- Puedes bloquear por bundle ID de la app de origen (por ejemplo, para no registrar jamás lo copiado desde tu gestor de contraseñas)

## Auto-actualización

Incluye Sparkle (independiente de la cadena de firma de Apple; los paquetes de actualización se verifican con EdDSA). En Preferences → General → Updates puedes forzar una comprobación manual; el Scheduled Check Interval (por defecto 24 horas) la ejecuta automáticamente.

## Desarrollo

### Prerrequisitos

```bash
brew install just xcodegen swift-format
```

Xcode 15+ (se recomienda 16).

### Comandos habituales

```bash
just gen       # Genera .xcodeproj a partir de project.yml (no se commitea)
just build     # Build Debug en frío
just run       # Lanzamiento (shell en la barra de menú, sin icono en el Dock porque LSUIElement=true)
just test      # Ejecuta los 85 tests unitarios de Core
just lint      # lint con swift-format
just fmt       # swift-format in-place
just logs      # Stream de la salida de os.Logger (subsistema com.clipboard.app)
just reset     # Elimina los datos de historial locales
just package   # Empaqueta DMGs Release por arquitectura (arm64 + x86_64) + SHA256 en dist/
just clean     # Limpia artefactos de build y el proyecto generado
```

### Empaquetado

```bash
just package
# → dist/Clipboard-<version>-arm64.dmg  (+ .sha256)
# → dist/Clipboard-<version>-x86_64.dmg (+ .sha256)
```

### Estructura del proyecto

- `Core/` — Swift Package `ClipboardCore`: toda la lógica de negocio, testeable de forma independiente
- `App/` — target de app macOS: shell de barra de menú y composition root, sin lógica de negocio
- `project.yml` — fuente de XcodeGen; `.xcodeproj` se regenera con cada `just gen` y **no se commitea**
- `harness.json` — única fuente de verdad del proyecto; cualquier desviación debe sincronizarse en el mismo commit

### Proceso de release (mantenedores)

1. Añade al principio de `CHANGELOG.md` una entrada `## [x.y.z] - YYYY-MM-DD`
2. Sube `MARKETING_VERSION` en `project.yml` a `x.y.z`; incrementa `CURRENT_PROJECT_VERSION`
3. `git commit -am "release: x.y.z"`
4. `git tag -a vx.y.z -m "x.y.z"`
5. `git push && git push --tags` — GitHub Actions ejecuta `release.yml`: compila ambas DMG por arquitectura (arm64 + x86_64), firma cada una con la clave privada de Sparkle, crea un Release con ambas DMG + `.sha256` + `appcast-item-<arch>.xml` por arquitectura e imprime ambos snippets de appcast en el Step Summary del workflow
6. A continuación `release.yml` confirma automáticamente los appcasts actualizados en `main` —— los feeds por arquitectura `appcast-arm64.xml` / `appcast-x86_64.xml` y el `appcast.xml` fusionado para instalaciones antiguas (≤1.0.4) ——, así que no hace falta pegar nada a mano. (Sparkle no verá la nueva versión hasta que GitHub Pages vuelva a publicar.)

**Configuración única antes del primer release**:

1. Ejecuta `just build` una vez (hace que SPM descargue Sparkle la primera vez)
2. `just sparkle-keys` genera un par EdDSA — la clave privada va al Keychain local por defecto; la pública se imprime en stdout
3. Pega la clave pública (una cadena base64) en `project.yml` y `App/Info.plist`, **ambos**, en el campo `SUPublicEDKey` (reemplazando el placeholder `REPLACE_WITH_BASE64_EDKEY`). XcodeGen sobrescribe `Info.plist` desde `project.yml` en cada `just gen`, por lo que olvidarse del lado `project.yml` hará que tras `just gen` se restablezca el placeholder
4. Exporta la clave privada para el secret de CI: `just sparkle-keys -x sparkle_ed_priv.key` (`-x` se reenvía a `generate_keys`); `cat sparkle_ed_priv.key`, copia el contenido a un gestor de contraseñas y **ejecuta inmediatamente `rm sparkle_ed_priv.key`**
5. En Settings → Secrets → Actions del repositorio, añade `SPARKLE_PRIVATE_KEY` pegando el contenido base64 exportado
6. El owner actual es `carter-ya`; tras hacer fork debes sustituirlo por tu usuario / organización de GitHub en: el valor por defecto de `SU_FEED_URL` en `project.yml`, las URLs de feed por arquitectura en la receta `package` del `Justfile`, `docs/appcast.xml` / `docs/appcast-arm64.xml` / `docs/appcast-x86_64.xml`, `docs/install.sh` (constante `REPO` y URL del comentario de cabecera), definiciones de enlaces de `CHANGELOG.md`, la sección de instalación de cada `README*.md` (URL del install.sh) y `project.distribution` de `harness.json`
7. Activa GitHub Pages: Settings → Pages → Source `Deploy from a branch` → Branch `main` → `/docs` → Save; el appcast se servirá en `https://carter-ya.github.io/clipboard/appcast.xml`
8. `just clean && just package` para **reempaquetar** — cualquier DMG ya presente en `dist/` fue construida con valores placeholder y no debe subirse

### Restricciones duras (para contribuidores)

- La lógica de negocio se queda en `ClipboardCore`; la capa de UI depende de Core mediante protocolos
- Todo el logging pasa por `os.Logger` (subsistema `com.clipboard.app`); nada de `print()`
- No sintetizar eventos de teclado (nada de CGEvent / AppleScript / Accessibility) — seleccionar un elemento sólo escribe al portapapeles; el usuario pulsa `⌘V` por su cuenta
- App Sandbox está desactivado; Mac App Store no es un canal de distribución
- Los elementos sensibles se quedan sólo en memoria, nunca en disco
- Disciplina de tres colas: `monitor_queue` (polling y filtrado) / `store_queue` (hashing y persistencia) / `main_queue` (UI)

El conjunto completo de convenciones está en `harness.json`.

## Licencia

TBD (a decidir antes del primer release público).

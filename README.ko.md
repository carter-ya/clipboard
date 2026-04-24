# Clipboard

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · **한국어** · [Deutsch](README.de.md) · [Español](README.es.md)

macOS 메뉴 막대에 상주하는 클립보드 히스토리 도구입니다. 모든 데이터는 로컬에만 저장되며 네트워크·동기화·추적을 일절 하지 않습니다. 민감 항목은 메모리에만 보관되고 디스크에 절대 기록되지 않습니다.

## 기능

- 전역 단축키로 히스토리 패널 호출 (기본값은 미지정이며 최초 실행 시 설정을 안내)
- 텍스트 / 리치 텍스트 / 이미지 / 파일 네 가지 항목 유형, 썸네일 미리 보기 제공
- kind 필터 + 전체 텍스트 검색 (이미지 OCR 결과도 검색 대상)
- 민감 콘텐츠 감지 (비밀번호, 카드 번호 등): 캐시에만 남고 영구 저장·내보내기 안 함
- 출처 앱 단위 차단 (bundle ID 블랙리스트)
- AI 요약: Vision OCR + NaturalLanguage 개체 인식, macOS 26+ 에서는 Apple Foundation Models 선택 가능
- 다국어 UI: English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Sparkle 자동 업데이트 (Apple 서명 없이 EdDSA로 검증)

## 시스템 요구 사항

macOS 13 Ventura 이상. Apple Silicon 과 Intel 모두 지원합니다. Foundation Models 요약은 macOS 26+ 이면서 기기에서 Apple Intelligence 가 활성화되어 있어야 합니다.

## 설치

### 원라이너 스크립트 (권장)

```bash
curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash
```

스크립트 동작: 최신 DMG 내려받기 → SHA-256 검증 → 실행 중인 Clipboard가 있으면 종료 → `/Applications/` 에 복사 → `xattr -cr` 로 Gatekeeper 격리 속성 제거. 완료 후 Launchpad 또는 Spotlight 에서 실행하세요.

### GitHub Release 에서 수동 설치

1. [Releases 페이지](https://github.com/carter-ya/clipboard/releases/latest) 에서 `Clipboard-<version>.dmg` 다운로드
2. 더블클릭으로 마운트한 뒤 `Clipboard.app` 을 `Applications/` 에 드래그
3. **Gatekeeper 격리 속성 제거** (본 프로젝트는 Apple Developer ID 서명·공증을 사용하지 않습니다):

    ```bash
    xattr -cr /Applications/Clipboard.app
    ```

4. 더블클릭으로 실행. 최초 실행 시 전역 단축키 설정 안내 창이 나타납니다 (`⌃⌥⌘V` 또는 `⌘⇧V` 권장).

> 3단계를 건너뛰면 macOS 가 "개발자를 확인할 수 없음" 을 표시하며 열기를 거부합니다. **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기** 로 허용할 수도 있지만 `xattr -cr` 쪽이 더 빠릅니다.

### 다운로드 검증

모든 DMG 에는 같은 이름의 `.sha256` 파일이 함께 있습니다. DMG 와 `.sha256` 을 같은 폴더에 받은 뒤 해시를 비교합니다:

```bash
shasum -a 256 Clipboard-<version>.dmg
cat Clipboard-<version>.dmg.sha256
# 두 줄의 첫 번째 필드가 일치해야 합니다
```

(`.sha256` 의 두 번째 열은 패키징 시점의 저장소 상대 경로 `dist/...` 이므로 `shasum -c` 는 직접 사용할 수 없습니다.)

## 사용법

- **⌃⌥⌘V** (또는 설정한 단축키): 히스토리 패널 열고 닫기
- **↑ / ↓**: 항목 간 이동
- **⏎**: 선택 항목을 클립보드에 다시 쓰고 패널 닫기. 이후 사용자가 직접 `⌘V` 로 붙여넣기 (Clipboard 는 키보드 이벤트를 합성하지 않습니다)
- **⌘F**: 검색 상자로 이동
- **⌘,**: 환경설정 열기
- **패널 내 항목 우클릭**: Pin / Delete
- **Pin 된 항목**은 용량 상한으로 절대 밀려나지 않습니다

## 개인정보

- 모든 히스토리 데이터는 `~/Library/Application Support/Clipboard/` 에 저장됩니다
- **민감 항목** (macOS 가 `NSPasteboardTypeConcealed` 로 표시한 항목, 예: 비밀번호 관리자에서 복사한 비밀번호) 은 메모리에만 캐시되며 종료 시 삭제됩니다. `history.json`, `blobs/`, 내보내기 아카이브, 로그 본문 어디에도 기록되지 않습니다
- 네트워크 통신·텔레메트리·애널리틱스 없음
- 출처 앱 bundle ID 단위로 차단 가능 (예: 비밀번호 관리자에서 복사한 내용은 절대 기록하지 않도록)

## 자동 업데이트

Sparkle 내장 (Apple 서명 체계와 무관하게 업데이트 패키지를 EdDSA 로 검증). Preferences → General → Updates 에서 수동 점검이 가능하며, Scheduled Check Interval (기본 24시간) 로 자동 점검됩니다.

## 개발

### 사전 준비

```bash
brew install just xcodegen swift-format
```

Xcode 15+ (16 권장).

### 주요 명령어

```bash
just gen       # project.yml 에서 .xcodeproj 생성 (커밋 대상 아님)
just build     # Debug 클린 빌드
just run       # 실행 (LSUIElement=true 로 Dock 아이콘 없이 메뉴 막대에만 표시)
just test      # Core 의 85 개 유닛 테스트 실행
just lint      # swift-format lint
just fmt       # swift-format 자동 포맷
just logs      # os.Logger 출력 스트림 (subsystem com.clipboard.app)
just reset     # 로컬 히스토리 데이터 제거
just package   # Release DMG + SHA256 을 dist/ 에 생성
just clean     # 빌드 아티팩트와 생성된 .xcodeproj 삭제
```

### 패키징

```bash
just package
# → dist/Clipboard-<version>.dmg
# → dist/Clipboard-<version>.dmg.sha256
```

### 프로젝트 구조

- `Core/` —— `ClipboardCore` Swift Package: 모든 비즈니스 로직, 독립 테스트 가능
- `App/` —— macOS App 타깃: 메뉴 막대 껍데기와 조립 계층, 비즈니스 로직 없음
- `project.yml` —— XcodeGen 소스. `.xcodeproj` 는 `just gen` 으로 매번 생성되며 **커밋하지 않습니다**
- `harness.json` —— 프로젝트의 단일 진실 원본. 어긋남이 있으면 같은 커밋 안에서 동기화해야 합니다

### 릴리스 절차 (메인테이너)

1. `CHANGELOG.md` 최상단에 `## [x.y.z] - YYYY-MM-DD` 항목 추가
2. `project.yml` 의 `MARKETING_VERSION` 을 `x.y.z` 로, `CURRENT_PROJECT_VERSION` 을 1 증가
3. `git commit -am "release: x.y.z"`
4. `git tag -a vx.y.z -m "x.y.z"`
5. `git push && git push --tags` —— GitHub Actions 가 `release.yml` 실행: DMG 빌드, Sparkle 개인 키 서명, Release 생성 (DMG + `.sha256` + `appcast-item.xml` 첨부), appcast 스니펫을 workflow 의 Step Summary 에 출력
6. **Step Summary 의 `<item>…</item>` 스니펫을 `docs/appcast.xml` 의 `</channel>` 바로 앞에 붙여 넣은 뒤** `git commit -am "appcast: vx.y.z" && git push` 실행 (GitHub Pages 가 반영된 후에야 Sparkle 이 새 버전을 감지)

**첫 릴리스 전** 한 번만 필요한 설정:

1. `just build` 한 번 실행 (SPM 이 Sparkle 을 최초로 내려받도록 트리거)
2. `just sparkle-keys` 로 EdDSA 키 쌍 생성 —— 개인 키는 기본적으로 로컬 Keychain 에 저장되고 공개 키는 stdout 으로 출력됩니다
3. 출력된 공개 키 (base64 문자열) 를 `project.yml` 과 `App/Info.plist` **두 곳** 모두의 `SUPublicEDKey` 에 붙여 넣습니다 (플레이스홀더 `REPLACE_WITH_BASE64_EDKEY` 교체). XcodeGen 은 `just gen` 때마다 `project.yml` 값으로 `Info.plist` 를 덮어쓰므로, `project.yml` 쪽을 놓치면 `just gen` 이후 다시 플레이스홀더로 돌아갑니다
4. CI secret 용으로 개인 키를 내보내기: `just sparkle-keys -x sparkle_ed_priv.key` (`-x` 는 `generate_keys` 로 그대로 전달). `cat sparkle_ed_priv.key` 로 내용을 비밀번호 관리자에 복사한 뒤 **즉시 `rm sparkle_ed_priv.key`**
5. 저장소의 Settings → Secrets → Actions 에서 `SPARKLE_PRIVATE_KEY` 를 추가하고 방금 내보낸 base64 내용을 붙여 넣기
6. 현재 owner 는 `carter-ya`. fork 이후에는 다음 모두를 본인의 GitHub 사용자명 / 조직명으로 전부 치환: `project.yml` 의 `SUFeedURL`, `App/Info.plist` 의 `SUFeedURL`, `docs/appcast.xml`, `docs/install.sh` 의 `REPO` 상수와 header 주석 URL, `CHANGELOG.md` 링크 정의, 모든 `README*.md` 의 설치 섹션 내 install.sh URL, `harness.json` 의 `project.distribution`
7. GitHub Pages 활성화: Settings → Pages → Source `Deploy from a branch` → Branch `main` → `/docs` → Save. appcast 는 `https://carter-ya.github.io/clipboard/appcast.xml` 에 공개됩니다
8. `just clean && just package` 로 **재패키징** —— `dist/` 에 이미 있는 DMG 는 플레이스홀더 값으로 빌드되어 있으므로 절대 업로드하면 안 됩니다

### 하드 제약 (기여자용)

- 비즈니스 로직은 `ClipboardCore` 에 둡니다. UI 계층은 프로토콜을 통해 Core 에 의존
- 로그는 `os.Logger` (subsystem `com.clipboard.app`) 로 통일. `print()` 금지
- 키보드 이벤트 합성 금지 (CGEvent / AppleScript / Accessibility 모두 사용하지 않음) —— 항목 선택은 클립보드에 쓰기만 하고 사용자가 직접 `⌘V` 로 붙여넣기
- App Sandbox 비활성화. Mac App Store 배포는 하지 않음
- 민감 항목은 메모리에만 보관하고 디스크에 쓰지 않음
- 3 큐 분담: `monitor_queue` (폴링과 필터) / `store_queue` (해시와 영속화) / `main_queue` (UI)

전체 규약은 `harness.json` 을 참고하세요.

## 라이선스

TBD (첫 공개 전 확정).

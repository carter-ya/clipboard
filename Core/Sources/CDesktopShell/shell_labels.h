#ifndef CLIPBOARD_SHELL_LABELS_H
#define CLIPBOARD_SHELL_LABELS_H
#ifdef _WIN32
#include <wchar.h>
typedef wchar_t shell_label_char;
#define SHELL_LABEL(value) L##value
#else
typedef char shell_label_char;
#define SHELL_LABEL(value) value
#endif
/* en, zh-Hans, zh-Hant, ja, ko, de, es; stable Swift shellIndex values. */
static const shell_label_char *const shell_labels[7][9] = {
  { /* en */
    SHELL_LABEL("Show history"),
    SHELL_LABEL("Start recording"),
    SHELL_LABEL("Pause recording"),
    SHELL_LABEL("Settings"),
    SHELL_LABEL("Quit"),
    SHELL_LABEL("Recording"),
    SHELL_LABEL("Paused"),
    SHELL_LABEL("Clipboard - recording"),
    SHELL_LABEL("Clipboard - paused"),
  },
  { /* zh-Hans */
    SHELL_LABEL("显示历史"),
    SHELL_LABEL("开始录制"),
    SHELL_LABEL("暂停录制"),
    SHELL_LABEL("设置"),
    SHELL_LABEL("退出"),
    SHELL_LABEL("正在录制"),
    SHELL_LABEL("已暂停"),
    SHELL_LABEL("Clipboard - 正在录制"),
    SHELL_LABEL("Clipboard - 已暂停"),
  },
  { /* zh-Hant */
    SHELL_LABEL("顯示歷程"),
    SHELL_LABEL("開始錄製"),
    SHELL_LABEL("暫停錄製"),
    SHELL_LABEL("設定"),
    SHELL_LABEL("退出"),
    SHELL_LABEL("正在錄製"),
    SHELL_LABEL("已暫停"),
    SHELL_LABEL("Clipboard - 正在錄製"),
    SHELL_LABEL("Clipboard - 已暫停"),
  },
  { /* ja */
    SHELL_LABEL("履歴を表示"),
    SHELL_LABEL("記録を開始"),
    SHELL_LABEL("記録を一時停止"),
    SHELL_LABEL("設定"),
    SHELL_LABEL("終了"),
    SHELL_LABEL("記録中"),
    SHELL_LABEL("一時停止中"),
    SHELL_LABEL("Clipboard - 記録中"),
    SHELL_LABEL("Clipboard - 一時停止中"),
  },
  { /* ko */
    SHELL_LABEL("기록 표시"),
    SHELL_LABEL("기록 시작"),
    SHELL_LABEL("기록 일시 정지"),
    SHELL_LABEL("설정"),
    SHELL_LABEL("종료"),
    SHELL_LABEL("기록 중"),
    SHELL_LABEL("일시 정지됨"),
    SHELL_LABEL("Clipboard - 기록 중"),
    SHELL_LABEL("Clipboard - 일시 정지됨"),
  },
  { /* de */
    SHELL_LABEL("Verlauf anzeigen"),
    SHELL_LABEL("Aufzeichnung starten"),
    SHELL_LABEL("Aufzeichnung pausieren"),
    SHELL_LABEL("Einstellungen"),
    SHELL_LABEL("Beenden"),
    SHELL_LABEL("Aufzeichnung läuft"),
    SHELL_LABEL("Pausiert"),
    SHELL_LABEL("Clipboard - Aufzeichnung läuft"),
    SHELL_LABEL("Clipboard - Pausiert"),
  },
  { /* es */
    SHELL_LABEL("Mostrar historial"),
    SHELL_LABEL("Iniciar registro"),
    SHELL_LABEL("Pausar registro"),
    SHELL_LABEL("Ajustes"),
    SHELL_LABEL("Salir"),
    SHELL_LABEL("Registrando"),
    SHELL_LABEL("Pausado"),
    SHELL_LABEL("Clipboard - Registrando"),
    SHELL_LABEL("Clipboard - Pausado"),
  },
};
static const shell_label_char *shell_label(int language, int label) {
  if (language < 0 || language >= 7) language = 0;
  if (label < 0 || label >= 9) return SHELL_LABEL("");
  return shell_labels[language][label];
}
#undef SHELL_LABEL
#endif

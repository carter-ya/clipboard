import Foundation

enum DesktopLocalization {
  static func isChinese(_ language: String?) -> Bool {
    (language ?? Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
  }
  static func text(_ value: String, language: String?) -> String {
    guard isChinese(language) else { return value }
    if value.hasSuffix(" items"), let number = value.split(separator: " ").first, Int(number) != nil
    {
      return "\(number) 条"
    }
    return chinese[value] ?? value
  }
  private static let chinese: [String: String] = [
    "Preview truncated. Copy keeps the full text.": "预览已截断，复制仍会保留完整文字。",
    "Clipboard could not safely open this profile.": "无法安全打开此配置。",
    "Close another instance or check the desktop session, then try again.": "请关闭其他实例或检查桌面会话后重试。",
    "Quit": "退出",
    "Clipboard capture is unavailable on this Wayland desktop. Copy remains available.":
      "此 Wayland 桌面不支持后台读取剪贴板，仍可复制历史内容。",
    "Wayland does not identify clipboard source apps. App exclusions cannot match unknown sources; sensitive hints still apply.":
      "Wayland 不提供剪贴板来源应用信息，应用排除规则无法匹配未知来源；敏感标记仍然有效。",
    "Waiting for the desktop shortcut portal.": "正在等待桌面快捷键授权服务。",
    "Apply the shortcut to request permission from your desktop.": "应用快捷键后，可向桌面请求使用权限。",
    "Shortcut permission was declined. Apply again to retry.": "快捷键授权被拒绝，可再次应用以重试。",
    "The global shortcut portal is unavailable on this Wayland desktop.":
      "此 Wayland 桌面不提供全局快捷键授权服务。",
    "The desktop manages this shortcut. Its assigned keys may differ from the preference.":
      "快捷键由桌面管理，实际按键可能与首选设置不同。",
    "Your clipboard history, on this device.": "此设备上的剪贴板历史。",
    "Filters": "筛选", "Hide filters": "收起筛选", "All": "全部", "All types": "全部类型", "Text": "文本",
    "Rtf": "富文本", "Image": "图片", "File": "文件",
    "Pinned": "置顶", "Preview": "预览", "Local history": "本地历史", "Source: ": "来源：",
    "Search history": "搜索历史", "Source app ID (optional)": "来源应用标识（可选）",
    "Start recording": "开始录制", "Pause recording": "暂停录制", "Hide": "隐藏", "Settings": "设置",
    "Copy": "复制", "Copy result": "复制结果", "Pin / unpin": "置顶／取消置顶", "Delete": "删除",
    "Copy here, then paste in your app.": "在此复制，然后在目标应用中粘贴。",
    "Preferences": "偏好设置", "Back to history": "返回历史", "Quit Clipboard": "退出 Clipboard",
    "History stays on this device. Sensitive items stay in memory.": "历史保存在此设备，敏感条目仅保留在内存。",
    "History capacity (1–5000)": "历史容量（1–5000）",
    "Maximum clipboard item (MiB, 1–16)": "单条大小上限（MiB，1–16）",
    "Mark blocked source apps as sensitive": "将受限来源应用的内容标记为敏感",
    "Blocked app IDs, separated by commas": "受限应用标识，以逗号分隔", "Save content settings": "保存内容设置",
    "Export history": "导出历史", "Import history": "导入历史", "Clear history": "清空历史",
    "Delete all history, including pinned items?": "删除所有历史，包括置顶条目？", "Delete all history": "删除全部历史",
    "Cancel": "取消",
    "Enable global shortcut": "启用全局快捷键", "Apply shortcut": "应用快捷键",
    "Keep running when closing the window": "关闭窗口后继续运行", "Show history when starting": "启动时显示历史",
    "Record when starting": "启动时录制", "Save behavior": "保存行为设置", "Recording: On": "录制：开启",
    "Recording: Paused": "录制：已暂停",
    "System services": "系统服务", "Enable launch at login": "启用登录后启动",
    "Disable launch at login": "停用登录后启动",
    "Local OCR uses installed system language packs. Apple-only models are unavailable here.":
      "本地 OCR 使用已安装的语言包，此平台不提供 Apple 专属模型。",
    "Automatically recognize images": "自动识别图片中的文字",
    "Remote AI is off by default. Enabling it sends eligible content to your chosen endpoint.":
      "远程 AI 默认关闭。启用后，符合条件的内容会发送到指定服务。",
    "Enable remote AI": "启用远程 AI", "Allow image uploads": "允许上传图片",
    "Automatically summarize new items": "自动总结新条目",
    "API endpoint": "API 服务地址", "Model name": "模型名称", "API key": "API 密钥",
    "Save API key": "保存 API 密钥",
    "Delete API key": "删除 API 密钥", "Use saved API key": "使用已保存的 API 密钥",
    "Save AI settings": "保存 AI 设置",
    "Recognize text": "识别文字", "Summarize": "生成摘要", "OCR / AI result": "OCR／AI 结果",
    "Appearance": "外观", "System": "跟随系统", "Light": "浅色", "Dark": "深色", "Language": "语言",
    "System language": "系统语言",
    "Ready": "就绪", "Loading history": "正在加载历史", "Copied to clipboard": "已复制到剪贴板",
    "Item pinned": "已置顶", "Item unpinned": "已取消置顶", "Item deleted": "条目已删除",
    "Recording paused": "录制已暂停", "Recording clipboard": "正在录制剪贴板", "Settings saved": "设置已保存",
    "Settings could not be saved.": "无法保存设置。", "History could not be opened.": "无法打开历史。",
    "Clipboard is unavailable in this session.": "当前桌面会话无法使用剪贴板。",
    "Saved settings could not be read. Recording starts paused.": "无法读取已保存的设置，录制将保持暂停。",
    "The global shortcut is already in use. Choose another in Settings.": "全局快捷键已被占用，请在设置中选择其他组合。",
    "The global shortcut is unavailable in this desktop session.": "当前桌面会话无法注册全局快捷键。",
    "System tray unavailable in this desktop session. Use the global shortcut to reopen.":
      "当前桌面不提供托盘，可用全局快捷键重新打开。",
    "System tray unavailable in this desktop session. Closing this window quits Clipboard.":
      "当前桌面不提供托盘，关闭窗口将退出 Clipboard。",
    "Shortcut saved": "快捷键已保存",
    "Shortcut already in use. Previous binding kept.": "快捷键已被占用，已保留原组合。",
    "Shortcut could not be saved. Previous settings kept.": "无法保存快捷键，已保留原设置。",
    "Enter a capacity of 1–5000 and a size of 1–16 MiB.": "请输入 1–5000 的容量和 1–16 MiB 的大小。",
    "Content settings saved": "内容设置已保存", "Content settings could not be saved.": "无法保存内容设置。",
    "History cleared": "历史已清空", "History exported. Sensitive items excluded.": "历史已导出，未包含敏感条目。",
    "Export failed. Check the destination and archive size (256 MiB maximum).":
      "导出失败，请检查目标位置和归档大小（最大 256 MiB）。",
    "Import failed. Choose a self-contained Clipboard JSON archive.":
      "导入失败，请选择完整的 Clipboard JSON 归档。",
    "Startup integration is unavailable in this session.": "当前会话无法设置开机启动。",
    "Startup setting saved": "开机启动设置已保存", "Startup setting could not be changed.": "无法更改开机启动设置。",
    "AI settings saved": "AI 设置已保存",
    "Check the model and endpoint. Use HTTPS, or HTTP for a loopback server.":
      "请检查模型与服务地址，使用 HTTPS 或本机回环 HTTP 地址。",
    "API key saved in the system credential store. Save AI settings to use it.":
      "API 密钥已保存到系统凭据存储，请保存 AI 设置以使用它。",
    "API key deleted. Save AI settings to update the connection.": "API 密钥已删除，请保存 AI 设置以更新连接。",
    "Secure credential storage is unavailable or locked.": "系统安全凭据存储不可用或已锁定。",
    "Secure credential storage is unavailable or locked. No plaintext fallback was used.":
      "系统安全凭据存储不可用或已锁定，未将密钥改存为明文。",
    "No text was recognized.": "未识别到文字。", "Summary ready": "摘要已生成", "OCR text ready": "OCR 文字已生成",
    "Analysis cancelled": "分析已取消",
    "Summary unavailable. Check AI settings and the connection.": "无法生成摘要，请检查 AI 设置和网络连接。",
    "OCR unavailable. Check the image and installed OCR language packs.":
      "无法识别文字，请检查图片和已安装的 OCR 语言包。",
    "Appearance saved": "外观已保存", "Language saved": "语言已保存",
  ]
}

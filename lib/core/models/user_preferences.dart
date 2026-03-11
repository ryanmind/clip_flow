import 'package:clip_flow/core/constants/clip_constants.dart';
import 'package:flutter/material.dart';

/// UI 界面模式（传统剪贴板/应用切换器）。
enum UiMode {
  /// 经典剪贴板历史界面。
  classic,

  /// 紧凑型 App Switcher 界面。
  compact,
}

/// 不可变的用户偏好设置，并提供 JSON 序列化/反序列化。
class UserPreferences {
  /// 构造函数：提供默认值。
  UserPreferences({
    this.autoStart = false,
    this.minimizeToTray = true,
    this.globalHotkey = 'Cmd+Shift+V',
    this.maxHistoryItems = ClipConstants.maxHistoryItems,
    this.enableEncryption = true,
    this.enableOCR = true,
    this.ocrLanguage = 'auto',
    this.ocrMinConfidence = 0.5,
    this.language = 'zh_CN',
    this.uiMode = UiMode.classic,
    this.isDeveloperMode = false,
    this.showPerformanceOverlay = false,
    this.autoHideEnabled = true,
    this.compactModeWindowWidth,
    this.autoHideTimeoutSeconds = 3,
    this.themeMode = ThemeMode.system,
  });

  /// 从 JSON Map 创建 [UserPreferences] 实例。
  factory UserPreferences.fromJson(Map<String, dynamic> json) {
    return UserPreferences(
      autoStart: (json['autoStart'] as bool?) ?? false,
      minimizeToTray: (json['minimizeToTray'] as bool?) ?? true,
      globalHotkey: (json['globalHotkey'] as String?) ?? 'Cmd+Shift+V',
      maxHistoryItems:
          (json['maxHistoryItems'] as int?) ?? ClipConstants.maxHistoryItems,
      enableEncryption: (json['enableEncryption'] as bool?) ?? true,
      enableOCR: (json['enableOCR'] as bool?) ?? true,
      ocrLanguage: (json['ocrLanguage'] as String?) ?? 'auto',
      ocrMinConfidence: ((json['ocrMinConfidence'] as num?) ?? 0.5).toDouble(),
      language: (json['language'] as String?) ?? 'zh_CN',
      uiMode: UiMode.values.firstWhere(
        (e) => e.name == (json['uiMode'] as String?),
        orElse: () => UiMode.classic,
      ),
      isDeveloperMode: (json['isDeveloperMode'] as bool?) ?? false,
      showPerformanceOverlay:
          (json['showPerformanceOverlay'] as bool?) ?? false,
      autoHideEnabled: (json['autoHideEnabled'] as bool?) ?? true,
      compactModeWindowWidth: json['compactModeWindowWidth'] as double?,
      autoHideTimeoutSeconds: (json['autoHideTimeoutSeconds'] as int?) ?? 3,
      themeMode: ThemeMode.values.firstWhere(
        (e) => e.name == (json['themeMode'] as String?),
        orElse: () => ThemeMode.system,
      ),
    );
  }

  /// 是否开机自启动。
  final bool autoStart;

  /// 关闭窗口是否最小化到托盘。
  final bool minimizeToTray;

  /// 全局快捷键。
  final String globalHotkey;

  /// 历史记录最大保留条数。
  final int maxHistoryItems;

  /// 是否启用加密。
  final bool enableEncryption;

  /// 是否启用 OCR。
  final bool enableOCR;

  /// OCR 识别语言（包含 `auto` 自动识别）。
  final String ocrLanguage;

  /// OCR 最小置信度阈值 (0.0 - 1.0)。
  final double ocrMinConfidence;

  /// 显示语言代码（如 `zh_CN`）。
  final String language;

  /// UI 界面模式（传统剪贴板/应用切换器）。
  final UiMode uiMode;

  /// 是否启用开发者模式。
  final bool isDeveloperMode;

  /// 是否显示性能监控覆盖层。
  final bool showPerformanceOverlay;

  /// 是否启用自动隐藏。
  final bool autoHideEnabled;

  /// 紧凑模式的窗口宽度（null 表示使用默认计算值）。
  final double? compactModeWindowWidth;

  /// 自动隐藏超时时间（秒）。
  final int autoHideTimeoutSeconds;

  /// 主题模式（系统/浅色/深色）。
  final ThemeMode themeMode;

  /// 返回复制的新实例，并按需覆盖指定字段。
  UserPreferences copyWith({
    bool? autoStart,
    bool? minimizeToTray,
    String? globalHotkey,
    int? maxHistoryItems,
    bool? enableEncryption,
    bool? enableOCR,
    String? ocrLanguage,
    double? ocrMinConfidence,
    String? language,
    UiMode? uiMode,
    bool? isDeveloperMode,
    bool? showPerformanceOverlay,
    bool? autoHideEnabled,
    double? compactModeWindowWidth,
    int? autoHideTimeoutSeconds,
    ThemeMode? themeMode,
  }) {
    return UserPreferences(
      autoStart: autoStart ?? this.autoStart,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      globalHotkey: globalHotkey ?? this.globalHotkey,
      maxHistoryItems: maxHistoryItems ?? this.maxHistoryItems,
      enableEncryption: enableEncryption ?? this.enableEncryption,
      enableOCR: enableOCR ?? this.enableOCR,
      ocrLanguage: ocrLanguage ?? this.ocrLanguage,
      ocrMinConfidence: ocrMinConfidence ?? this.ocrMinConfidence,
      language: language ?? this.language,
      uiMode: uiMode ?? this.uiMode,
      isDeveloperMode: isDeveloperMode ?? this.isDeveloperMode,
      showPerformanceOverlay:
          showPerformanceOverlay ?? this.showPerformanceOverlay,
      autoHideEnabled: autoHideEnabled ?? this.autoHideEnabled,
      compactModeWindowWidth:
          compactModeWindowWidth ?? this.compactModeWindowWidth,
      autoHideTimeoutSeconds:
          autoHideTimeoutSeconds ?? this.autoHideTimeoutSeconds,
      themeMode: themeMode ?? this.themeMode,
    );
  }

  /// 序列化为 JSON Map。
  Map<String, dynamic> toJson() {
    return {
      'autoStart': autoStart,
      'minimizeToTray': minimizeToTray,
      'globalHotkey': globalHotkey,
      'maxHistoryItems': maxHistoryItems,
      'enableEncryption': enableEncryption,
      'enableOCR': enableOCR,
      'ocrLanguage': ocrLanguage,
      'ocrMinConfidence': ocrMinConfidence,
      'language': language,
      'uiMode': uiMode.name,
      'isDeveloperMode': isDeveloperMode,
      'showPerformanceOverlay': showPerformanceOverlay,
      'autoHideEnabled': autoHideEnabled,
      'compactModeWindowWidth': compactModeWindowWidth,
      'autoHideTimeoutSeconds': autoHideTimeoutSeconds,
      'themeMode': themeMode.name,
    };
  }
}

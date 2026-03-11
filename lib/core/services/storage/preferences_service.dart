import 'dart:async';
import 'dart:convert';

import 'package:clip_flow/core/models/user_preferences.dart';
import 'package:clip_flow/core/services/observability/index.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户偏好设置持久化服务（单例）
///
/// 使用 SharedPreferences 进行用户偏好设置的持久化存储：
/// - 提供保存和加载用户偏好设置的方法
/// - 支持 JSON 序列化/反序列化
/// - 使用常量键名确保一致性
class PreferencesService {
  /// 工厂构造：返回单例实例
  factory PreferencesService() => _instance;

  /// 私有构造函数
  PreferencesService._internal();

  /// 单例实例
  static final PreferencesService _instance = PreferencesService._internal();

  /// SharedPreferences 实例
  SharedPreferences? _prefs;

  /// 用户偏好设置的存储键
  static const String _userPreferencesKey = 'user_preferences';

  /// 初始化服务
  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 内存缓存
  UserPreferences? _cachedPreferences;

  /// 保存用户偏好设置
  ///
  /// 参数：
  /// - preferences: 要保存的用户偏好设置
  ///
  /// 返回：保存是否成功
  Future<bool> savePreferences(UserPreferences preferences) async {
    await initialize();
    if (_prefs == null) return false;

    // 更新内存缓存
    _cachedPreferences = preferences;

    try {
      final jsonString = jsonEncode(preferences.toJson());
      return await _prefs!.setString(_userPreferencesKey, jsonString);
    } on Exception catch (e) {
      // 记录错误但不抛出异常
      unawaited(
        Log.e('Failed to save preferences', tag: 'preferences', error: e),
      );
      return false;
    }
  }

  /// 加载用户偏好设置
  ///
  /// 返回：用户偏好设置，如果不存在则返回默认设置
  Future<UserPreferences> loadPreferences() async {
    // 优先返回内存缓存
    if (_cachedPreferences != null) {
      return _cachedPreferences!;
    }

    await initialize();
    if (_prefs == null) return UserPreferences();

    try {
      final jsonString = _prefs!.getString(_userPreferencesKey);
      if (jsonString == null) {
        final defaultPrefs = UserPreferences();
        _cachedPreferences = defaultPrefs;
        return defaultPrefs;
      }

      final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final prefs = UserPreferences.fromJson(jsonMap);
      _cachedPreferences = prefs;
      return prefs;
    } on Exception catch (e) {
      // 如果解析失败，返回默认设置
      unawaited(
        Log.e('Failed to load preferences', tag: 'preferences', error: e),
      );
      return UserPreferences();
    }
  }

  /// 清除所有用户偏好设置
  ///
  /// 返回：清除是否成功
  Future<bool> clearPreferences() async {
    await initialize();
    if (_prefs == null) return false;

    // 清除内存缓存
    _cachedPreferences = null;

    try {
      return await _prefs!.remove(_userPreferencesKey);
    } on Exception catch (e) {
      // 记录错误但不抛出异常
      unawaited(
        Log.e('Failed to clear preferences', tag: 'preferences', error: e),
      );
      return false;
    }
  }

  /// 检查是否存在保存的偏好设置
  ///
  /// 返回：是否存在保存的设置
  Future<bool> hasPreferences() async {
    await initialize();
    if (_prefs == null) return false;

    return _prefs!.containsKey(_userPreferencesKey);
  }

  /// 获取偏好设置信息
  ///
  /// 返回：包含设置信息的 Map
  Future<Map<String, dynamic>> getPreferencesInfo() async {
    await initialize();
    if (_prefs == null) {
      return {
        'hasPreferences': false,
        'dataSize': 0,
        'lastModified': null,
      };
    }

    final hasPrefs = _prefs!.containsKey(_userPreferencesKey);
    final jsonString = _prefs!.getString(_userPreferencesKey);

    return {
      'hasPreferences': hasPrefs,
      'dataSize': jsonString?.length ?? 0,
      'lastModified': hasPrefs ? DateTime.now().toIso8601String() : null,
    };
  }

  /// 保存字符串值
  ///
  /// 参数：
  /// - key: 存储键
  /// - value: 要保存的字符串值
  ///
  /// 返回：保存是否成功
  Future<bool> setString(String key, String value) async {
    await initialize();
    if (_prefs == null) return false;

    try {
      return await _prefs!.setString(key, value);
    } on Exception catch (e) {
      unawaited(
        Log.e('Failed to save string value', tag: 'preferences', error: e),
      );
      return false;
    }
  }

  /// 获取字符串值
  ///
  /// 参数：
  /// - key: 存储键
  ///
  /// 返回：字符串值，如果不存在则返回 null
  Future<String?> getString(String key) async {
    await initialize();
    if (_prefs == null) return null;

    try {
      return _prefs!.getString(key);
    } on Exception catch (e) {
      unawaited(
        Log.e('Failed to get string value', tag: 'preferences', error: e),
      );
      return null;
    }
  }
}

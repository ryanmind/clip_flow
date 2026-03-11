import 'dart:async';
import 'dart:io';

import 'package:clip_flow/core/models/user_preferences.dart';
import 'package:clip_flow/core/services/observability/index.dart';
import 'package:clip_flow/core/services/platform/system/window_listener.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// ignore_for_file: public_member_api_docs  内部服务模块，托盘服务不需要对外暴露API文档

/// 系统托盘服务
///
/// 负责管理系统托盘图标、菜单和窗口控制功能
class TrayService with TrayListener {
  factory TrayService() => _instance;
  TrayService._internal();
  static final TrayService _instance = TrayService._internal();

  bool _isInitialized = false;
  Completer<void>? _initializing;
  UserPreferences? _userPreferences;

  /// 托盘交互回调（用于通知外部托盘已被激活，例如重置自动隐藏状态）
  VoidCallback? onTrayInteraction;

  /// 窗口显示回调
  VoidCallback? onWindowShown;

  /// 窗口隐藏回调
  VoidCallback? onWindowHidden;

  /// 初始化系统托盘服务（并发安全）
  Future<void> initialize([UserPreferences? userPreferences]) async {
    if (_isInitialized) {
      await Log.i('TrayService already initialized');
      return;
    }

    // 若已有初始化过程在进行，等待其完成以避免重复初始化
    if (_initializing != null) {
      await Log.i('TrayService is initializing, awaiting existing process');
      await _initializing!.future;
      return;
    }

    _initializing = Completer<void>();

    try {
      _userPreferences = userPreferences;

      // 设置托盘图标
      await _setTrayIcon();

      // 设置托盘菜单
      await _setTrayMenu();

      // 注册托盘监听器
      trayManager.addListener(this);

      _isInitialized = true;
      await Log.i('TrayService initialized successfully');
    } catch (e, stackTrace) {
      await Log.e(
        'Failed to initialize TrayService: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      // 完成初始化过程标记
      _initializing?.complete();
      _initializing = null;
    }
  }

  /// 销毁托盘服务
  Future<void> dispose() async {
    if (!_isInitialized) return;

    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
      _isInitialized = false;
      await Log.i('TrayService disposed');
    } on Exception catch (e, stackTrace) {
      await Log.e(
        'Failed to dispose TrayService: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 设置托盘图标
  Future<void> _setTrayIcon() async {
    try {
      // 使用项目中的图标文件
      await trayManager.setIcon('assets/icons/clipflow_icon_192.png');
      await Log.i('Tray icon set successfully');
    } on Exception catch (e, stackTrace) {
      await Log.e(
        'Failed to set tray icon: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 设置托盘菜单
  Future<void> _setTrayMenu() async {
    try {
      final menu = Menu(
        items: [
          MenuItem(
            key: 'show',
            label: '显示窗口',
          ),
          MenuItem(
            key: 'hide',
            label: '隐藏窗口',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'settings',
            label: '设置',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'quit',
            label: '退出',
          ),
        ],
      );

      await trayManager.setContextMenu(menu);
      await Log.i('Tray menu set successfully');
    } on Exception catch (e, stackTrace) {
      await Log.e(
        'Failed to set tray menu: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 显示窗口
  Future<void> showWindow() async {
    try {
      final windowService = WindowManagementService.instance;
      await windowService.showAndFocus();
      onWindowShown?.call();
      await Log.i('Window shown and focused via WindowManagementService');
    } on Exception catch (e, stackTrace) {
      await Log.e(
        'Failed to show window: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 隐藏窗口
  Future<void> hideWindow() async {
    try {
      final windowService = WindowManagementService.instance;
      await windowService.hide();
      onWindowHidden?.call();
      await Log.i('Window hidden via WindowManagementService');
    } on Exception catch (e, stackTrace) {
      await Log.e(
        'Failed to hide window: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 切换窗口显示状态
  Future<void> toggleWindow() async {
    try {
      final isVisible = await windowManager.isVisible();
      final isMinimized = await windowManager.isMinimized();

      await Log.i(
        'toggleWindow called',
        tag: 'TrayService',
        fields: {
          'isVisible': isVisible,
          'isMinimized': isMinimized,
        },
      );

      if (isVisible && !isMinimized) {
        // 窗口可见且未最小化，则隐藏窗口
        await Log.i('Hiding window', tag: 'TrayService');
        await hideWindow();
      } else {
        // 窗口隐藏或最小化，则显示并聚焦窗口
        await Log.i('Showing window', tag: 'TrayService');

        // 先取消最小化状态（如果是最小化状态）
        if (isMinimized) {
          await Log.i('Restoring minimized window', tag: 'TrayService');
          await windowManager.restore();
        }

        // 显示窗口
        await showWindow();

        // 尝试多种方法确保窗口在前台
        await Log.i('Attempting to bring window to front', tag: 'TrayService');
        await windowManager.focus();

        // 在macOS上，使用原生API激活应用
        if (Platform.isMacOS) {
          await Log.i('Activating application on macOS', tag: 'TrayService');
          try {
            // 使用延迟确保窗口操作完成
            await Future<void>.delayed(const Duration(milliseconds: 100));

            // 调用原生方法激活应用
            const channel = MethodChannel('clipboard_service');
            await channel.invokeMethod<bool>('activateApp');

            await Log.i('App activation completed', tag: 'TrayService');
          } on Exception catch (e) {
            await Log.w(
              'Failed to activate app via native method: $e',
              tag: 'TrayService',
            );

            // 回退到窗口管理器方法
            await windowManager.focus();
            await windowManager.show();
          }
        }
      }
    } on Exception catch (e, stackTrace) {
      await Log.e(
        'Failed to toggle window: $e',
        tag: 'TrayService',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 退出应用
  Future<void> exitApp() async {
    try {
      await Log.i('Exiting application from tray');
      await windowManager.destroy();
    } on Exception catch (e, stackTrace) {
      await Log.e('Failed to exit app: $e', error: e, stackTrace: stackTrace);
    }
  }

  /// 检查是否应该最小化到托盘
  bool get shouldMinimizeToTray {
    try {
      // 与用户偏好默认值保持一致：默认为 true
      return _userPreferences?.minimizeToTray ?? true;
    } on Exception catch (_) {
      // 同步方法中不能使用await，所以这里只返回默认值
      return true;
    }
  }

  /// 处理窗口关闭事件
  Future<void> handleWindowClose() async {
    if (shouldMinimizeToTray) {
      await hideWindow();
      await Log.i('Window minimized to tray');
    } else {
      await windowManager.close();
    }
  }

  /// 更新用户偏好设置
  set userPreferences(UserPreferences preferences) {
    _userPreferences = preferences;
  }

  /// 获取用户偏好设置
  UserPreferences get userPreferences => _userPreferences ?? UserPreferences();
  // TrayListener 实现

  @override
  void onTrayIconMouseDown() {
    // 托盘图标被点击
    onTrayInteraction?.call();
    unawaited(toggleWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // 托盘图标被右键点击，显示上下文菜单
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // 处理托盘菜单项点击
    switch (menuItem.key) {
      case 'show':
        onTrayInteraction?.call();
        unawaited(showWindow());
      case 'hide':
        unawaited(hideWindow());
      case 'settings':
        // 显示设置页面
        unawaited(showWindow());
      case 'quit':
        unawaited(exitApp());
    }
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 剪贴板监听管理器
///
/// 优先订阅原生事件流，只有在事件流不可用时才回退到 Dart 侧轮询。
class ClipboardPoller {
  static const MethodChannel _platformChannel = MethodChannel(
    'clipboard_service',
  );
  static const EventChannel _eventsChannel = EventChannel('clipboard_events');

  static const Duration _fallbackInterval = Duration(milliseconds: 500);
  static const Duration _rapidCopyWindow = Duration(seconds: 1);
  static const Duration _rapidCopyTimeout = Duration(seconds: 5);
  static const int _rapidCopyThreshold = 3;
  static const int _idleThreshold = 20;

  // ignore: cancel_subscriptions, reason: cancelled via _cancelActiveMonitoring
  StreamSubscription<dynamic>? _eventsSubscription;
  Timer? _fallbackTimer;
  Timer? _debounceTimer;

  Duration _currentInterval = Duration.zero;
  bool _isPolling = false;
  bool _isPaused = false;
  bool _isIdleMode = false;
  bool _isProcessingCallback = false;
  bool _isRapidCopyMode = false;
  bool _isUsingFallbackPolling = false;

  int _lastClipboardSequence = -1;
  int _consecutiveNoChangeCount = 0;
  int _rapidCopyCount = 0;
  int _totalChecks = 0;
  int _successfulChecks = 0;
  int _failedChecks = 0;
  int _totalNativeEvents = 0;

  DateTime? _lastRapidCopyTime;
  DateTime? _lastChangeTime;
  DateTime? _monitoringStartTime;
  Duration _totalMonitoringTime = Duration.zero;
  final List<DateTime> _recentChanges = [];

  VoidCallback? _onClipboardChanged;
  void Function(String error)? _onError;

  /// 开始监听
  void startPolling({
    VoidCallback? onClipboardChanged,
    void Function(String error)? onError,
  }) {
    if (_isPolling && !_isPaused) {
      return;
    }

    _onClipboardChanged = onClipboardChanged;
    _onError = onError;
    _isPolling = true;
    _isPaused = false;
    _monitoringStartTime = DateTime.now();

    _startMonitoring();
  }

  /// 停止监听
  void stopPolling() {
    _cancelActiveMonitoring();
    _isPolling = false;
    _isPaused = false;

    _onClipboardChanged = null;
    _onError = null;

    if (_monitoringStartTime != null) {
      _totalMonitoringTime += DateTime.now().difference(_monitoringStartTime!);
      _monitoringStartTime = null;
    }

    _resetRuntimeState();
  }

  /// 暂停监听
  void pausePolling() {
    if (!_isPolling) {
      return;
    }

    _cancelActiveMonitoring();
    _isPaused = true;

    if (_monitoringStartTime != null) {
      _totalMonitoringTime += DateTime.now().difference(_monitoringStartTime!);
      _monitoringStartTime = null;
    }
  }

  /// 恢复监听
  void resumePolling() {
    if (!_isPolling || !_isPaused) {
      return;
    }

    _isPaused = false;
    _monitoringStartTime = DateTime.now();
    _startMonitoring();
  }

  /// 手动触发一次检查
  Future<bool> checkOnce() async {
    _totalChecks++;

    try {
      final hasChanged = await _checkClipboardChange();
      if (hasChanged) {
        _successfulChecks++;
      } else {
        _recordNoChange();
      }
      return hasChanged;
    } on Exception catch (e) {
      _failedChecks++;
      _onError?.call('手动检查失败: $e');
      rethrow;
    }
  }

  /// 当前监控节奏；事件模式下为 0，轮询回退时为当前轮询间隔。
  Duration get currentInterval => _currentInterval;

  /// 当前是否处于活动监听状态。
  bool get isPolling => _isPolling && !_isPaused;

  /// 是否处于空闲模式。
  bool get isIdleMode => _isIdleMode;

  void _startMonitoring() {
    _cancelActiveMonitoring();
    _startNativeEventMonitoring();
  }

  void _startNativeEventMonitoring() {
    _isUsingFallbackPolling = false;
    _currentInterval = Duration.zero;

    _eventsSubscription = _eventsChannel.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: _handleNativeEventError,
      onDone: _handleNativeEventDone,
      cancelOnError: false,
    );
  }

  void _handleNativeEvent(dynamic event) {
    if (!_isPolling || _isPaused) {
      return;
    }

    if (event is! Map) {
      _onError?.call('收到未知格式的剪贴板事件');
      return;
    }

    final data = Map<Object?, Object?>.from(event);
    final sequence = (data['sequence'] as num?)?.toInt();
    final timestampMs = (data['timestamp'] as num?)?.toInt();
    final intervalMs = (data['monitoringIntervalMs'] as num?)?.toInt();

    if (sequence != null && sequence == _lastClipboardSequence) {
      return;
    }

    if (sequence != null) {
      _lastClipboardSequence = sequence;
    }

    _totalChecks++;
    _successfulChecks++;
    _totalNativeEvents++;
    _currentInterval = intervalMs != null && intervalMs > 0
        ? Duration(milliseconds: intervalMs)
        : Duration.zero;

    final eventTime = timestampMs == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(timestampMs);
    _recordChange(eventTime);
    _onClipboardChanged?.call();
  }

  void _handleNativeEventError(Object error, StackTrace _) {
    if (!_isPolling || _isPaused) {
      return;
    }

    _failedChecks++;
    _switchToFallbackPolling('剪贴板事件流失败: $error');
  }

  void _handleNativeEventDone() {
    if (!_isPolling || _isPaused || _isUsingFallbackPolling) {
      return;
    }

    _switchToFallbackPolling('剪贴板事件流已结束');
  }

  void _switchToFallbackPolling(String reason) {
    _cancelActiveMonitoring();
    _isUsingFallbackPolling = true;
    _currentInterval = _fallbackInterval;
    _onError?.call('$reason，已回退到轮询监听');
    _scheduleNextFallbackPoll();
  }

  void _scheduleNextFallbackPoll() {
    if (!_isPolling || _isPaused || !_isUsingFallbackPolling) {
      return;
    }

    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(_currentInterval, () async {
      if (!_isPolling || _isPaused || !_isUsingFallbackPolling) {
        return;
      }

      if (_isProcessingCallback) {
        return;
      }

      _isProcessingCallback = true;
      try {
        _totalChecks++;
        final hasChanged = await _checkClipboardChange();
        if (hasChanged) {
          _successfulChecks++;
          _onClipboardChanged?.call();
        } else {
          _recordNoChange();
        }
      } on Exception catch (e) {
        _failedChecks++;
        _onError?.call('轮询检查失败: $e');
      } finally {
        _isProcessingCallback = false;
        _scheduleNextFallbackPoll();
      }
    });
  }

  void _cancelActiveMonitoring() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;

    final subscription = _eventsSubscription;
    _eventsSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }

  Future<bool> _checkClipboardChange() async {
    try {
      final currentSequence = await _getClipboardSequence();
      if (currentSequence != _lastClipboardSequence) {
        _lastClipboardSequence = currentSequence;
        _recordChange();
        return true;
      }
      return false;
    } on Exception catch (_) {
      return _fallbackContentCheck();
    }
  }

  Future<int> _getClipboardSequence() async {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      try {
        final result = await _platformChannel.invokeMethod<int>(
          'getClipboardSequence',
        );
        return result ?? -1;
      } on Exception catch (e) {
        throw Exception('无法获取剪贴板序列号: $e');
      }
    }

    throw Exception('不支持的平台');
  }

  String? _lastClipboardContent;

  Future<bool> _fallbackContentCheck() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final currentContent = clipboardData?.text;

      if (currentContent != _lastClipboardContent) {
        _lastClipboardContent = currentContent;
        _recordChange();
        return true;
      }

      return false;
    } on Exception catch (e) {
      throw Exception('回退内容检查失败: $e');
    }
  }

  void _recordChange([DateTime? timestamp]) {
    final now = timestamp ?? DateTime.now();
    _recentChanges
      ..add(now)
      ..removeWhere(
        (change) => now.difference(change).inSeconds > 8,
      );

    _consecutiveNoChangeCount = 0;
    _isIdleMode = false;
    _lastChangeTime = now;
    _detectRapidCopyMode(now);
  }

  void _recordNoChange() {
    _consecutiveNoChangeCount++;
    _isIdleMode = _consecutiveNoChangeCount >= _idleThreshold;
  }

  void _detectRapidCopyMode(DateTime now) {
    if (_lastRapidCopyTime != null &&
        now.difference(_lastRapidCopyTime!) <= _rapidCopyWindow) {
      _rapidCopyCount++;
      if (_rapidCopyCount >= _rapidCopyThreshold) {
        _isRapidCopyMode = true;
        _debounceTimer?.cancel();
        _debounceTimer = Timer(_rapidCopyTimeout, () {
          _isRapidCopyMode = false;
          _rapidCopyCount = 0;
        });
      }
    } else {
      _rapidCopyCount = 1;
    }

    _lastRapidCopyTime = now;
  }

  void _resetRuntimeState() {
    _currentInterval = Duration.zero;
    _lastClipboardSequence = -1;
    _lastClipboardContent = null;
    _consecutiveNoChangeCount = 0;
    _recentChanges.clear();
    _isIdleMode = false;
    _isRapidCopyMode = false;
    _isUsingFallbackPolling = false;
    _lastRapidCopyTime = null;
    _rapidCopyCount = 0;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// 获取监听统计信息。
  Map<String, dynamic> getPollingStats() {
    final now = DateTime.now();
    final currentSessionTime = _monitoringStartTime != null
        ? now.difference(_monitoringStartTime!)
        : Duration.zero;
    final totalTime = _totalMonitoringTime + currentSessionTime;
    final successRate = _totalChecks > 0
        ? _successfulChecks / _totalChecks
        : 0.0;
    final avgInterval = _totalChecks > 0 && totalTime.inMilliseconds > 0
        ? totalTime.inMilliseconds / _totalChecks
        : _currentInterval.inMilliseconds.toDouble();

    return {
      'isPolling': isPolling,
      'isPaused': _isPaused,
      'isIdleMode': _isIdleMode,
      'isRapidCopyMode': _isRapidCopyMode,
      'isUsingFallbackPolling': _isUsingFallbackPolling,
      'monitoringMode': _isUsingFallbackPolling
          ? 'fallback_polling'
          : (_eventsSubscription != null ? 'native_events' : 'stopped'),
      'currentInterval': _currentInterval.inMilliseconds,
      'consecutiveNoChangeCount': _consecutiveNoChangeCount,
      'recentChangesCount': _recentChanges.length,
      'totalChecks': _totalChecks,
      'successfulChecks': _successfulChecks,
      'failedChecks': _failedChecks,
      'totalNativeEvents': _totalNativeEvents,
      'successRate': (successRate * 100).toStringAsFixed(1),
      'totalPollingTime': totalTime.inSeconds,
      'averageInterval': avgInterval.toStringAsFixed(1),
      'lastChangeTime': _lastChangeTime?.toIso8601String(),
      'rapidCopyCount': _rapidCopyCount,
      'lastRapidCopyTime': _lastRapidCopyTime?.toIso8601String(),
      'performance': {
        'nativeEventMonitoring': !_isUsingFallbackPolling,
        'fallbackPollingEnabled': true,
        'rapidCopyDetection': true,
      },
    };
  }

  /// 获取性能指标。
  Map<String, dynamic> getPerformanceMetrics() {
    return {
      'pollingEfficiency': getPollingStats(),
      'resourceOptimization': {
        'idleDetection': _isIdleMode,
        'fallbackActive': _isUsingFallbackPolling,
        'nativeEventsReceived': _totalNativeEvents,
      },
    };
  }

  /// 重置统计信息。
  void resetStats() {
    _totalChecks = 0;
    _successfulChecks = 0;
    _failedChecks = 0;
    _totalNativeEvents = 0;
    _totalMonitoringTime = Duration.zero;
    _lastChangeTime = null;
  }
}

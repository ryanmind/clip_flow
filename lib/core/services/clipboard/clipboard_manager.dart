import 'dart:async';

import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/clipboard/index.dart';
import 'package:clip_flow/core/services/observability/index.dart';
import 'package:clip_flow/core/services/performance/index.dart';
import 'package:clip_flow/core/services/storage/index.dart';
import 'package:meta/meta.dart';

/// 剪贴板管理器
///
/// 整合所有性能优化，包括：
/// - 快速轮询机制
/// - 异步处理队列
/// - 批量数据库操作
/// - 智能缓存
/// - 防抖和去重
class ClipboardManager {
  /// 工厂构造：返回单例实例
  factory ClipboardManager() => _instance;

  /// 私有构造：单例内部初始化
  ClipboardManager._internal({
    Future<void> Function(List<ClipItem> items)? batchInsertOverride,
  }) : _batchInsertOverride = batchInsertOverride;

  /// 测试构造：允许替换批量写入实现，避免真实数据库依赖。
  @visibleForTesting
  ClipboardManager.test({
    Future<void> Function(List<ClipItem> items)? batchInsertOverride,
  }) : _batchInsertOverride = batchInsertOverride;

  /// 单例实例
  static final ClipboardManager _instance = ClipboardManager._internal();

  /// 剪贴板轮询器
  final ClipboardPoller _poller = ClipboardPoller();

  /// 剪贴板处理器
  final ClipboardProcessor _processor = ClipboardProcessor();

  /// 异步处理队列
  final AsyncProcessingQueue _processingQueue = AsyncProcessingQueue(
    maxConcurrentTasks: 2,
    maxQueueSize: 50,
  );

  final DatabaseService _database = DatabaseService.instance;
  final Future<void> Function(List<ClipItem> items)? _batchInsertOverride;

  // UI 流控制器
  final StreamController<ClipItem> _uiController =
      StreamController<ClipItem>.broadcast();

  // 管理器是否已销毁
  bool _isDisposed = false;
  bool _isDisposing = false;
  int _activeChangeHandlers = 0;
  Completer<void>? _drainCompleter;

  // 批量写入缓存
  final List<ClipItem> _writeBuffer = [];
  Timer? _batchWriteTimer;
  static const Duration _batchWriteDelay = Duration(milliseconds: 500);
  static const int _maxBufferSize = 50; // 批量写入最大缓冲区
  static const Duration _maxBufferAge = Duration(seconds: 2); // 最大缓冲时间

  // 性能监控
  int _totalClipsDetected = 0;
  int _totalClipsProcessed = 0;
  int _totalClipsSaved = 0;
  DateTime? _lastClipTime;

  /// 初始化管理器
  Future<void> initialize() async {
    await _database.initialize();
    _processingQueue.start();
  }

  /// 启动剪贴板监控
  void startMonitoring() {
    if (_isDisposed || _isDisposing) {
      return;
    }
    _poller.startPolling(
      onClipboardChanged: _handleClipboardChange,
      onError: _handleError,
    );
  }

  /// 停止剪贴板监控
  void stopMonitoring() {
    _stopMonitoring(flushPending: true);
  }

  void _stopMonitoring({required bool flushPending}) {
    _poller.stopPolling();
    _processingQueue.stop();
    _batchWriteTimer?.cancel();
    _batchWriteTimer = null;

    // 保存剩余的批量数据
    if (flushPending && _writeBuffer.isNotEmpty) {
      unawaited(_flushWriteBuffer());
    }
  }

  /// UI 层监听的剪贴板变化流
  Stream<ClipItem> get uiStream => _uiController.stream;

  /// 安全地向UI流发送事件
  void _safeAddToUiStream(ClipItem item) {
    if (!_isDisposed && !_uiController.isClosed) {
      try {
        _uiController.add(item);
      } on Exception catch (e) {
        unawaited(
          Log.w(
            'Failed to add item to UI stream - controller may be closed',
            tag: 'OptimizedClipboardManager',
            error: e,
            fields: {'id': item.id},
          ),
        );
      }
    }
  }

  /// 处理剪贴板变化
  Future<void> _handleClipboardChange() async {
    if (_isDisposed || _isDisposing) return;

    _activeChangeHandlers++;

    try {
      _totalClipsDetected++;
      _lastClipTime = DateTime.now();

      await Log.d(
        'Clipboard change detected',
        tag: 'OptimizedClipboardManager',
        fields: {
          'totalDetected': _totalClipsDetected,
          'isRapidCopyMode':
              _poller.getPollingStats()['isRapidCopyMode'] ?? false,
        },
      );

      // 处理剪贴板内容
      final clipItem = await _processor.processClipboardContent();
      if (clipItem == null) return;

      // 在添加到队列之前，先检查数据库中是否已存在该记录
      final existingItem = await _database.getClipItemById(clipItem.id);
      if (existingItem != null) {
        await Log.d(
          'Clip item already exists in database, updating timestamp',
          tag: 'OptimizedClipboardManager',
          fields: {
            'id': clipItem.id,
            'type': clipItem.type.name,
          },
        );

        // 更新数据库中的访问时间戳
        // 注意：保持createdAt不变，只更新updatedAt
        // createdAt代表首次创建时间，应该保持不变以维护审计追踪
        final updatedItem = existingItem.copyWith(
          updatedAt: DateTime.now(),
          // ✅ 不修改createdAt，保持数据完整性
        );
        await _database.updateClipItem(updatedItem);

        // 更新UI以确保该项目显示在最前面
        _safeAddToUiStream(updatedItem);
        return;
      }

      _totalClipsProcessed++;

      // 添加到异步处理队列
      await _addToProcessingQueue(clipItem);
    } on Exception catch (e) {
      await Log.e(
        'Failed to handle clipboard change',
        tag: 'OptimizedClipboardManager',
        error: e,
      );
    } finally {
      _activeChangeHandlers--;
      if (_isDisposing && _activeChangeHandlers == 0) {
        _drainCompleter?.complete();
        _drainCompleter = null;
      }
    }
  }

  /// 添加到处理队列
  Future<void> _addToProcessingQueue(ClipItem item) async {
    // 根据类型设置优先级
    final Priority priority;
    switch (item.type) {
      case ClipType.image:
      case ClipType.video:
        priority = Priority.low; // 图片和视频处理较慢，降低优先级
      case ClipType.file:
      case ClipType.rtf:
      case ClipType.html:
      case ClipType.audio:
        priority = Priority.normal;
      case ClipType.code:
      case ClipType.text:
      case ClipType.json:
      case ClipType.xml:
        priority = Priority.high; // 文本处理较快，提高优先级
      case ClipType.url:
      case ClipType.color:
      case ClipType.email:
        priority = Priority.normal;
    }

    final processedItem = await _processingQueue.addClipboardTask(
      item: item,
      processor: _processClipItem,
      priority: priority,
    );

    if (processedItem != null) {
      await _addToWriteBuffer(processedItem);
      // 向 UI 流发射事件，确保 UI 能立即响应新内容
      _safeAddToUiStream(processedItem);
    }
  }

  /// 处理剪贴板项目（OCR等耗时操作）
  Future<ClipItem?> _processClipItem(ClipItem item) async {
    try {
      await Log.d(
        'Processing clip item',
        tag: 'OptimizedClipboardManager',
        fields: {
          'id': item.id,
          'type': item.type.name,
        },
      );

      // 如果是图片且需要OCR，这里已经由ClipboardProcessor处理过了
      // 所以直接返回项目
      return item;
    } on Exception catch (e) {
      await Log.e(
        'Failed to process clip item',
        tag: 'OptimizedClipboardManager',
        error: e,
        fields: {'id': item.id},
      );
      return null;
    }
  }

  /// 添加到写入缓冲区
  Future<void> _addToWriteBuffer(ClipItem item) async {
    _writeBuffer.add(item);

    // 检查缓冲区是否需要刷新：达到最大大小、高优先级项目、或超时
    final bufferAge = _lastClipTime == null
        ? Duration.zero
        : DateTime.now().difference(_lastClipTime!);
    final shouldFlush =
        _writeBuffer.length >= _maxBufferSize ||
        item.type == ClipType.text ||
        bufferAge > _maxBufferAge;

    if (shouldFlush) {
      _scheduleImmediateBatchWrite();
    } else {
      _scheduleBatchWrite();
    }
  }

  /// 调度批量写入
  void _scheduleBatchWrite() {
    // 如果已经有定时器在运行，不重复调度
    if (_batchWriteTimer?.isActive ?? false) return;

    _batchWriteTimer = Timer(_batchWriteDelay, _flushWriteBuffer);
  }

  /// 立即调度批量写入
  void _scheduleImmediateBatchWrite() {
    _batchWriteTimer?.cancel();
    _batchWriteTimer = Timer(Duration.zero, _flushWriteBuffer);
  }

  /// 刷新写入缓冲区
  Future<void> _flushWriteBuffer() async {
    if (_isDisposed || _writeBuffer.isEmpty) return;

    final itemsToWrite = List<ClipItem>.from(_writeBuffer);
    _writeBuffer.clear();

    try {
      await Log.d(
        'Flushing write buffer',
        tag: 'OptimizedClipboardManager',
        fields: {'count': itemsToWrite.length},
      );

      // 批量写入数据库
      await _batchInsertItems(itemsToWrite);
      _totalClipsSaved += itemsToWrite.length;

      await Log.d(
        'Write buffer flushed successfully',
        tag: 'OptimizedClipboardManager',
        fields: {'count': itemsToWrite.length},
      );
    } on Exception catch (e) {
      await Log.e(
        'Failed to flush write buffer',
        tag: 'OptimizedClipboardManager',
        error: e,
        fields: {'count': itemsToWrite.length},
      );

      // 如果批量写入失败，尝试单独写入
      for (final item in itemsToWrite) {
        try {
          await _database.insertClipItem(item);
          _totalClipsSaved++;
        } on Exception catch (itemError) {
          await Log.e(
            'Failed to save individual item',
            tag: 'OptimizedClipboardManager',
            error: itemError,
            fields: {'id': item.id},
          );
        }
      }
    }
  }

  /// 批量插入剪贴板项目
  Future<void> _batchInsertItems(List<ClipItem> items) async {
    if (items.isEmpty) return;

    // 使用数据库的批量插入功能
    final stopwatch = Stopwatch()..start();
    final batchInsertOverride = _batchInsertOverride;

    try {
      if (batchInsertOverride != null) {
        await batchInsertOverride(items);
      } else {
        // 显式启用事务以确保原子性 (漏洞#9)
        await _database.batchInsertClipItems(items);
      }

      stopwatch.stop();

      await Log.d(
        'Batch insert completed',
        tag: 'OptimizedClipboardManager',
        fields: {
          'count': items.length,
          'duration': stopwatch.elapsedMilliseconds,
          'avgTimePerItem': stopwatch.elapsedMilliseconds / items.length,
        },
      );
    } on Exception catch (e) {
      stopwatch.stop();
      await Log.e(
        'Batch insert failed',
        tag: 'OptimizedClipboardManager',
        error: e,
        fields: {
          'count': items.length,
          'duration': stopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    }
  }

  /// 处理错误
  void _handleError(String error) {
    unawaited(
      Log.e(
        'Clipboard monitoring error',
        tag: 'OptimizedClipboardManager',
        error: Exception(error),
      ),
    );
  }

  /// 获取综合性能指标
  Map<String, dynamic> getPerformanceMetrics() {
    final pollerStats = _poller.getPollingStats();
    final queueStats = _processingQueue.getStats();
    final processorStats = _processor.getPerformanceMetrics();

    final processingRate = _totalClipsDetected > 0
        ? (_totalClipsProcessed / _totalClipsDetected * 100)
        : 0.0;

    final saveRate = _totalClipsProcessed > 0
        ? (_totalClipsSaved / _totalClipsProcessed * 100)
        : 0.0;

    return {
      'timestamp': DateTime.now().toIso8601String(),
      'detection': {
        'totalDetected': _totalClipsDetected,
        'totalProcessed': _totalClipsProcessed,
        'processingRate': processingRate.toStringAsFixed(1),
        'lastClipTime': _lastClipTime?.toIso8601String(),
        ...pollerStats,
      },
      'processing': {
        'queue': queueStats,
        'processor': processorStats,
      },
      'storage': {
        'totalSaved': _totalClipsSaved,
        'saveRate': saveRate.toStringAsFixed(1),
        'writeBufferSize': _writeBuffer.length,
        'batchWriteActive': _batchWriteTimer?.isActive ?? false,
      },
      'overall': {
        'efficiency': {
          'detectionToProcessing': processingRate.toStringAsFixed(1),
          'processingToStorage': saveRate.toStringAsFixed(1),
          'overall': (processingRate * saveRate / 100).toStringAsFixed(1),
        },
      },
    };
  }

  /// 重置统计信息
  void resetStats() {
    _totalClipsDetected = 0;
    _totalClipsProcessed = 0;
    _totalClipsSaved = 0;
    _lastClipTime = null;
    _poller.resetStats();
    _processingQueue.resetStats();
  }

  /// 强制刷新所有缓冲区
  Future<void> flushAllBuffers() async {
    await _flushWriteBuffer();
  }

  /// 检查是否在快速复制模式
  bool get isRapidCopyMode =>
      (_poller.getPollingStats()['isRapidCopyMode'] as bool?) ?? false;

  /// 获取当前轮询间隔
  Duration get currentPollingInterval => Duration(
    milliseconds:
        (_poller.getPollingStats()['currentInterval'] as int?) ?? 1000,
  );

  /// 获取队列状态
  Map<String, dynamic> get queueStatus => _processingQueue.getStats();

  /// 公共方法：添加剪贴板项目到处理队列（用于测试）
  Future<void> addToProcessingQueue(ClipItem item) async {
    await _addToProcessingQueue(item);
  }

  /// 测试辅助：直接向写入缓冲区注入项目，跳过数据库和剪贴板依赖。
  @visibleForTesting
  void debugBufferItem(ClipItem item) {
    _writeBuffer.add(item);
  }

  /// 测试辅助：查看当前缓冲区大小。
  @visibleForTesting
  int get debugBufferedItemCount => _writeBuffer.length;

  /// 销毁管理器
  Future<void> dispose() async {
    if (_isDisposed || _isDisposing) return;

    _isDisposing = true;
    _stopMonitoring(flushPending: false);
    await _waitForActiveHandlers();
    await flushAllBuffers();
    _isDisposed = true;

    // 安全关闭流控制器
    if (!_uiController.isClosed) {
      await _uiController.close();
    }
  }

  Future<void> _waitForActiveHandlers() async {
    if (_activeChangeHandlers == 0) {
      return;
    }
    _drainCompleter ??= Completer<void>();
    await _drainCompleter!.future;
  }
}

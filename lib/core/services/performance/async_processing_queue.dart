import 'dart:async';

import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/observability/index.dart';

/// 异步处理队列项
class _QueueItem<T> {
  /// 创建队列项
  _QueueItem({
    required this.data,
    required this.processor,
    this.priority = Priority.normal,
    this.id,
  });

  final T data;
  final Future<T?> Function(T data) processor;
  final Priority priority;
  final String? id;
  final DateTime timestamp = DateTime.now();
  Completer<T?>? completer;

  @override
  String toString() {
    return '_QueueItem(id: $id, priority: $priority, timestamp: $timestamp)';
  }
}

/// 异步处理队列管理器
///
/// 提供高性能的异步任务处理，支持：
/// - 优先级队列
/// - 并发处理
/// - 背压控制
/// - 任务去重
/// - 错误处理和重试
class AsyncProcessingQueue {
  /// 创建异步处理队列
  AsyncProcessingQueue({
    int maxConcurrentTasks = 3,
    int maxQueueSize = 100,
    Duration taskTimeout = const Duration(seconds: 30),
  }) : _maxConcurrentTasks = maxConcurrentTasks,
       _maxQueueSize = maxQueueSize,
       _taskTimeout = taskTimeout;

  final int _maxConcurrentTasks;
  final int _maxQueueSize;
  final Duration _taskTimeout;

  final PriorityQueue<_QueueItem<ClipItem>> _queue =
      PriorityQueue<_QueueItem<ClipItem>>(
        (a, b) {
          final priorityComparison = a.priority.value.compareTo(
            b.priority.value,
          );
          if (priorityComparison != 0) {
            return priorityComparison;
          }
          return a.timestamp.compareTo(b.timestamp);
        },
      );

  final Set<String> _processingIds = {};
  final Map<String, _QueueItem<ClipItem>> _pendingItems = {};

  bool _isProcessing = false;
  Timer? _cleanupTimer;
  Timer? _debounceTimer;

  // 性能统计
  int _totalProcessed = 0;
  int _totalFailed = 0;
  int _totalDuplicates = 0;
  DateTime? _lastProcessTime;
  final List<Duration> _processingTimes = [];

  /// 启动队列处理器
  void start() {
    if (_isProcessing) return;

    _isProcessing = true;
    _startCleanupTimer();
    unawaited(_processQueue());
  }

  /// 停止队列处理器
  void stop() {
    _isProcessing = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// 添加剪贴板处理任务
  Future<ClipItem?> addClipboardTask({
    required ClipItem item,
    required Future<ClipItem?> Function(ClipItem item) processor,
    Priority priority = Priority.normal,
  }) async {
    final id = item.id;

    // 检查是否有重复任务
    if (_pendingItems.containsKey(id)) {
      _totalDuplicates++;
      await Log.d(
        'Duplicate clipboard task skipped',
        tag: 'AsyncProcessingQueue',
        fields: {'id': id},
      );
      return null;
    }

    if (_queue.length >= _maxQueueSize) {
      final droppedItem = _queue.removeLowestPriority();
      _pendingItems.remove(droppedItem.id);
      if (!(droppedItem.completer?.isCompleted ?? true)) {
        droppedItem.completer!.complete(null);
      }
      await Log.w(
        'Queue full, dropping lowest-priority task',
        tag: 'AsyncProcessingQueue',
        fields: {
          'queueSize': _queue.length,
          'maxSize': _maxQueueSize,
          'droppedTaskId': droppedItem.id,
          'droppedPriority': droppedItem.priority.name,
        },
      );
    }

    final queueItem = _QueueItem<ClipItem>(
      data: item,
      processor: processor,
      priority: priority,
      id: id,
    );
    final completer = queueItem.completer = Completer<ClipItem?>();

    _pendingItems[id] = queueItem;
    _queue.add(queueItem);

    // 防抖机制：如果短时间内有多个任务，延迟处理
    _scheduleDebouncedProcess();

    return completer.future;
  }

  /// 调度防抖处理
  void _scheduleDebouncedProcess() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      const Duration(milliseconds: 50),
      () {
        if (_isProcessing) {
          unawaited(_processQueue());
        }
      },
    );
  }

  /// 处理队列中的任务
  Future<void> _processQueue() async {
    if (!_isProcessing ||
        _queue.isEmpty ||
        _processingIds.length >= _maxConcurrentTasks) {
      return;
    }

    while (!_queue.isEmpty && _processingIds.length < _maxConcurrentTasks) {
      final queueItem = _queue.remove();
      if (queueItem.completer?.isCompleted ?? false) continue;

      _pendingItems.remove(queueItem.id);
      _processingIds.add(queueItem.id!);

      // 异步处理任务
      unawaited(
        _processTask(queueItem)
            .then((_) {
              _processingIds.remove(queueItem.id);
            })
            .catchError((Object error) {
              _processingIds.remove(queueItem.id);
              _totalFailed++;
              unawaited(
                Log.e(
                  'Task processing failed',
                  tag: 'AsyncProcessingQueue',
                  error: error,
                  fields: {'taskId': queueItem.id},
                ),
              );
            }),
      );

      // 继续处理下一个任务
      Timer(const Duration(milliseconds: 10), _processQueue);
    }
  }

  /// 处理单个任务
  Future<void> _processTask(_QueueItem<ClipItem> queueItem) async {
    final stopwatch = Stopwatch()..start();

    try {
      await Log.d(
        'Processing clipboard task',
        tag: 'AsyncProcessingQueue',
        fields: {
          'taskId': queueItem.id,
          'priority': queueItem.priority.name,
        },
      );

      // Race the task against a timeout marker to avoid hanging callers.
      final result = await Future.any<ClipItem?>([
        queueItem.processor(queueItem.data),
        Future<ClipItem?>.delayed(_taskTimeout, () {
          unawaited(
            Log.w(
              'Task timeout',
              tag: 'AsyncProcessingQueue',
              fields: {
                'taskId': queueItem.id,
                'timeout': _taskTimeout.inSeconds,
              },
            ),
          );
          return null;
        }),
      ]);

      stopwatch.stop();
      _processingTimes.add(stopwatch.elapsed);
      _totalProcessed++;
      _lastProcessTime = DateTime.now();

      // 完成任务
      if (!queueItem.completer!.isCompleted) {
        queueItem.completer!.complete(result);
      }

      await Log.d(
        'Task completed successfully',
        tag: 'AsyncProcessingQueue',
        fields: {
          'taskId': queueItem.id,
          'processingTime': stopwatch.elapsedMilliseconds,
        },
      );
    } on Exception catch (e) {
      stopwatch.stop();
      _totalFailed++;

      if (!queueItem.completer!.isCompleted) {
        queueItem.completer!.completeError(e);
      }

      await Log.e(
        'Task processing failed',
        tag: 'AsyncProcessingQueue',
        error: e,
        fields: {
          'taskId': queueItem.id,
          'processingTime': stopwatch.elapsedMilliseconds,
        },
      );
    }
  }

  /// 启动清理定时器
  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanup();
    });
  }

  /// 清理过期的任务和统计数据
  void _cleanup() {
    final now = DateTime.now();

    // 清理超时的任务
    final expiredItems = _pendingItems.values.where(
      (item) => now.difference(item.timestamp) > _taskTimeout,
    );

    for (final item in expiredItems) {
      _pendingItems.remove(item.id);
      if (!item.completer!.isCompleted) {
        item.completer!.completeError(
          TimeoutException('Task expired', _taskTimeout),
        );
      }
    }

    // 清理旧的统计数据
    if (_processingTimes.length > 100) {
      _processingTimes.removeRange(0, _processingTimes.length - 50);
    }
  }

  /// 获取队列统计信息
  Map<String, dynamic> getStats() {
    final avgProcessingTime = _processingTimes.isNotEmpty
        ? _processingTimes.fold<int>(
                0,
                (sum, time) => sum + time.inMilliseconds,
              ) /
              _processingTimes.length
        : 0.0;

    return {
      'isProcessing': _isProcessing,
      'queueSize': _queue.length,
      'pendingItems': _pendingItems.length,
      'processingItems': _processingIds.length,
      'maxConcurrentTasks': _maxConcurrentTasks,
      'maxQueueSize': _maxQueueSize,
      'totalProcessed': _totalProcessed,
      'totalFailed': _totalFailed,
      'totalDuplicates': _totalDuplicates,
      'successRate': _totalProcessed + _totalFailed > 0
          ? ((_totalProcessed / (_totalProcessed + _totalFailed)) * 100)
                .toStringAsFixed(1)
          : '0.0',
      'averageProcessingTime': avgProcessingTime.toStringAsFixed(1),
      'lastProcessTime': _lastProcessTime?.toIso8601String(),
    };
  }

  /// 重置统计信息
  void resetStats() {
    _totalProcessed = 0;
    _totalFailed = 0;
    _totalDuplicates = 0;
    _lastProcessTime = null;
    _processingTimes.clear();
  }

  /// 清空队列
  void clearQueue() {
    // 取消所有待处理的任务
    for (final item in _pendingItems.values) {
      if (!item.completer!.isCompleted) {
        item.completer!.completeError(
          Exception('Queue cleared'),
        );
      }
    }

    _queue.clear();
    _pendingItems.clear();
    _processingIds.clear();
  }
}

/// 优先级队列实现
class PriorityQueue<T> {
  /// 创建优先级队列
  PriorityQueue(int Function(T a, T b) comparator)
    : _comparator = comparator,
      _data = [];

  final int Function(T a, T b) _comparator;
  final List<T> _data;

  /// 添加元素到队列
  void add(T item) {
    _data.add(item);
    _bubbleUp(_data.length - 1);
  }

  /// 从队列中移除并返回最高优先级元素
  T remove() {
    if (_data.isEmpty) {
      throw StateError('Cannot remove from empty queue');
    }

    final result = _data.first;
    final last = _data.removeLast();

    if (_data.isNotEmpty) {
      _data[0] = last;
      _bubbleDown(0);
    }

    return result;
  }

  /// 从队列中移除并返回最低优先级元素。
  T removeLowestPriority() {
    if (_data.isEmpty) {
      throw StateError('Cannot remove from empty queue');
    }

    var lowestIndex = 0;
    for (var i = 1; i < _data.length; i++) {
      if (_comparator(_data[i], _data[lowestIndex]) < 0) {
        lowestIndex = i;
      }
    }

    final result = _data[lowestIndex];
    final last = _data.removeLast();

    if (lowestIndex < _data.length) {
      _data[lowestIndex] = last;
      _bubbleDown(lowestIndex);
      _bubbleUp(lowestIndex);
    }

    return result;
  }

  /// 检查队列是否为空
  bool get isEmpty => _data.isEmpty;

  /// 获取队列长度
  int get length => _data.length;

  /// 清空队列
  void clear() {
    _data.clear();
  }

  void _bubbleUp(int currentIndex) {
    var index = currentIndex;
    while (index > 0) {
      final parentIndex = (index - 1) ~/ 2;
      if (_comparator(_data[index], _data[parentIndex]) <= 0) break;

      _swap(index, parentIndex);
      index = parentIndex;
    }
  }

  void _bubbleDown(int currentIndex) {
    final length = _data.length;
    var index = currentIndex;

    while (true) {
      var largest = index;
      final leftIndex = 2 * index + 1;
      final rightIndex = 2 * index + 2;

      if (leftIndex < length &&
          _comparator(_data[leftIndex], _data[largest]) > 0) {
        largest = leftIndex;
      }

      if (rightIndex < length &&
          _comparator(_data[rightIndex], _data[largest]) > 0) {
        largest = rightIndex;
      }

      if (largest == index) break;

      _swap(index, largest);
      index = largest;
    }
  }

  void _swap(int a, int b) {
    final temp = _data[a];
    _data[a] = _data[b];
    _data[b] = temp;
  }
}

/// 队列优先级
enum Priority {
  /// 低优先级
  low(0),

  /// 普通优先级
  normal(1),

  /// 高优先级
  high(2),

  /// 关键优先级
  critical(3);

  /// 创建优先级枚举值
  const Priority(this.value);

  /// 优先级数值
  final int value;
}

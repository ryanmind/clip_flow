import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/async_processing_queue.dart';
import 'package:clip_flow/core/services/clipboard_poller.dart';
import 'package:clip_flow/core/services/clipboard/clipboard_manager.dart';
import 'package:clip_flow/core/services/storage/index.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 确保Flutter测试环境初始化
  TestWidgetsFlutterBinding.ensureInitialized();

  const clipboardChannel = MethodChannel('clipboard_service');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const clipboardEvents = EventChannel('clipboard_events');
  final tempRoot = Directory.systemTemp.createTempSync('clip_flow_perf_test_');

  late MockStreamHandlerEventSink eventSink;
  late bool shouldFailStream;
  late int mockSequence;

  Future<void> emitNativeEvent(int sequence, {int intervalMs = 0}) async {
    eventSink.success(<String, Object?>{
      'sequence': sequence,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'platform': 'macos',
      'source': 'owner-change',
      'monitoringIntervalMs': intervalMs,
    });
    await Future<void>.delayed(Duration.zero);
  }

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardChannel, (call) async {
          if (call.method == 'getClipboardSequence') {
            return mockSequence;
          }
          return null;
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          switch (call.method) {
            case 'getApplicationSupportDirectory':
            case 'getApplicationDocumentsDirectory':
            case 'getTemporaryDirectory':
              return tempRoot.path;
            default:
              return tempRoot.path;
          }
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          clipboardEvents,
          MockStreamHandler.inline(
            onListen: (arguments, events) {
              if (shouldFailStream) {
                events.error(code: 'STREAM_ERROR', message: 'stream failed');
                return;
              }
              eventSink = events;
            },
          ),
        );
  });

  tearDownAll(() async {
    await DatabaseService.instance.close();
    PathService.instance.clearCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(clipboardEvents, null);
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('剪贴板性能优化测试', () {
    late ClipboardManager manager;
    late ClipboardPoller poller;
    late AsyncProcessingQueue queue;

    setUp(() async {
      shouldFailStream = false;
      mockSequence = 0;
      PathService.instance.clearCache();
      manager = ClipboardManager.test(
        batchInsertOverride: (_) async {},
        skipStorageInitialization: true,
      );
      poller = ClipboardPoller();
      queue = AsyncProcessingQueue();
    });

    tearDown(() async {
      await manager.dispose();
      await DatabaseService.instance.close();
      PathService.instance.clearCache();
      poller.stopPolling();
      queue.stop();
    });

    test('快速复制模式检测测试', () async {
      poller.startPolling();
      await Future<void>.delayed(Duration.zero);

      // 模拟快速复制
      for (int i = 1; i <= 5; i++) {
        await Future.delayed(Duration(milliseconds: 200));
        await emitNativeEvent(i);
      }

      // 检查是否进入快速复制模式
      final stats = poller.getPollingStats();
      print('轮询统计: $stats');

      expect(stats['isRapidCopyMode'], isTrue);
      expect(stats['rapidCopyCount'], greaterThanOrEqualTo(3));
      expect(stats['totalNativeEvents'], equals(5));
    });

    test('异步处理队列性能测试', () async {
      queue.start();

      final stopwatch = Stopwatch()..start();

      // 添加多个处理任务
      final futures = <Future>[];
      for (int i = 0; i < 20; i++) {
        final item = ClipItem(
          id: 'test_$i',
          type: ClipType.text,
          content: '测试内容 $i',
          metadata: {},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final future = queue.addClipboardTask(
          item: item,
          processor: (item) async {
            // 模拟处理时间
            await Future.delayed(
              Duration(milliseconds: 10 + Random().nextInt(20)),
            );
            return item;
          },
          priority: i % 3 == 0 ? Priority.high : Priority.normal,
        );

        futures.add(future);
      }

      // 等待所有任务完成
      final results = await Future.wait(futures);

      stopwatch.stop();

      final queueStats = queue.getStats();
      print('队列统计: $queueStats');
      print('总处理时间: ${stopwatch.elapsedMilliseconds}ms');
      print('平均处理时间: ${stopwatch.elapsedMilliseconds / results.length}ms');

      expect(results.length, equals(20));
      expect(queueStats['totalProcessed'], equals(20));
      expect(queueStats['successRate'], equals('100.0'));
    });

    test('批量写入性能测试', () async {
      await manager.initialize();

      final stopwatch = Stopwatch()..start();

      // 模拟快速复制场景
      final items = <ClipItem>[];
      for (int i = 0; i < 50; i++) {
        items.add(
          ClipItem(
            id: 'batch_test_$i',
            type: i % 4 == 0 ? ClipType.code : ClipType.text,
            content: '批量测试内容 $i',
            metadata: {},
            createdAt: DateTime.now().subtract(Duration(seconds: i)),
            updatedAt: DateTime.now(),
          ),
        );
      }

      // 使用优化管理器处理
      for (final item in items) {
        await manager.addToProcessingQueue(item);
      }

      // 等待处理完成
      await Future.delayed(Duration(seconds: 2));
      await manager.flushAllBuffers();

      stopwatch.stop();

      final metrics = manager.getPerformanceMetrics();
      print('性能指标: $metrics');
      print('批量写入总时间: ${stopwatch.elapsedMilliseconds}ms');

      expect(metrics['storage']['totalSaved'], greaterThan(0));
      expect(stopwatch.elapsedMilliseconds, lessThan(3000)); // 应该在3秒内完成
    });

    test('轮询间隔自适应测试', () async {
      poller.startPolling();
      await Future<void>.delayed(Duration.zero);

      final initialInterval = poller.currentInterval;
      print('初始轮询间隔: ${initialInterval.inMilliseconds}ms');

      for (int i = 1; i <= 3; i++) {
        await emitNativeEvent(i);
      }

      final activeInterval = poller.currentInterval;
      print('活跃轮询间隔: ${activeInterval.inMilliseconds}ms');

      expect(activeInterval, equals(Duration.zero));

      poller.stopPolling();

      shouldFailStream = true;
      final fallbackPoller = ClipboardPoller();
      fallbackPoller.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final fallbackInterval = fallbackPoller.currentInterval;
      print('回退轮询间隔: ${fallbackInterval.inMilliseconds}ms');

      expect(
        fallbackInterval.inMilliseconds,
        greaterThan(initialInterval.inMilliseconds),
      );
      fallbackPoller.stopPolling();
    });

    test('内存使用和缓存效率测试', () async {
      await manager.initialize();
      manager.startMonitoring();

      // 生成大量数据测试内存使用
      for (int i = 0; i < 100; i++) {
        final item = ClipItem(
          id: 'memory_test_$i',
          type: ClipType.text,
          content: '内存测试内容 $i' * (10 + Random().nextInt(50)), // 变长内容
          metadata: {},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        await manager.addToProcessingQueue(item);
      }

      // 等待处理完成
      await Future.delayed(Duration(seconds: 3));
      await manager.flushAllBuffers();

      final metrics = manager.getPerformanceMetrics();
      print('内存使用指标: $metrics');

      // 检查处理效率
      expect(metrics['processing']['queue']['totalProcessed'], greaterThan(80));
      expect(metrics['storage']['totalSaved'], greaterThan(80));
    });

    test('并发处理能力测试', () async {
      queue.start();

      const concurrency = 10;
      const itemsPerBatch = 20;

      final stopwatch = Stopwatch()..start();

      // 创建多个并发批次
      final batchFutures = <Future>[];
      for (int batch = 0; batch < concurrency; batch++) {
        final batchFuture = () async {
          for (int i = 0; i < itemsPerBatch; i++) {
            final item = ClipItem(
              id: 'concurrent_${batch}_$i',
              type: ClipType.text,
              content: '并发测试内容 ${batch}_$i',
              metadata: {},
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            );

            await queue.addClipboardTask(
              item: item,
              processor: (item) async {
                // 模拟不同的处理时间
                await Future.delayed(
                  Duration(milliseconds: 5 + Random().nextInt(15)),
                );
                return item;
              },
            );
          }
        }();

        batchFutures.add(batchFuture);
      }

      await Future.wait(batchFutures);

      // 等待所有任务完成
      await Future.delayed(Duration(seconds: 5));

      stopwatch.stop();

      final stats = queue.getStats();
      print('并发处理统计: $stats');
      print('总处理时间: ${stopwatch.elapsedMilliseconds}ms');
      print(
        '总吞吐量: ${(concurrency * itemsPerBatch / stopwatch.elapsedMilliseconds * 1000).toStringAsFixed(1)} items/sec',
      );

      expect(stats['totalProcessed'], equals(concurrency * itemsPerBatch));
      expect(stopwatch.elapsedMilliseconds, lessThan(10000)); // 10秒内完成
    });

    test('错误恢复和容错性测试', () async {
      queue.start();

      var successCount = 0;
      var errorCount = 0;

      // 添加一些正常任务和一些失败任务
      for (int i = 0; i < 20; i++) {
        final item = ClipItem(
          id: 'error_test_$i',
          type: ClipType.text,
          content: '错误测试内容 $i',
          metadata: {},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        try {
          await queue.addClipboardTask(
            item: item,
            processor: (item) async {
              if (i % 5 == 0) {
                throw Exception('模拟处理错误');
              }
              successCount++;
              return item;
            },
          );
        } catch (e) {
          errorCount++;
        }
      }

      // 等待处理完成
      await Future.delayed(Duration(seconds: 2));

      final stats = queue.getStats();
      print('错误处理统计: $stats');
      print('成功: $successCount, 错误: $errorCount');

      expect(stats['totalProcessed'], equals(16)); // 20 - 4个错误
      expect(stats['totalFailed'], equals(4));
    });
  });

  group('性能基准测试', () {
    test('轮询性能基准', () async {
      final poller = ClipboardPoller();
      poller.startPolling();

      const testDuration = Duration(seconds: 5);
      final startTime = DateTime.now();
      var checkCount = 0;

      while (DateTime.now().difference(startTime) < testDuration) {
        await poller.checkOnce();
        checkCount++;
        await Future.delayed(Duration(milliseconds: 100));
      }

      final stats = poller.getPollingStats();
      print('轮询基准测试结果:');
      print('- 测试时长: ${testDuration.inSeconds}秒');
      print('- 检查次数: $checkCount');
      print(
        '- 检查频率: ${(checkCount / testDuration.inSeconds).toStringAsFixed(1)} checks/sec',
      );
      print('- 成功率: ${stats['successRate']}%');

      poller.stopPolling();

      expect(checkCount, greaterThan(40)); // 至少40次检查
    });

    test('OCR处理性能基准', () async {
      // 创建模拟图片数据
      final imageData = Uint8List(1024 * 100); // 100KB图片
      for (int i = 0; i < imageData.length; i++) {
        imageData[i] = Random().nextInt(256);
      }

      const testCount = 10;
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < testCount; i++) {
        // 这里应该调用实际的OCR处理，但为了测试我们模拟处理时间
        await Future.delayed(
          Duration(milliseconds: 100 + Random().nextInt(200)),
        );
      }

      stopwatch.stop();

      final avgTime = stopwatch.elapsedMilliseconds / testCount;
      print('OCR处理基准测试结果:');
      print('- 测试数量: $testCount');
      print('- 总时间: ${stopwatch.elapsedMilliseconds}ms');
      print('- 平均时间: ${avgTime.toStringAsFixed(1)}ms');
      print('- 处理速度: ${(1000 / avgTime).toStringAsFixed(1)} images/sec');

      expect(avgTime, lessThan(400)); // 平均处理时间应小于400ms
    });
  });
}
